import argparse
from dataclasses import asdict, dataclass
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import tomllib


MANIFEST = Path(__file__).resolve().parents[1] / "extension.toml"
GRAMMAR_FILES = ("grammar.js", "tree-sitter.json", "src/parser.c", "src/node-types.json")


@dataclass(frozen=True)
class GrammarReference:
    repository: str
    revision: str
    path: str


def read_reference(manifest):
    with Path(manifest).open("rb") as source:
        grammars = tomllib.load(source).get("grammars", {})
    grammar = grammars.get("ss") if isinstance(grammars, dict) else None
    if not isinstance(grammar, dict):
        raise ValueError("[grammars.ss] must be a table")
    fields = {}
    for name in ("repository", "rev", "path"):
        value = grammar.get(name)
        if not isinstance(value, str):
            raise ValueError(f"[grammars.ss].{name} must be a string")
        fields[name] = value
    if not re.fullmatch(r"https://github\.com/[\w.-]+/[\w.-]+(?:\.git)?", fields["repository"], re.ASCII):
        raise ValueError("[grammars.ss].repository must be an HTTPS GitHub repository URL")
    if not re.fullmatch(r"[0-9a-f]{40}", fields["rev"]):
        raise ValueError("[grammars.ss].rev must be a full commit SHA")
    if not re.fullmatch(r"[\w-]+(?:/[\w-]+)*", fields["path"], re.ASCII):
        raise ValueError("[grammars.ss].path must be a relative grammar directory")
    return GrammarReference(fields["repository"], fields["rev"], fields["path"])


def run_git(*arguments):
    # Never borrow objects or repository configuration from the calling checkout.
    environment = {name: value for name, value in os.environ.items() if not name.startswith("GIT_")}
    environment.update(GIT_TERMINAL_PROMPT="0", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
    process = subprocess.Popen(
        ["git", *map(str, arguments)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, env=environment, start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=60)
    except subprocess.TimeoutExpired as error:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        raise RuntimeError("Git operation exceeded its 60-second deadline") from error
    if process.returncode:
        raise RuntimeError(stderr.strip() or f"Git exited with status {process.returncode}")
    return stdout.strip()


def fetch_reference(reference, directory):
    directory = Path(directory)
    directory.mkdir()
    run_git("init", "--bare", "--quiet", directory)
    try:
        run_git("--git-dir", directory, "fetch", "--quiet", "--no-tags", "--depth=1",
                "--no-recurse-submodules", reference.repository, reference.revision)
    except RuntimeError as error:
        raise RuntimeError(
            f"cannot fetch grammar revision {reference.revision} from {reference.repository}: {error}"
        ) from error
    fetched = run_git("--git-dir", directory, "rev-parse", "--verify", "FETCH_HEAD^{commit}")
    if fetched != reference.revision:
        raise ValueError(f"fetched grammar revision {fetched}, expected {reference.revision}")
    for name in GRAMMAR_FILES:
        target = f"{reference.path}/{name}"
        try:
            kind = run_git("--git-dir", directory, "cat-file", "-t", f"{fetched}:{target}")
        except RuntimeError as error:
            raise ValueError(f"grammar revision {fetched} does not contain {target}") from error
        if kind != "blob":
            raise ValueError(f"grammar revision {fetched}: {target} must be a file")
    return directory


def check_reference(manifest=MANIFEST, archive=None):
    reference = read_reference(manifest)
    with tempfile.TemporaryDirectory(prefix="ss-zed-grammar-") as temporary:
        repository = fetch_reference(reference, Path(temporary) / "repository.git")
        if archive is not None:
            paths = [f"{reference.path}/{name}" for name in ("grammar.js", "tree-sitter.json", "src")]
            run_git("--git-dir", repository, "archive", "--format=tar",
                    f"--output={Path(archive).resolve()}", reference.revision, "--", *paths)
    return reference


def main():
    parser = argparse.ArgumentParser(description="Verify that Zed's pinned grammar can be fetched independently.")
    parser.add_argument("--manifest", type=Path, default=MANIFEST)
    parser.add_argument("--archive", type=Path, help="Save the verified grammar sources for integration tests")
    arguments = parser.parse_args()
    try:
        reference = check_reference(arguments.manifest, arguments.archive)
    except (OSError, RuntimeError, ValueError) as error:
        print(f"{arguments.manifest}: {error}", file=sys.stderr)
        return 1
    print(json.dumps(asdict(reference)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

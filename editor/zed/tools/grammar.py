from dataclasses import dataclass
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import tomllib
from urllib.parse import unquote, urlsplit


GRAMMAR_PATH = "editor/tree-sitter-ss"
GRAMMAR_FILES = ("grammar.js", "tree-sitter.json", "src/parser.c", "src/node-types.json")
GRAMMAR_SOURCES = ("grammar.js", "tree-sitter.json", "src")


@dataclass(frozen=True)
class GrammarReference:
    repository: str
    revision: str
    path: str


def read_reference(manifest, *, allow_local=False):
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
    local = urlsplit(fields["repository"])
    local_allowed = (allow_local and local.scheme == "file" and not local.netloc
                     and Path(unquote(local.path)).is_absolute() and not local.query and not local.fragment)
    if not local_allowed and not re.fullmatch(r"https://github\.com/[\w.-]+/[\w.-]+(?:\.git)?", fields["repository"], re.ASCII):
        raise ValueError("[grammars.ss].repository must be an HTTPS GitHub repository URL")
    if not re.fullmatch(r"[0-9a-f]{40}", fields["rev"]):
        raise ValueError("[grammars.ss].rev must be a full commit SHA")
    if not re.fullmatch(r"[\w-]+(?:/[\w-]+)*", fields["path"], re.ASCII):
        raise ValueError("[grammars.ss].path must be a relative grammar directory")
    return GrammarReference(fields["repository"], fields["rev"], fields["path"])


def run_git(*arguments, environment=None):
    # Never borrow objects or repository configuration from the calling checkout.
    clean_environment = {name: value for name, value in os.environ.items() if not name.startswith("GIT_")}
    clean_environment.update(GIT_TERMINAL_PROMPT="0", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
    clean_environment.update(environment or {})
    process = subprocess.Popen(
        ["git", *map(str, arguments)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, env=clean_environment, start_new_session=True,
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


def check_reference(manifest, archive=None, *, allow_local=False):
    reference = read_reference(manifest, allow_local=allow_local)
    with tempfile.TemporaryDirectory(prefix="ss-zed-grammar-") as temporary:
        repository = fetch_reference(reference, Path(temporary) / "repository.git")
        if archive is not None:
            paths = [f"{reference.path}/{name}" for name in GRAMMAR_SOURCES]
            run_git("--git-dir", repository, "archive", "--format=tar",
                    f"--output={Path(archive).resolve()}", reference.revision, "--", *paths)
    return reference

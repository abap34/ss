"""Generate a Zed extension with a local grammar snapshot or a published commit."""
import argparse
from dataclasses import asdict
import json
from pathlib import Path
import re
import shutil
import tarfile
import tempfile
import tomllib

from grammar import GRAMMAR_FILES, GRAMMAR_PATH, GRAMMAR_SOURCES, GrammarReference, fetch_reference, run_git


ROOT = Path(__file__).resolve().parents[3]
EXTENSION_PATH = "editor/zed"
EXTENSION_SOURCES = ("Cargo.toml", "Cargo.lock", "src", "languages")
TEMPLATE = "extension.toml.in"
MARKER = ".ss-zed-generation.json"


def copy_sources(source, destination, paths):
    for name in paths:
        path = source / name
        if path.is_symlink():
            raise ValueError(f"extension sources must not be symlinks: {path}")
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if path.is_dir():
            for child in path.rglob("*"):
                if child.is_symlink():
                    raise ValueError(f"extension sources must not be symlinks: {child}")
            shutil.copytree(path, target)
        else:
            shutil.copyfile(path, target)


def render_manifest(template, reference):
    # Older published releases used extension.toml directly. Replace its grammar
    # table too, keeping their extension sources and grammar at the same commit.
    tomllib.loads(template)
    template = re.sub(r"(?ms)^\[grammars\.ss\][ \t]*\n.*?(?=^\[|\Z)", "", template)
    fields = {"repository": reference.repository, "rev": reference.revision, "path": reference.path}
    rendered = template.rstrip() + "\n\n[grammars.ss]\n" + "".join(
        f"{name} = {json.dumps(value)}\n" for name, value in fields.items()
    )
    tomllib.loads(rendered)
    return rendered


def snapshot_grammar(root, directory, published_path):
    for name in GRAMMAR_FILES:
        if not (root / GRAMMAR_PATH / name).is_file():
            raise ValueError(f"missing grammar source: {name}")
    directory.mkdir()
    copy_sources(root / GRAMMAR_PATH, directory / GRAMMAR_PATH, GRAMMAR_SOURCES)
    run_git("init", "--quiet", directory)
    run_git("-C", directory, "add", "--", GRAMMAR_PATH)
    # Identical content keeps the same revision across runs and source rebases.
    environment = {"GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z"}
    run_git("-C", directory, "-c", "user.name=ss", "-c", "user.email=ss@example.invalid",
            "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
            "commit", "--quiet", "-m", "Snapshot Zed grammar", environment=environment)
    revision = run_git("-C", directory, "rev-parse", "HEAD")
    return GrammarReference(published_path.as_uri(), revision, GRAMMAR_PATH)


def export_extension(repository, revision, directory):
    names = run_git("--git-dir", repository, "ls-tree", "--name-only", f"{revision}:{EXTENSION_PATH}").splitlines()
    manifest = TEMPLATE if TEMPLATE in names else "extension.toml"
    paths = [f"{EXTENSION_PATH}/{name}" for name in (*EXTENSION_SOURCES, manifest)]
    with tempfile.TemporaryDirectory(prefix="ss-zed-export-") as temporary:
        archive = Path(temporary) / "extension.tar"
        run_git("--git-dir", repository, "archive", f"--output={archive}", revision, "--", *paths)
        with tarfile.open(archive) as contents:
            contents.extractall(directory, filter="data")
    source = directory / EXTENSION_PATH
    return source, (source / manifest).read_text()


def prepare(mode, output, *, revision=None, root=ROOT):
    if mode not in {"dev", "release"}:
        raise ValueError("mode must be dev or release")
    if mode == "dev" and revision is not None:
        raise ValueError("--revision is only used for release preparation")
    if mode == "release" and (revision is None or not re.fullmatch(r"[0-9a-f]{40}", revision)):
        raise ValueError("release preparation requires a full commit SHA")
    output = Path(output).absolute()
    if output.is_symlink():
        raise ValueError("output must not be a symlink")
    output = output.resolve()
    for source in (root / EXTENSION_PATH, root / GRAMMAR_PATH):
        source = source.resolve()
        if output.is_relative_to(source) or source.is_relative_to(output):
            raise ValueError("output must be separate from extension and grammar sources")
    if output.exists():
        marker = output / MARKER
        if not marker.is_file() or json.loads(marker.read_text()).get("generator") != "ss-zed":
            raise ValueError(f"refusing to replace an unrelated output directory: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ss-zed-prepare-", dir=output.parent) as temporary:
        work = Path(temporary)
        prepared = work / "prepared"
        prepared.mkdir()
        source = root / EXTENSION_PATH
        template = (source / TEMPLATE).read_text()
        if mode == "dev":
            reference = snapshot_grammar(root, prepared / "grammar", output / "grammar")
        else:
            repository = tomllib.loads(template)["repository"]
            reference = GrammarReference(repository, revision, GRAMMAR_PATH)
            fetched = fetch_reference(reference, work / "published.git")
            source, template = export_extension(fetched, revision, work / "sources")
        extension = prepared / "extension"
        copy_sources(source, extension, EXTENSION_SOURCES)
        (extension / "extension.toml").write_text(render_manifest(template, reference))
        report = {"generator": "ss-zed", "mode": mode, "extension": str(output / "extension"), **asdict(reference)}
        (prepared / MARKER).write_text(json.dumps(report, indent=2) + "\n")
        backup = work / "previous"
        if output.exists():
            output.rename(backup)
        try:
            prepared.rename(output)
        except OSError:
            if backup.exists():
                backup.rename(output)
            raise
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("dev", "release"))
    parser.add_argument("--output", type=Path, required=True, help="Directory for the generated extension and grammar")
    parser.add_argument("--revision", help="Full published commit SHA; defaults to HEAD in release mode")
    arguments = parser.parse_args()
    try:
        revision = arguments.revision
        if arguments.mode == "release" and revision is None:
            revision = run_git("-C", ROOT, "rev-parse", "--verify", "HEAD^{commit}")
        report = prepare(arguments.mode, arguments.output, revision=revision)
    except (OSError, RuntimeError, ValueError, tarfile.TarError) as error:
        parser.exit(1, f"Zed extension preparation failed: {error}\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()

import argparse
from dataclasses import asdict
import json
from pathlib import Path
import tempfile

from grammar import check_reference
from prepare import prepare


def main():
    parser = argparse.ArgumentParser(description="Verify a generated Zed grammar reference. Defaults to the working tree.")
    parser.add_argument("--manifest", type=Path, help="Generated extension.toml to verify")
    parser.add_argument("--allow-local", action="store_true", help="Allow file URLs for a development extension")
    parser.add_argument("--archive", type=Path, help="Save the verified grammar sources for integration tests")
    arguments = parser.parse_args()
    try:
        if arguments.manifest is None:
            with tempfile.TemporaryDirectory(prefix="ss-zed-check-") as temporary:
                report = prepare("dev", Path(temporary) / "dev")
                reference = check_reference(Path(report["extension"]) / "extension.toml", arguments.archive, allow_local=True)
        else:
            reference = check_reference(arguments.manifest, arguments.archive, allow_local=arguments.allow_local)
    except (OSError, RuntimeError, ValueError) as error:
        parser.exit(1, f"Zed grammar verification failed: {error}\n")
    print(json.dumps(asdict(reference)))


if __name__ == "__main__":
    main()

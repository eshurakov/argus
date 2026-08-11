#!/usr/bin/env python3

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, NoReturn


ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = ROOT / "VERSION"
PROJECT_PATH = ROOT / "project.yml"
CLI_PATH = ROOT / "ArgusCLI" / "main.swift"
PBXPROJ_PATH = ROOT / "Argus.xcodeproj" / "project.pbxproj"


def load_manifest() -> tuple[str, int]:
    manifest: Any = None
    try:
        manifest = json.loads(MANIFEST_PATH.read_text())
    except (OSError, TypeError, json.JSONDecodeError) as error:
        fail(f"invalid VERSION manifest: {error}")

    if not isinstance(manifest, dict):
        fail("VERSION must contain a JSON object")
    version = manifest.get("version")
    build = manifest.get("build")

    if not isinstance(version, str) or re.fullmatch(r"\d+\.\d+\.\d+", version) is None:
        fail("VERSION.version must use MAJOR.MINOR.PATCH numeric syntax")
    if not isinstance(build, int) or isinstance(build, bool) or build < 1:
        fail("VERSION.build must be a positive integer")
    return version, build


def write_manifest(version: str, build: int) -> None:
    MANIFEST_PATH.write_text(json.dumps({"version": version, "build": build}, indent=2) + "\n")


def replace_exact(path: Path, pattern: str, replacement: str, description: str) -> None:
    source = path.read_text()
    updated, count = re.subn(pattern, replacement, source, flags=re.MULTILINE)
    if count != 1:
        fail(f"expected exactly one {description} in {path.relative_to(ROOT)}, found {count}")
    path.write_text(updated)


def synchronize(version: str, build: int) -> None:
    replace_exact(
        PROJECT_PATH,
        r'^(\s*MARKETING_VERSION:\s*)"[^"]+"$',
        rf'\g<1>"{version}"',
        "MARKETING_VERSION",
    )
    replace_exact(
        PROJECT_PATH,
        r'^(\s*CURRENT_PROJECT_VERSION:\s*)"[^"]+"$',
        rf'\g<1>"{build}"',
        "CURRENT_PROJECT_VERSION",
    )
    replace_exact(
        CLI_PATH,
        r'^(\s*version:\s*)"argus [^"]+"$',
        rf'\g<1>"argus {version}"',
        "Companion CLI version",
    )


def generate_project() -> None:
    subprocess.run([str(ROOT / "scripts" / "build.sh"), "generate"], cwd=ROOT, check=True)


def require_matches(path: Path, pattern: str, expected_count: int, description: str) -> None:
    source = path.read_text()
    count = len(re.findall(pattern, source, flags=re.MULTILINE))
    if count != expected_count:
        fail(
            f"{path.relative_to(ROOT)} has {count} matching {description}; "
            f"expected {expected_count}"
        )


def verify(version: str, build: int) -> None:
    require_matches(
        PROJECT_PATH,
        rf'^\s*MARKETING_VERSION:\s*"{re.escape(version)}"$',
        1,
        f"MARKETING_VERSION {version}",
    )
    require_matches(
        PROJECT_PATH,
        rf'^\s*CURRENT_PROJECT_VERSION:\s*"{build}"$',
        1,
        f"CURRENT_PROJECT_VERSION {build}",
    )
    require_matches(
        CLI_PATH,
        rf'^\s*version:\s*"argus {re.escape(version)}"$',
        1,
        f"Companion CLI version {version}",
    )
    require_matches(
        PBXPROJ_PATH,
        rf'^\s*MARKETING_VERSION = {re.escape(version)};$',
        2,
        f"generated MARKETING_VERSION {version}",
    )
    require_matches(
        PBXPROJ_PATH,
        rf'^\s*CURRENT_PROJECT_VERSION = {build};$',
        2,
        f"generated CURRENT_PROJECT_VERSION {build}",
    )
    print(f"Version consumers match {version} ({build})")


def next_version(version: str, increment: str) -> str:
    major, minor, patch = (int(component) for component in version.split("."))
    if increment == "minor":
        return f"{major}.{minor + 1}.0"
    if increment == "patch":
        return f"{major}.{minor}.{patch + 1}"
    fail(f"unsupported increment: {increment}")


def prepare(increment: str) -> None:
    version, build = load_manifest()
    prepared_version = next_version(version, increment)
    next_build = build + 1
    write_manifest(prepared_version, next_build)
    synchronize(prepared_version, next_build)
    generate_project()
    verify(prepared_version, next_build)
    print(f"Prepared {prepared_version} ({next_build})")


def fail(message: str) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    parser = argparse.ArgumentParser(description="Synchronize and verify Argus version metadata.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare_parser = subparsers.add_parser("prepare", help="Prepare the next release version.")
    prepare_parser.add_argument("increment", choices=["minor", "patch"])
    subparsers.add_parser("verify", help="Verify all generated version consumers.")
    arguments = parser.parse_args()

    if arguments.command == "prepare":
        prepare(arguments.increment)
    else:
        verify(*load_manifest())


if __name__ == "__main__":
    main()

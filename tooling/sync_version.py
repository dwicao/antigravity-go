#!/usr/bin/env python3
"""Synchronize version.json, app/assets/version.json, and release notes from pubspec.yaml + CHANGELOG.md."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PUBSPEC = ROOT / "app" / "pubspec.yaml"
CHANGELOG = ROOT / "CHANGELOG.md"
ROOT_VERSION_JSON = ROOT / "version.json"
ASSET_VERSION_JSON = ROOT / "app" / "assets" / "version.json"


def parse_pubspec_version(pubspec_path: pathlib.Path = PUBSPEC) -> tuple[str, int]:
    text = pubspec_path.read_text(encoding="utf-8")
    match = re.search(r"^version:\s*([^+\s]+)(?:\+(\d+))?", text, re.MULTILINE)
    if not match:
        raise ValueError(f"version not found in {pubspec_path}")
    version = match.group(1).strip()
    build_number = int(match.group(2)) if match.group(2) else 1
    return version, build_number


def extract_changelog_notes(
    version: str,
    changelog_path: pathlib.Path = CHANGELOG,
) -> str:
    if not changelog_path.exists():
        return ""
    lines = changelog_path.read_text(encoding="utf-8").splitlines()
    header_re = re.compile(rf"^##\s+\[?v?{re.escape(version)}\]?(?:\s|$|-)")
    next_header_re = re.compile(r"^##\s+")
    collecting = False
    collected: list[str] = []
    for line in lines:
        if not collecting:
            if header_re.match(line):
                collecting = True
            continue
        if next_header_re.match(line):
            break
        collected.append(line)
    return "\n".join(collected).strip()


def build_local_manifest(
    repo: str | None = None,
) -> dict[str, object]:
    version, build_number = parse_pubspec_version()
    repo_name = repo or os.environ.get("GITHUB_REPOSITORY", "dwicao/antigravity-go")
    notes = extract_changelog_notes(version)
    return {
        "version": version,
        "buildNumber": build_number,
        "tag": f"v{version}",
        "changelogUrl": f"https://github.com/{repo_name}/blob/main/CHANGELOG.md",
        "releaseNotes": notes,
    }


def write_synced_files(repo: str | None = None) -> dict[str, object]:
    manifest = build_local_manifest(repo=repo)
    payload = json.dumps(manifest, indent=2) + "\n"
    ASSET_VERSION_JSON.parent.mkdir(parents=True, exist_ok=True)
    ROOT_VERSION_JSON.write_text(payload, encoding="utf-8")
    ASSET_VERSION_JSON.write_text(payload, encoding="utf-8")
    return manifest


def check_synced(repo: str | None = None) -> None:
    expected = build_local_manifest(repo=repo)
    for path in (ROOT_VERSION_JSON, ASSET_VERSION_JSON):
        if not path.exists():
            sys.exit(f"Missing synced version file: {path} (run python3 tooling/sync_version.py)")
        actual = json.loads(path.read_text(encoding="utf-8"))
        if actual.get("version") != expected["version"] or actual.get("buildNumber") != expected["buildNumber"]:
            sys.exit(
                f"{path} is out of sync ({actual.get('version')}+{actual.get('buildNumber')}) "
                f"vs pubspec.yaml ({expected['version']}+{expected['buildNumber']}). "
                "Run python3 tooling/sync_version.py"
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="Verify version.json matches pubspec.yaml")
    parser.add_argument("--repo", default=None, help="GitHub owner/repo override")
    args = parser.parse_args()

    if args.check:
        check_synced(repo=args.repo)
        print("version.json and app/assets/version.json match app/pubspec.yaml")
        return

    manifest = write_synced_files(repo=args.repo)
    print(f"Synced version {manifest['version']}+{manifest['buildNumber']} -> version.json & app/assets/version.json")


if __name__ == "__main__":
    main()

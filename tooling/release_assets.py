#!/usr/bin/env python3
"""Package signed Antigravity Go APKs, SHA256SUMS, update.json, version.json, and RELEASE_NOTES.md into dist/."""

import hashlib
import json
import os
import pathlib
import shutil
import sys

from sync_version import extract_changelog_notes, parse_pubspec_version

ROOT = pathlib.Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
APK_DIR = ROOT / "app" / "build" / "app" / "outputs" / "flutter-apk"
AOSP_TESTKEY_FP = "a40da80a59d170caa950cf15c18c454d47a39b26989d8b640ecd745ba71bf5dc"


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def build_release_notes_markdown(
    version: str,
    tag: str,
    changelog_notes: str,
    repo: str,
    commit_sha: str,
) -> str:
    sections = []
    if changelog_notes.strip():
        sections.append(f"## What's New in {tag}\n\n{changelog_notes.strip()}")
    else:
        sections.append(f"## Antigravity Go {version}")
    sections.append(
        "---\n\n"
        f"- **Version:** `{version}` (`{tag}`)\n"
        + (f"- **Commit:** `{commit_sha}`\n" if commit_sha else "")
        + f"- **Signing key (AOSP testkey SHA-256):** `{AOSP_TESTKEY_FP}`\n"
        + f"- **Full Changelog:** https://github.com/{repo}/blob/main/CHANGELOG.md"
    )
    return "\n\n".join(sections).strip() + "\n"


def main() -> None:
    version, build_number = parse_pubspec_version()
    repo = os.environ.get("GITHUB_REPOSITORY", "dwicao/antigravity-go")
    tag = os.environ.get("INPUT_TAG") or f"v{version}"
    commit_sha = os.environ.get("GITHUB_SHA", "").strip()
    changelog_notes = extract_changelog_notes(version)

    if DIST.exists():
        shutil.rmtree(DIST)
    DIST.mkdir(parents=True, exist_ok=True)

    checksums = []
    assets = {}
    for flavor in ("arm64", "x64"):
        src = APK_DIR / f"app-{flavor}-release.apk"
        if not src.exists():
            continue
        dest_name = f"antigravity-go-{version}-{flavor}.apk"
        dest = DIST / dest_name
        shutil.copy2(src, dest)
        digest = sha256_file(dest)
        checksums.append(f"{digest}  {dest_name}")
        assets[flavor] = {
            "name": dest_name,
            "sha256": digest,
            "size": dest.stat().st_size,
            "url": f"https://github.com/{repo}/releases/download/{tag}/{dest_name}",
        }

    if not assets:
        sys.exit(f"No release APKs found in {APK_DIR}")

    (DIST / "SHA256SUMS").write_text("\n".join(checksums) + "\n", encoding="utf-8")

    page_url = f"https://github.com/{repo}/releases/tag/{tag}"
    changelog_url = f"https://github.com/{repo}/blob/main/CHANGELOG.md"
    update_meta = {
        "version": version,
        "buildNumber": build_number,
        "tag": tag,
        "name": f"Antigravity Go {version}",
        "page": page_url,
        "changelogUrl": changelog_url,
        "releaseNotes": changelog_notes,
        "assets": assets,
    }
    encoded = json.dumps(update_meta, indent=2) + "\n"
    (DIST / "update.json").write_text(encoded, encoding="utf-8")
    (DIST / "version.json").write_text(encoded, encoding="utf-8")
    (DIST / "RELEASE_NOTES.md").write_text(
        build_release_notes_markdown(
            version=version,
            tag=tag,
            changelog_notes=changelog_notes,
            repo=repo,
            commit_sha=commit_sha,
        ),
        encoding="utf-8",
    )
    print(f"Packaged {len(assets)} APK(s), version.json, update.json, and RELEASE_NOTES.md into {DIST}")


if __name__ == "__main__":
    main()

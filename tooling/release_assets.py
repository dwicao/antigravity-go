#!/usr/bin/env python3
"""Package signed Antigravity Go APKs, SHA256SUMS, and update.json into dist/."""

import hashlib
import json
import os
import pathlib
import re
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
APK_DIR = ROOT / "app" / "build" / "app" / "outputs" / "flutter-apk"


def pubspec_version() -> str:
    text = (ROOT / "app" / "pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"^version:\s*([^+\s]+)", text, re.MULTILINE)
    if not match:
        sys.exit("version not found in app/pubspec.yaml")
    return match.group(1)


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    version = pubspec_version()
    repo = os.environ.get("GITHUB_REPOSITORY", "dwicao/antigravity-go")
    tag = os.environ.get("INPUT_TAG") or f"v{version}"

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
    update_meta = {
        "version": version,
        "tag": tag,
        "page": f"https://github.com/{repo}/releases/tag/{tag}",
        "assets": assets,
    }
    (DIST / "update.json").write_text(
        json.dumps(update_meta, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Packaged {len(assets)} APK(s) into {DIST}")


if __name__ == "__main__":
    main()

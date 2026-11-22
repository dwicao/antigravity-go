#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APP="$ROOT/app"

flavor=arm64
mode=release
name=""
code=""

while (($#)); do
  case "$1" in
    -f|--flavor) flavor=${2:?--flavor needs a value}; shift 2 ;;
    --release|--debug|--profile) mode=${1#--}; shift ;;
    --build-name) name=${2:?}; shift 2 ;;
    -n|--build-number) code=${2:?}; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

case "$flavor" in
  arm64|x64) flavors=("$flavor") ;;
  all) flavors=(arm64 x64) ;;
  *) echo "Invalid flavor: $flavor" >&2; exit 1 ;;
esac

if [[ -z "$name" ]]; then
  name=$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' "$APP/pubspec.yaml")
fi
if [[ -z "$code" ]]; then
  code=$(python3 "$ROOT/tooling/build_number.py")
fi

platform_of() {
  case "$1" in
    arm64) echo android-arm64 ;;
    x64) echo android-x64 ;;
  esac
}

echo "Antigravity Go $name ($code) · $mode · ${flavors[*]}"
for f in "${flavors[@]}"; do
  (
    cd "$APP"
    flutter build apk "--$mode" \
      --flavor "$f" \
      --target-platform "$(platform_of "$f")" \
      --build-name "$name" \
      --build-number "$code"
  )
done

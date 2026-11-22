#!/usr/bin/env bash
# Builds static native Android shell binaries (GNU Bash + BusyBox POSIX utilities)
# for arm64-v8a and x86_64 into app/android/app/src/main/jniLibs/<abi>/ so
# Antigravity CLI (`agy`) has `bash`, `sh`, `ls`, `find`, `grep`, `sed`, `awk`,
# `tar`, etc. in $PATH on any unrooted Android device.
set -euo pipefail

ROOT=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
JNI_DIR="$ROOT/app/android/app/src/main/jniLibs"
CACHE_DIR="$ROOT/.cache/shell-tools"
mkdir -p "$CACHE_DIR"

BASH_VERSION="5.2.37"
BASH_TARBALL="$CACHE_DIR/bash-${BASH_VERSION}.tar.gz"
BASH_URLS=(
  "https://ftpmirror.gnu.org/bash/bash-${BASH_VERSION}.tar.gz"
  "https://mirrors.kernel.org/gnu/bash/bash-${BASH_VERSION}.tar.gz"
  "https://ftp.gnu.org/gnu/bash/bash-${BASH_VERSION}.tar.gz"
)

if [[ ! -s "$BASH_TARBALL" ]]; then
  for url in "${BASH_URLS[@]}"; do
    echo "[shell-tools] Downloading bash ${BASH_VERSION} from $url..."
    if curl -fsSL --retry 3 --connect-timeout 20 "$url" -o "$BASH_TARBALL.tmp"; then
      if gzip -t "$BASH_TARBALL.tmp" 2>/dev/null; then
        mv "$BASH_TARBALL.tmp" "$BASH_TARBALL"
        break
      fi
    fi
    rm -f "$BASH_TARBALL.tmp"
  done
fi
[[ -s "$BASH_TARBALL" ]] || { echo "Failed to download bash-${BASH_VERSION}.tar.gz" >&2; exit 1; }

build_for_arch() {
  local abi="$1"
  local platform="$2"
  local expected_machine="$3"
  local out_dir="$JNI_DIR/$abi"
  mkdir -p "$out_dir"

  echo "[shell-tools] Building static busybox + bash for $abi ($platform)..."
  docker run --rm --platform "$platform" \
    -v "$CACHE_DIR:/cache:ro" \
    -v "$out_dir:/out" \
    alpine:3.20 /bin/sh -euxc '
      apk add --no-cache build-base busybox-static ncurses-dev ncurses-static
      cp /bin/busybox.static /out/libbusybox.so
      strip /out/libbusybox.so || true

      rm -rf /tmp/bash-src && mkdir -p /tmp/bash-src
      tar -xzf "/cache/bash-'"${BASH_VERSION}"'.tar.gz" -C /tmp/bash-src --strip-components=1
      cd /tmp/bash-src
      CC=gcc \
      CFLAGS="-Os -Wno-implicit-function-declaration -Wno-incompatible-pointer-types" \
      LDFLAGS="-static" \
      ./configure \
        --enable-static-link \
        --without-bash-malloc \
        --disable-nls \
        --with-curses
      make -j"$(nproc)"
      strip bash
      cp bash /out/libbash.so
      chmod 0755 /out/libbusybox.so /out/libbash.so

      /out/libbash.so -c "echo verified-bash-\$(/out/libbusybox.so uname -m)"
    '

  for bin in libbash.so libbusybox.so; do
    local target="$out_dir/$bin"
    [[ -s "$target" ]] || { echo "Missing $target" >&2; exit 1; }
    readelf -h "$target" | grep -q "$expected_machine" || {
      echo "$target is not expected ELF machine ($expected_machine)" >&2
      readelf -h "$target" >&2
      exit 1
    }
    if readelf -l "$target" | grep -q "INTERP"; then
      echo "$target must be statically linked (found PT_INTERP)" >&2
      exit 1
    fi
  done
}

build_for_arch "x86_64" "linux/amd64" "X86-64"
build_for_arch "arm64-v8a" "linux/arm64" "AArch64"

echo "[shell-tools] Executing x86_64 static binaries on host to double-check..."
"$JNI_DIR/x86_64/libbash.so" -c '"$1" ls -la /tmp >/dev/null && echo "host-exec-ok"' _ "$JNI_DIR/x86_64/libbusybox.so"

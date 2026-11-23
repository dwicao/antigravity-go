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

BUSYBOX_VERSION="1.36.1"
BUSYBOX_TARBALL="$CACHE_DIR/busybox-${BUSYBOX_VERSION}.tar.bz2"
BUSYBOX_URLS=(
  "https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2"
  "https://sources.buildroot.net/busybox/busybox-${BUSYBOX_VERSION}.tar.bz2"
  "https://distfiles.macports.org/busybox/busybox-${BUSYBOX_VERSION}.tar.bz2"
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

if [[ ! -s "$BUSYBOX_TARBALL" ]]; then
  for url in "${BUSYBOX_URLS[@]}"; do
    echo "[shell-tools] Downloading busybox ${BUSYBOX_VERSION} from $url..."
    if curl -fsSL --retry 3 --connect-timeout 20 "$url" -o "$BUSYBOX_TARBALL.tmp"; then
      if bzip2 -t "$BUSYBOX_TARBALL.tmp" 2>/dev/null; then
        mv "$BUSYBOX_TARBALL.tmp" "$BUSYBOX_TARBALL"
        break
      fi
    fi
    rm -f "$BUSYBOX_TARBALL.tmp"
  done
fi
[[ -s "$BUSYBOX_TARBALL" ]] || { echo "Failed to download busybox-${BUSYBOX_VERSION}.tar.bz2" >&2; exit 1; }

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
      apk add --no-cache build-base bzip2 linux-headers ncurses-dev ncurses-static

      # Build BusyBox from source with SUID/syslog/utmp disabled so Android seccomp
      # does not terminate applet dispatch with SIGSYS (exit 159).
      rm -rf /tmp/bb-src && mkdir -p /tmp/bb-src
      tar -xjf "/cache/busybox-'"${BUSYBOX_VERSION}"'.tar.bz2" -C /tmp/bb-src --strip-components=1
      cd /tmp/bb-src
      make defconfig
      sed -i \
        -e "s/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/" \
        -e "s/^CONFIG_FEATURE_SUID=y/# CONFIG_FEATURE_SUID is not set/" \
        -e "s/^CONFIG_FEATURE_SUID_CONFIG=y/# CONFIG_FEATURE_SUID_CONFIG is not set/" \
        -e "s/^CONFIG_FEATURE_SYSLOG=y/# CONFIG_FEATURE_SYSLOG is not set/" \
        -e "s/^CONFIG_FEATURE_UTMP=y/# CONFIG_FEATURE_UTMP is not set/" \
        -e "s/^CONFIG_FEATURE_WTMP=y/# CONFIG_FEATURE_WTMP is not set/" \
        -e "s/^CONFIG_TC=y/# CONFIG_TC is not set/" \
        -e "s/^CONFIG_FEATURE_TC_INGRESS=y/# CONFIG_FEATURE_TC_INGRESS is not set/" \
        -e "s/^CONFIG_SHA1_HWACCEL=y/# CONFIG_SHA1_HWACCEL is not set/" \
        -e "s/^CONFIG_SHA256_HWACCEL=y/# CONFIG_SHA256_HWACCEL is not set/" \
        .config
      yes "" | make oldconfig >/dev/null 2>&1 || true
      make -j"$(nproc)"
      strip busybox
      cp busybox /out/libbusybox.so

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

      ln -sf /out/libbusybox.so /tmp/busybox
      ln -sf /out/libbusybox.so /tmp/ls
      /out/libbash.so -c "echo verified-bash-\$(/tmp/busybox uname -m)"
      /tmp/ls /tmp >/dev/null
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
ln -sf "$JNI_DIR/x86_64/libbusybox.so" /tmp/test-busybox-host
ln -sf "$JNI_DIR/x86_64/libbusybox.so" "$CACHE_DIR/ls"
"$JNI_DIR/x86_64/libbash.so" -c '"$1" /tmp >/dev/null && echo "host-exec-ok"' _ "$CACHE_DIR/ls"
rm -f /tmp/test-busybox-host "$CACHE_DIR/ls"

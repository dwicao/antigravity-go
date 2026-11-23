#!/usr/bin/env bash
# Builds static native Android shell binaries (GNU Bash, BusyBox POSIX utilities,
# and lightweight PTY host) for arm64-v8a and x86_64 into
# app/android/app/src/main/jniLibs/<abi>/ so Antigravity CLI (`agy`) and the
# embedded terminal run cleanly on any unrooted Android device.
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

  echo "[shell-tools] Building static busybox + bash + pty host for $abi ($platform)..."
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

      cat <<'\''PTYEOF'\'' > /tmp/pty_host.c
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static int write_all(int fd, const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
            return -1;
        }
        off += (size_t)n;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s <cols> <rows> <ctrl_fifo_or_dash> <cmd> [args...]\n", argv[0]);
        return 2;
    }
    int cols = atoi(argv[1]);
    int rows = atoi(argv[2]);
    if (cols < 1) cols = 80;
    if (rows < 1) rows = 24;
    const char *ctrl_path = argv[3];

    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = (unsigned short)cols;
    ws.ws_row = (unsigned short)rows;

    int master_fd = -1;
    int slave_fd = -1;
    if (openpty(&master_fd, &slave_fd, NULL, NULL, &ws) != 0) {
        perror("openpty");
        return 1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        close(master_fd);
        close(slave_fd);
        return 1;
    }

    if (pid == 0) {
        close(master_fd);
        setsid();
        ioctl(slave_fd, TIOCSCTTY, 0);
        dup2(slave_fd, STDIN_FILENO);
        dup2(slave_fd, STDOUT_FILENO);
        dup2(slave_fd, STDERR_FILENO);
        if (slave_fd > 2) close(slave_fd);
        execvp(argv[4], &argv[4]);
        _exit(127);
    }

    close(slave_fd);

    int ctrl_fd = -1;
    if (ctrl_path != NULL && strcmp(ctrl_path, "-") != 0 && ctrl_path[0] != '\0') {
        mkfifo(ctrl_path, 0600);
        ctrl_fd = open(ctrl_path, O_RDWR | O_NONBLOCK);
    }

    int stdin_open = 1;
    char buf[8192];
    char ctrl_buf[128];
    size_t ctrl_len = 0;

    while (1) {
        struct pollfd fds[3];
        int nfds = 0;
        int idx_master = -1, idx_stdin = -1, idx_ctrl = -1;

        idx_master = nfds;
        fds[nfds].fd = master_fd;
        fds[nfds].events = POLLIN;
        fds[nfds].revents = 0;
        nfds++;

        if (stdin_open) {
            idx_stdin = nfds;
            fds[nfds].fd = STDIN_FILENO;
            fds[nfds].events = POLLIN;
            fds[nfds].revents = 0;
            nfds++;
        }

        if (ctrl_fd >= 0) {
            idx_ctrl = nfds;
            fds[nfds].fd = ctrl_fd;
            fds[nfds].events = POLLIN;
            fds[nfds].revents = 0;
            nfds++;
        }

        int rc = poll(fds, (nfds_t)nfds, -1);
        if (rc < 0) {
            if (errno == EINTR) continue;
            break;
        }

        if (idx_stdin >= 0 && (fds[idx_stdin].revents & (POLLIN | POLLERR | POLLHUP))) {
            ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
            if (n > 0) {
                if (write_all(master_fd, buf, (size_t)n) < 0) break;
            } else if (n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN)) {
                stdin_open = 0;
            }
        }

        if (idx_ctrl >= 0 && (fds[idx_ctrl].revents & POLLIN)) {
            ssize_t n = read(ctrl_fd, ctrl_buf + ctrl_len, sizeof(ctrl_buf) - 1 - ctrl_len);
            if (n > 0) {
                ctrl_len += (size_t)n;
                ctrl_buf[ctrl_len] = '\0';
                char *nl = strchr(ctrl_buf, '\n');
                while (nl != NULL) {
                    *nl = '\0';
                    unsigned int nc = 0, nr = 0;
                    if (sscanf(ctrl_buf, "%u %u", &nc, &nr) == 2 && nc >= 1 && nr >= 1) {
                        struct winsize nws;
                        memset(&nws, 0, sizeof(nws));
                        nws.ws_col = (unsigned short)(nc > 2000 ? 2000 : nc);
                        nws.ws_row = (unsigned short)(nr > 2000 ? 2000 : nr);
                        ioctl(master_fd, TIOCSWINSZ, &nws);
                        kill(-pid, SIGWINCH);
                    }
                    size_t remain = ctrl_len - (size_t)(nl - ctrl_buf + 1);
                    memmove(ctrl_buf, nl + 1, remain);
                    ctrl_len = remain;
                    ctrl_buf[ctrl_len] = '\0';
                    nl = strchr(ctrl_buf, '\n');
                }
                if (ctrl_len >= sizeof(ctrl_buf) - 1) ctrl_len = 0;
            }
        }

        if (idx_master >= 0 && (fds[idx_master].revents & (POLLIN | POLLERR | POLLHUP))) {
            ssize_t n = read(master_fd, buf, sizeof(buf));
            if (n > 0) {
                write_all(STDOUT_FILENO, buf, (size_t)n);
            } else if (n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN)) {
                break;
            }
        }
    }

    close(master_fd);
    if (ctrl_fd >= 0) close(ctrl_fd);
    int status = 0;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 1;
}
PTYEOF
      gcc -Os -Wall -Wextra -static /tmp/pty_host.c -o /out/libpty.so
      strip /out/libpty.so
      chmod 0755 /out/libbusybox.so /out/libbash.so /out/libpty.so

      ln -sf /out/libbusybox.so /tmp/busybox
      ln -sf /out/libbusybox.so /tmp/ls
      /out/libbash.so -c "echo verified-bash-\$(/tmp/busybox uname -m)"
      /tmp/ls /tmp >/dev/null
      /out/libpty.so 91 33 - /out/libbash.so -c "echo verified-pty"
    '

  for bin in libbash.so libbusybox.so libpty.so; do
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

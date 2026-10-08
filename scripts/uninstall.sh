#!/usr/bin/env bash
#
# uninstall.sh — reverse of install.sh.
#
# Unregisters the module from DKMS for every kernel, removes the staged source,
# the firmware/config, and unloads the module if it is loaded. Leaves no
# init-system configuration behind, because none was ever written.
#
set -euo pipefail

MODULE_NAME="zt9101_ztopmac_usb"
CFG_DIR="/usr/lib/zt9101"

info() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo ./scripts/uninstall.sh" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/src"

# Prefer parsing dkms.conf from the repo; fall back to whatever is in /usr/src.
DKMS_NAME="zt9101"
DKMS_VER=""
if [ -f "$SRC/dkms.conf" ]; then
  # shellcheck disable=SC1090
  DKMS_NAME="$( . "$SRC/dkms.conf"; echo "${PACKAGE_NAME:-$DKMS_NAME}")"
  DKMS_VER="$(  . "$SRC/dkms.conf"; echo "${PACKAGE_VERSION:-}")"
fi
if [ -z "$DKMS_VER" ]; then
  # e.g. /usr/src/zt9101-1.2.1800.20241115 -> 1.2.1800.20241115
  for d in /usr/src/"$DKMS_NAME"-*; do
    [ -d "$d" ] || continue
    DKMS_VER="${d##*/"$DKMS_NAME"-}"
    break
  done
fi

# ------------------------------------------------------------ unload first ---
# Unloading must happen before the built artifacts are deleted.
if lsmod | grep -q "^$MODULE_NAME"; then
  info "unloading $MODULE_NAME"
  if ! modprobe -r "$MODULE_NAME" 2>/dev/null; then
    warn "modprobe -r failed (device busy?) — continuing; unplug the dongle and reboot"
  fi
fi

# ------------------------------------------------------------- DKMS removal --
if command -v dkms >/dev/null 2>&1 && [ -n "$DKMS_VER" ]; then
  if dkms status -m "$DKMS_NAME" -v "$DKMS_VER" 2>/dev/null | grep -q .; then
    info "removing $DKMS_NAME/$DKMS_VER from DKMS"
    dkms remove "$DKMS_NAME/$DKMS_VER" --all 2>/dev/null \
      || warn "dkms remove reported errors (already gone?)"
  else
    info "not registered with DKMS"
  fi
else
  info "dkms not available or version unknown — skipping DKMS removal"
fi

# ------------------------------------------------------------- file removal --
info "removing staged source"
# Only ever remove trees this package owns: /usr/src/<name>-<version>.
for d in /usr/src/"$DKMS_NAME"-*; do
  [ -d "$d" ] && rm -rf "$d" && info "  removed $d"
done

# Built module copies, for kernels whose DKMS entry we could not remove.
info "removing built modules"
for ko in /lib/modules/*/updates/dkms/"$MODULE_NAME".ko* ; do
  [ -e "$ko" ] || continue
  rm -f "$ko"
  info "  removed $ko"
done

if [ -d "$CFG_DIR" ]; then
  info "removing $CFG_DIR"
  rm -rf "$CFG_DIR"
fi

# Belt and braces: older builds of this driver installed autoload config.
for f in /etc/modules-load.d/zt9101.conf /etc/openrc/conf.d/zt9101; do
  [ -e "$f" ] && rm -f "$f" && info "removed stale $f"
done

depmod -a >/dev/null 2>&1 || true
command -v udevadm >/dev/null 2>&1 && udevadm control --reload >/dev/null 2>&1 || true

echo
info "uninstalled. Unplug and replug the adapter (or reboot) to release it."

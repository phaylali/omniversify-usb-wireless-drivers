#!/usr/bin/env bash
#
# install.sh — permanent DKMS install of the ZT9101 (LV-UW03) WiFi driver.
#
# Works on any distribution: stages the source into /usr/src, registers it with
# DKMS, builds and signs it for every installed kernel that has headers,
# installs the firmware/config, then activates the module.
#
# No init-system-specific configuration is written on purpose. The module is
# autoloaded from its USB modalias by udev (systemd-udev *and* eudev, i.e. also
# Artix/OpenRC/s6/runit/dinit), so nothing needs to know which init you run.
#
set -euo pipefail

MODULE_NAME="zt9101_ztopmac_usb"
CFG_DIR="/usr/lib/zt9101"

info()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight --
[ "$(id -u)" -eq 0 ] || die "run this as root: sudo ./scripts/install.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/src"
[ -f "$SRC/Makefile" ] || die "cannot find driver source at $SRC (run from the repo?)"
[ -f "$SRC/dkms.conf" ] || die "missing $SRC/dkms.conf"

# Read PACKAGE_NAME / PACKAGE_VERSION from the one place they are defined.
# shellcheck disable=SC1090
DKMS_NAME="$(  . "$SRC/dkms.conf"; echo "${PACKAGE_NAME:-}")"
DKMS_VER="$(   . "$SRC/dkms.conf"; echo "${PACKAGE_VERSION:-}")"
[ -n "$DKMS_NAME" ] && [ -n "$DKMS_VER" ] || die "could not parse dkms.conf"

info "module:  $DKMS_NAME/$DKMS_VER"

command -v dkms >/dev/null 2>&1 || die "dkms is not installed (pacman -S dkms / apt install dkms)"

# ---------------------------------------------------- discover the kernels ---
# A kernel qualifies only if its headers are present. Mirrors what the Arch
# alpm DKMS hook does, so this script and the AUR package behave identically.
mapfile -t KVERS < <(
  for d in /lib/modules/*/build/include; do
    [ -d "$d" ] && basename "$(dirname "$d")"
  done | sort -V
)
[ "${#KVERS[@]}" -gt 0 ] || die "no kernel headers found — install them first
  Arch/Artix:  sudo pacman -S linux-headers        (or linux-cachyos-headers,
                                                    linux-lts-headers, ...)
  Debian/Ubuntu: sudo apt install linux-headers-$(uname -r)"

info "kernels with headers: ${KVERS[*]}"

RUNNING="$(uname -r)"
if ! printf '%s\n' "${KVERS[@]}" | grep -qxF "$RUNNING"; then
  warn "headers for the RUNNING kernel ($RUNNING) are missing."
  warn "the module will be built for the other kernels only, and will NOT load now."
fi

# ------------------------------------------------------------- firmware/cfg --
info "installing firmware and config to $CFG_DIR"
install -d "$CFG_DIR/fw"
install -m 644 "$SRC"/fw/*.bin        "$CFG_DIR/fw/"
install -m 644 "$SRC/wifi.cfg"        "$CFG_DIR/wifi.cfg"

# ------------------------------------------------------- stage DKMS source ---
STAGE="/usr/src/$DKMS_NAME-$DKMS_VER"
info "staging source to $STAGE"
dkms remove "$DKMS_NAME/$DKMS_VER" --all >/dev/null 2>&1 || true
rm -rf "$STAGE"
install -d "$STAGE"
# Copy the tree verbatim; the wrapper Makefile resolves its own directory from
# pwd, so DKMS's `cd` into the build dir is what makes plain `make` work.
cp -a "$SRC/." "$STAGE/"

# ----------------------------------------------------- add, build, install ---
info "registering with DKMS"
dkms add "$DKMS_NAME/$DKMS_VER" >/dev/null

FAILED=0
BUILT=0
for k in "${KVERS[@]}"; do
  info "building for $k"
  if dkms build "$DKMS_NAME/$DKMS_VER" -k "$k" >/dev/null 2>&1 \
     && dkms install "$DKMS_NAME/$DKMS_VER" -k "$k" >/dev/null 2>&1; then
    BUILT=$((BUILT + 1))
    printf '    \033[1;32mok\033[0m  %s\n' "$k"
  else
    FAILED=$((FAILED + 1))
    printf '    \033[1;31mFAILED\033[0m %s\n' "$k" >&2
    LOG="/var/lib/dkms/$DKMS_NAME/$DKMS_VER/$k/x86_64/log/make.log"
    [ -f "$LOG" ] && tail -15 "$LOG" >&2
  fi
done

[ "$BUILT" -gt 0 ] || die "build failed for every kernel — see logs above"

depmod -a >/dev/null 2>&1 || true

# --------------------------------------------------------------- activate ----
# Prefer loading immediately so the user does not have to reboot. If the dongle
# is absent this simply registers the USB driver and returns.
info "activating module"
if modprobe "$MODULE_NAME" 2>/dev/null; then
  printf '    \033[1;32mloaded\033[0m %s\n' "$MODULE_NAME"
else
  if printf '%s\n' "${KVERS[@]}" | grep -qxF "$RUNNING"; then
    warn "modprobe failed — check dmesg"
  else
    warn "not loading: no build for the running kernel ($RUNNING)"
  fi
fi

# The dongle may have been enumerated before the module existed, in which case
# udev never fired an event for it. Nudge just our interface so it binds now.
if command -v udevadm >/dev/null 2>&1; then
  for dev in /sys/bus/usb/devices/*; do
    [ -f "$dev/idVendor" ] || continue
    v="$(cat "$dev/idVendor" 2>/dev/null || true)"
    p="$(cat "$dev/idProduct" 2>/dev/null || true)"
    if [ "$v" = "350b" ] && [ "$p" = "9101" ]; then
      name="$(basename "$dev")"
      info "retriggering udev for $name (dongle was already plugged in)"
      udevadm trigger --action=add --sysname-match="$name:1.0" >/dev/null 2>&1 || true
      udevadm settle --timeout=10 >/dev/null 2>&1 || true
      break
    fi
  done
fi

# ---------------------------------------------------------------- verify -----
echo
info "summary"
dkms status | grep -F "$DKMS_NAME" || true
echo
if lsmod | grep -q "^$MODULE_NAME"; then
  printf '    \033[1;32mmodule:  loaded\033[0m\n'
else
  printf '    \033[1;33mmodule:  not loaded (plug the dongle in)\033[0m\n'
fi
if [ -e /sys/class/net/wlan0 ]; then
  printf '    \033[1;32miface:   wlan0 present\033[0m\n'
else
  printf '    iface:   no wlan0 yet\n'
fi
printf '    config:  %s\n' "$CFG_DIR/wifi.cfg"
printf '    firmware:%s (%d files)\n' "$CFG_DIR/fw" "$(find "$CFG_DIR/fw" -name '*.bin' | wc -l)"

if [ "$FAILED" -gt 0 ]; then
  warn "$FAILED kernel(s) failed to build (see above)"
fi
echo
info "done. Connect with:  nmcli device wifi list"

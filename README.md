# Omniversify USB Wireless Drivers — LV-UW03 (ZTOP ZT9101)

A DKMS-packaged Linux driver for the **PIX-LINK LV-UW03** USB WiFi adapter,
heavily patched so that it actually works on a modern kernel and survives
reboots and kernel upgrades.

| | |
|---|---|
| USB ID | `350b:9101` |
| Reported as | `ZTopInc 802.11n NIC` |
| Chipset | ZTOP **ZT9101** |
| Kernel module | `zt9101_ztopmac_usb` |
| Base version | `ZT9101_android_V1.2.1800.20241115` |
| Wi-Fi stack | cfg80211 / nl80211 (not WEXT) |
| License | GPL-2.0 |

---

## Why this exists

You plug the dongle in, `lsusb` sees it, and absolutely nothing else happens.
No `wlan0`, no NetworkManager entry, nothing to click.

The reasons, in the order they defeat most people:

1. **It is not a Realtek rebrand.** The `350b:9101` ID belongs to ZTOP, so every
   guide for `88x2bu`, `rtl8812au` or `rtl88xxau` fails — those are Realtek
   chips with entirely different firmware and register maps.
2. **No in-tree driver will bind.** `rtl8xxxu` has no `new_id` sysfs file for
   this device and refuses it outright.
3. **No distro package existed.** Nothing in the Arch/Artix repositories, and
   nothing in the AUR.
4. **The vendor source does not build as-is.** It targets Android-era kernels,
   uses retired kbuild variables, and assumes you launch it from the source
   directory so it can find `./wifi.cfg`.

So the only route is the vendor source, patched. That is what this repository
is: the upstream driver, the patches needed to compile and run it on current
kernels, and the packaging to make it a normal one-command install.

---

## Install

### Arch, Artix, CachyOS — via the AUR

```sh
yay -S omniversify-usb-wireless-drivers-lv-uw03
```

**You must have kernel headers installed.** DKMS compiles the module against
your running kernel, and Arch-based systems deliberately do *not* ship headers
by default. Match the package to the kernel you actually boot:

```sh
sudo pacman -S linux-headers            # linux
sudo pacman -S linux-cachyos-headers    # linux-cachyos (CachyOS)
sudo pacman -S linux-lts-headers        # linux-lts
sudo pacman -S linux-zen-headers        # linux-zen
```

If headers are missing the package still installs cleanly, but the DKMS build is
skipped and pacman prints a `Missing <kernel> kernel headers` warning. Install
the headers afterwards and run:

```sh
sudo dkms autoinstall
```

Then plug the adapter in. If it was already plugged in while you installed, it
needs one replug (or a reboot) before udev notices that a driver now exists for
it.

### Any distribution — one script

```sh
git clone https://github.com/phaylali/omniversify-usb-wireless-drivers.git
cd omniversify-usb-wireless-drivers
sudo ./scripts/install.sh
```

The script stages the source into `/usr/src`, registers it with DKMS, builds and
signs it for **every** installed kernel that has headers, installs the firmware
and config, and activates the module.

---

## How the module loads — and why it works on Artix

This is the part that usually breaks when a driver is carried across distros.

The driver's USB ID is compiled into the module as a *modalias*:

```
usb:v350Bp9101d0000dc00dsc00dp00icFFiscFFipFFin00
```

Once DKMS installs the module, `depmod` records it in `modules.alias`. When the
dongle is enumerated, the kernel publishes that string in the device's uevent,
and udev's `80-drivers.rules` reacts to it:

```
ENV{MODALIAS}=="?*", RUN{builtin}+="kmod load"
```

That loads the module — with **no init-system-specific configuration at all**.

This matters because the common approach, `/etc/modules-load.d/*.conf`, is a
**systemd-only** mechanism. On Artix with OpenRC it is silently ignored (OpenRC
expects `/etc/openrc/conf.d/modules` instead), and the same is true for the s6,
runit and dinit flavours. A driver package that hardcodes `modules-load.d`
appears to install successfully on Artix and then never loads.

Relying on the modalias sidesteps that entirely. The rule above is shipped by
**systemd-udev** *and* by **eudev** (the udev fork Artix uses), and udev runs
under every one of those init systems. It also means:

- the module loads only when the dongle is actually present, and
- it loads on hot-plug as well as at boot, since udev replays `add` events for
  devices already present during coldplug.

No `.conf` files are installed for any init system. There is nothing to
configure.

---

## Supported kernels

The cfg80211 API changed at five different points across recent kernels, and the
driver carries an explicit guard for each rather than one blanket version check.
Verified building against:

| Kernel | Compiler | Status |
|---|---|---|
| `7.2.8-1-cachyos` | clang 22.1.8 | ✅ built, signed, tested |
| `7.2.8-arch1-2` | gcc 16.2.1 | ✅ built, signed |
| `6.18.52-1-cachyos-lts` | gcc 16.2.1 | ✅ built, signed |

The compiler is auto-detected per target kernel from its `.config`, so plain
`make` is correct on all of them — note that `linux-cachyos-lts` is gcc-built
despite the name.

The version guards are set from the actual upstream `include/net/cfg80211.h` at
each tag:

| Change | First appeared |
|---|---|
| `set_monitor_channel()` gains `struct net_device *dev` | 6.13 |
| `get_tx_power()` gains `unsigned int link_id` | 6.14 |
| `radio_idx` in `set_wiphy_params` / `set_tx_power` / `get_tx_power` | 6.17 |
| `net_device *` → `wireless_dev *` (keys, stations, `new_sta`/`del_sta`) | 7.1 |
| `remain_on_channel()` gains `const u8 *rx_addr` | 7.2 |

`set_default_key()` still takes `net_device *` in every version from 6.12
onwards, so it deliberately carries no guard.

---

## What was patched

Full detail lives in [`DEV_NOTES.md`](DEV_NOTES.md). In brief:

- **kbuild: `EXTRA_CFLAGS` → `ccflags-y`.** `EXTRA_CFLAGS` is dead in modern
  kbuild, so every compiler flag — including `-DCONFIG_LITTLE_ENDIAN`, without
  which `union pn48` is wrong — was being silently discarded.
- **Two-pass Makefile rewritten.** DKMS prepends `KERNELRELEASE=` to every
  `make` it runs, which collided with the branch the Makefile used to tell a
  wrapper invocation apart from kbuild. It now passes an explicit `ZT_KBUILD=1`
  sentinel.
- **cfg80211 / nl80211 port.** 22 version guards, thresholds taken from real
  kernel headers rather than guessed. WEXT mode was built and tested first and
  **rejected**: NetworkManager classifies the interface as *ethernet* with no
  `phy80211`, creates "Wired connection 2", and DHCP fails.
- **A kernel-crashing `/proc` bug.** Four entries under `/proc/net/wlan0/` were
  registered with a NULL `show` function. Reading one oopsed at `RIP: 0010:0x0`,
  and because the dying reader never ran its release callback the refcount
  leaked — which wedged `zt_proc_term()` in `remove_proc_entry`, holding the USB
  device lock and stalling `usb_hub_wq`. `rmmod` then hung in D-state and every
  USB device on that hub was dead until reboot. Fixed with a stub that returns
  EOF.
- **Absolute firmware and config paths.** `cfg` defaulted to `./wifi.cfg`, which
  resolves against the caller's cwd — `/` at boot. The config silently failed to
  open, scan tuning fell back to defaults, and **scans found zero networks**.
  This was the actual root cause of "driver loads but nothing is visible".
  Now `/usr/lib/zt9101/wifi.cfg` with a fallback in `hif_init()`.
- **Compiler auto-detection**, so plain `make` works on clang *and* gcc kernels.

---

## Verify it worked

```sh
dkms status | grep zt9101
lsmod | grep zt9101
ip link show wlan0
nmcli device status
nmcli device wifi list
```

Expected: `dkms status` reports `installed` for each kernel, `wlan0` exists, and
NetworkManager shows it as a `wifi` device — *not* `ethernet`.

Then connect as normal:

```sh
nmcli device wifi list
nmcli device wifi connect "Your-SSID" password "your-passphrase"
```

Sanity check the driver's own state:

```sh
cat /proc/net/wlan0/version
cat /proc/net/wlan0/rx
```

> Do not run these on a build older than this one. Before the NULL-`show` fix,
> reading `/proc/net/wlan0/*` could crash the kernel and hang `rmmod`.

---

## Uninstall

```sh
sudo pacman -Rns omniversify-usb-wireless-drivers-lv-uw03
```

Pacman's DKMS hook unregisters the module from every kernel and removes the
built artifacts.

Without pacman:

```sh
sudo ./scripts/uninstall.sh
```

Either way, unplug and replug the adapter (or reboot) to release it.

---

## Troubleshooting

**`Error! Bad return status for module build on kernel: …`**
Kernel headers are missing or belong to a different kernel. Install
`linux-headers` (or whichever matches your kernel) and re-run
`sudo dkms autoinstall`. Build logs are in
`/var/lib/dkms/<module>/<version>/<kernel>/x86_64/log/make.log`.

**Module builds but `wlan0` never appears.**
Confirm the module is loaded (`lsmod | grep zt9101`). If it is loaded but no
interface shows, the firmware or config is missing — check that
`/usr/lib/zt9101/wifi.cfg` and `/usr/lib/zt9101/fw/` exist, then reload:

```sh
sudo modprobe -r zt9101_ztopmac_usb && sudo modprobe zt9101_ztopmac_usb
```

**NetworkManager sees an *ethernet* device instead of Wi-Fi.**
You are running a WEXT build. This repository builds nl80211 only. Remove any
stray `zt9101` build from `/lib/modules/$(uname -r)/` and reinstall.

**Works until a kernel upgrade, then stops.**
DKMS `AUTOINSTALL` is enabled, but only if the headers for the *new* kernel are
installed at upgrade time. Install them and run `sudo dkms autoinstall`.

**`module verification failed` / kernel taint.**
Modules are signed with the DKMS MOK key (`/var/lib/dkms/mok.key`). If Secure
Boot is enabled and complains, either enrol that key or disable Secure Boot.
Residual taint from an earlier *unsigned* load never clears without a reboot.

**Scans return zero networks.**
Ensure `/usr/lib/zt9101/wifi.cfg` exists. The driver reads it by absolute path;
a missing file means default scan tuning and empty scan results.

---

## Credits

- Upstream vendor driver: Shandong ZTop Microelectronics Co., Ltd
- Linux port this is based on: [`yjun123/ZT9101_vendor_linux_driver`](https://github.com/yjun123/ZT9101_vendor_linux_driver)
- Codeberg fork: [`anlijudavid/driver_wifi_ztopinc`](https://codeberg.org/anlijudavid/driver_wifi_ztopinc)

Packaging, kernel-porting patches and DKMS integration for this repository by
Omniversify.

## License

GPL-2.0 — see [`LICENSE`](LICENSE).

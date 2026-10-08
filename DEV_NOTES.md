# DEV_NOTES — ZT9101 USB WiFi driver (kernel 7.2.8-1-cachyos)

Target hardware: **LV-UW03** dongle, USB `350b:9101` "ZTopInc 802.11n NIC" /
ZTOP ZT9101. Not a Realtek rebrand — no in-tree driver matches that vendor ID
(`rtl8xxxu` has no `new_id` file and refuses to bind), and no AUR package
exists for it.

Upstream: <https://codeberg.org/anlijudavid/driver_wifi_ztopinc>

## Build

```sh
make
```

No flags needed. `platform/platform.mak` probes the *target* kernel's `.config`
for `CONFIG_CC_IS_CLANG=y` and sets `LLVM=1` only when that kernel is
clang-built, so a plain `make` works on all of them:

| kernel | compiler | auto-selected |
|---|---|---|
| `7.2.8-1-cachyos` | clang 22.1.8 | `LLVM=1` |
| `7.2.8-arch1-2` | gcc 16.2.1 | gcc |
| `6.18.52-1-cachyos-lts` | gcc 16.2.1 | gcc |

The CachyOS *lts* kernel is gcc-built despite the name, which is why this has to
be detected per target rather than inferred from the distro.

`KVER` honours `KERNELRELEASE` (which DKMS prepends to every `make`) and falls
back to `uname -r`, so building for a non-running kernel picks the right
headers.

## Patches applied on top of upstream

### 1. kbuild: `EXTRA_CFLAGS` → `ccflags-y`

`EXTRA_CFLAGS` is dead in modern kbuild, so every flag was silently dropped.
Fixed in `mak/linux/Makefile` and `platform/platform.mak`. The latter is where
`-DCONFIG_LITTLE_ENDIAN` was being lost, which broke `union pn48`.

### 2. Two-pass kbuild detection

`mak/linux/Makefile` originally branched on `ifneq ($(KERNELRELEASE),)` to tell
"wrapper invocation" from "kbuild including this file for the object list".
DKMS prepends `KERNELRELEASE=$kernelver` to *every* make it runs, so the outer
wrapper took the second-pass branch, defined no targets, and died with
`No targets. Stop.` The wrapper now passes an explicit `ZT_KBUILD=1` sentinel
into the kbuild sub-make instead.

### 3. API drift

| File | Change | Reason |
|---|---|---|
| `os/linux/hif/usb.c:1114` | `#elseif` → `#elif` | typo, plus `drvwrap` left `usb_driver` in 6.8 |
| `os/linux/os_porting/zt_os_api_timer.c` | `del_timer` → `timer_delete` (≥6.15) | symbol renamed |
| `os/linux/os_priv.h` | local `zt_strncpy_impl` | kernel 7.x neither declares nor exports `strncpy` |

### 4. cfg80211 / nl80211 port (`os/linux/cfg80211/zt_cfg80211.c`)

22 version guards. `CONFIG_WIFI_FRAMEWORK = nl80211` in `src/Makefile`.

The first cut used one blanket `>= KERNEL_VERSION(7, 0, 0)` for everything. That
built on 7.2 but **failed on 6.18**, because the real cfg80211 changes landed at
five different points. Thresholds below were read from the actual upstream
headers (`include/net/cfg80211.h` at each tag), not guessed:

| change | first version | guards |
|---|---|---|
| `set_monitor_channel` gains `struct net_device *dev` | **6.13** | 1 |
| `get_tx_power` gains `unsigned int link_id` | **6.14** | 1 |
| `radio_idx` in `set_wiphy_params` / `set_tx_power` / `get_tx_power` | **6.17** | 3 |
| `net_device *` → `wireless_dev *` (keys, stations, `new_sta`/`del_sta`) | **7.1** | 16 |
| `remain_on_channel` gains `const u8 *rx_addr` | **7.2** | 1 |

The `7.0.0` guess was wrong for *all five*. In particular a 7.0 kernel would
have received `wireless_dev` for `add_key` while still wanting `net_device`.

`set_default_key` takes `net_device` in every version from 6.12 to 7.2, so it
correctly carries no guard.

WEXT mode was built and tested first — it loads and registers WEXT handlers,
but NetworkManager 1.58.1 classifies the interface as **ethernet** (no
`phy80211`), creates "Wired connection 2", and DHCP fails. Rejected.

### 5. Proc file NULL-function oops (root cause of the wedged kernel)

`os/linux/proc.c`:

```c
zt_s32(*show)(struct seq_file *, void *) = hdl->show ? hdl->show : 0;
return single_open(file, show, private);
```

Four entries in `proc_hdls[]` are registered with `show = NULL` — `set_rate`,
`chipreset`, `mp`, `cob` (write-only). `single_open()` stored that NULL and the
first read jumped to address 0 inside `seq_read_iter` → `RIP: 0010:0x0` oops.

Fixed by substituting a `zt_proc_show_stub` that returns 0, so reads return EOF.
Verified: all 14 readable entries under `/proc/net/wlan0/` now return data and
the module stays `Live`.

**Why this matters beyond the oops:** the dying `cat` never ran its release
callback, leaking the `/proc/net/wlan0/*` refcount. `zt_proc_term()` then
blocked forever in `remove_proc_entry` → `proc_entry_rundown`, which held the
USB device lock, which in turn stalled `usb_hub_wq`. Result: rmmod in
uninterruptible sleep, driver stuck at refcount `-1` state `Unloading`, and all
USB hotplug on that hub dead until reboot. **Never read `/proc/net/wlan0/*` on
a build older than this fix.**

The reboot that followed stalled once because systemd waited on that D-state
task; a second reboot came up clean. One-off, explained by the above.

### 6. Absolute firmware/config paths

`cfg` was `./wifi.cfg` and `wifi.cfg` had `fw=./fw/…`. Both resolve against the
`insmod` process's cwd, which is `/` at boot, so on a fresh start the config
failed to open, `cfg_size` became 0, the scan tuning (`scan_prb_times`,
`scan_que_deep`, `scan_ch_to`, …) fell back to defaults, and firmware lookup
resolved to a directory. **This was the root cause of scans finding zero BSS.**

- `os/linux/hif/hif.c`: default `cfg = "/usr/lib/zt9101/wifi.cfg"` (still a
  `module_param`, so overridable via modprobe.d)
- `wifi.cfg`: absolute `fw=` / `fw1=` paths
- `hif_init()`: falls back to the default firmware paths if `fw=` is absent

Installed system-wide:

```
/usr/lib/zt9101/wifi.cfg
/usr/lib/zt9101/fw/*.bin
```

### 7. `Incorrect netdev->dev_addr` warning on every open

`netdev_WARN(dev, "Incorrect netdev->dev_addr")` fired in `dev_addr_check()`
(`net/core/dev_addr_lists.c`) from `__dev_open`, i.e. the moment NetworkManager
brought `wlan0` up — on **every** clean module load, not just during reconnect
races. It taints the kernel with `W`.

Since v5.15 `dev->dev_addr` is a pointer *into* the `dev_addrs` rb-tree entry,
and the kernel keeps a parallel `dev->dev_addr_shadow[MAX_ADDR_LEN]` that
`dev_addr_check()` memcmp's against over all 32 bytes. The sanctioned writer,
`dev_addr_mod()` → `dev_addr_set()`, updates the entry **and** the shadow and
re-inserts the tree node; a bare `memcpy` into `->dev_addr` updates neither.

Two sites in `os/linux/netdev/ndev_linux.c` were doing bare writes:

| Site | Function | Was | Now |
|---|---|---|---|
| 94 | `ndev_init` | `memcpy(dev_addr)` + `memcpy(dev_addr_shadow)` under `>= 5.17` | `dev_addr_set(ndev, …)` |
| 588 | `ndev_set_mac_addr` | `memcpy(dev_addr)` **only** | `dev_addr_set(pnetdev, …)` |

Site 588 was the actual trigger — NetworkManager applies a randomised
(locally-administered `52:…`) MAC via `ndo_set_mac_address`, which desynced the
shadow from the efuse address already written at init:

```
[D][ndev_set_mac_addr:568] ndev_set_mac_addr:52:3e:2c:fc:02:5e
wlan0: Current addr:  52 3e 2c fc 02 5e 00 …   ← dev_addr          (site 588)
wlan0: Expected addr: 90 91 64 02 49 1d 00 …   ← dev_addr_shadow   (site 94, stale)
```

`dev_addr_set()` exists in every kernel from 6.12 through 7.2 (checked against
the real `include/linux/netdevice.h` at each tag), so it needs no version
guard. The direct writes also silently corrupted the rb-tree key, since the
node's bytes changed without a `rb_erase`/re-insert.

## DKMS install (persistence)

`dkms.conf` lives at the source root:

```conf
PACKAGE_NAME="zt9101"
PACKAGE_VERSION="1.2.1800.20241115"
AUTOINSTALL="yes"
MAKE[0]="make"
BUILT_MODULE_NAME[0]="zt9101_ztopmac_usb"
DEST_MODULE_LOCATION[0]="/updates"
```

`MAKE[0]` is deliberately bare: DKMS `cd`s into the build directory itself, and
it prepends `KERNELRELEASE=` and appends `LLVM=1` on its own (it detects clang
from `vmlinux`'s `.comment`). Supplying `make -C $kernel_source_dir M=…` — the
DKMS default — would break, because our top-level Makefile is a wrapper, not a
kbuild object Makefile.

Registered by the AUR package for every installed kernel that has both headers
**and** a module tree; `dkms status`:

```
zt9101/1.2.1800.20241115, 6.18.52-1-cachyos-lts, x86_64: installed
zt9101/1.2.1800.20241115, 7.2.8-1-cachyos,      x86_64: installed
```

`7.2.8-arch1-2` is skipped on this machine, correctly: `linux-headers` for it is
installed but the `linux` package itself is not, so `/lib/modules/7.2.8-arch1-2/`
contains only `build/` and `vdso/` — there is no `kernel/` tree to install a
module into and nothing bootable. Arch's alpm DKMS hook refuses such trees
(`Missing <kver> kernel modules tree`); the earlier manual `dkms install -k` run
had force-created `updates/dkms/` there, which is why it used to appear.

### Autoload — udev modalias, no init-specific config

**No `.conf` file is installed for any init system.** The USB ID is in the
module as a modalias:

```
usb:v350Bp9101d0000dc00dsc00dp00icFFiscFFipFFin00
```

`depmod` records it in `modules.alias`; the *interface* node (e.g. `1-5:1.0`,
**not** the device node `1-5`, which carries no modalias) publishes it in its
uevent, and udev's `80-drivers.rules` fires:

```
ENV{MODALIAS}=="?*", RUN{builtin}+="kmod load"
```

Verified by `rmmod` + `udevadm trigger --sysname-match='1-5:1.0'` → module
autoloaded, `phy`/`wlan0` recreated, NM reconnected.

This is deliberate and is what makes the package portable: `/etc/modules-load.d`
is **systemd-only**, whereas OpenRC expects `/etc/openrc/conf.d/modules` (s6,
runit and dinit each differ again). Hardcoding `modules-load.d` makes a package
install cleanly on Artix and then never load. `80-drivers.rules` ships with both
**systemd-udev and eudev** (Artix), and udev runs under every one of those inits.

Notes:
- DKMS signs each module with `/var/lib/dkms/mok.key` ("DKMS module signing
  key"), so **no `module verification failed` taint**. Any taint seen in a live
  session is residue from the earlier unsigned `insmod` — kernel taint never
  clears without a reboot.
- The `arch1-2` module stays uncompressed (`.ko`) because that kernel has
  `CONFIG_MODULE_COMPRESS` off; the two CachyOS kernels produce `.ko.zst`.

## ZTPROBE instrumentation (removed)

Three `printk`s were added to localise the zero-BSS scan failure, then removed
once the real cause (§6, relative paths) was found. They had been flooding the
ring buffer at **~26 messages/second**, evicting all boot messages within a
minute. The shipped source and all three installed modules contain **zero**
`ZTPROBE` strings.

## Status

- **Working.** `wlan0` associates with the AP, gets `192.168.100.17/24`,
  gateway `192.168.100.1`, `nmcli connectivity: full`, ping to `1.1.1.1` at
  0% loss (~38 ms).
- Scans return **3 BSS** (was zero), and `chip_reset` loops are gone — zero
  occurrences where previously every ~25-45 s.
- Firmware downloads correctly: `download firmware fullpath:/usr/lib/zt9101/fw/…`,
  `FW1 Ver: 2.8.6.2`, `bulk download firmware ok`, `zt_power_on success`.
- Persistent across reboot via DKMS + `modules-load.d`; NM profile has
  `autoconnect: yes`.
- Steady-state kernel log is quiet: 0 `WARNING`, 0 `ZTPROBE`, 0 verification
  failures, 0 oops/BUG (the `RIP: 0010` lines inside a WARN are just stack
  frames — a real oops also prints `Kernel panic` / `BUG: unable to handle` /
  `Oops:`).
- Module is signed; `rmmod`/`modprobe` cycles cleanly (the proc fix holds).
- Full fresh-install path proven end-to-end: `pacman -U` → alpm hook → DKMS
  build → `modules.alias` → `udevadm trigger` autoloads → NM autoconnects.

### Known non-fatal warnings

Six `WARNING:` traces fire once during an association:

- `dev_addr_lists.c:650` — **fixed**, see §7. Gone after switching both
  `dev_addr` writes to `dev_addr_set()`.
- Five inside `zt_msg_new` failure paths (`mlme.c:1744`, `auth.c:881`,
  `assoc.c:1024`, `zt_cfg80211.c:948`, `mlme.c:1570`), all within the same
  2-second window. Observed only during a forced `rmmod`/`modprobe` reconnect
  race; **0 warnings** across subsequent steady-state operation, and the
  association succeeds anyway. Treat as noise unless they start appearing
  during normal boot association.

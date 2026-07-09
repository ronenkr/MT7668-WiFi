# Port MT7668 USB WiFi driver to kernel 6.8 + add Samsung TV dongle USB ID

## Context

The dongle pulled from a Samsung TV is USB ID `04e8:20b1` — Samsung's OEM branding of a MediaTek **MT7668AUN** (WiFi 5 + BT 5.0 combo). It's plugged in now. There is no mainline WiFi driver for this chip; this repo carries the out-of-tree vendor driver (gen4, from a 5.4.213 kernel). Two gaps: (1) the driver doesn't build on 6.8 — its newest version guard is `KERNEL_VERSION(5,3,0)`; (2) the USB ID table only lists MediaTek reference IDs (`0e8d:7668`), not `04e8:20b1`.

**Goal:** `wlan_mt76x8_usb.ko` builds on `6.8.0-124-generic`, binds the dongle's WiFi interface, scans and connects.

**Verified up front** (trial builds + device inspection + header archaeology; no published 6.x port exists to reuse):
- Dongle interfaces 0–1 = Bluetooth (`e0/01/01`), interface 2 = vendor `ff/ff/ff` = WiFi. The table's `USB_DEVICE_AND_INTERFACE_INFO(..., 0xff, 0xff, 0xff)` style claims only the WiFi interface — BT stays free for `btusb`.
- Pure cfg80211 fullmac driver (no mac80211). Kernel has `CONFIG_CFG80211_WEXT=y`.
- Every fix below was compile-validated against the 6.8 kbuild command lines (incl. `-Werror=incompatible-pointer-types`); all 75 translation units pass. A symbol audit (`nm` vs `Module.symvers`, 306 externals) shows no unresolved symbols after the fixes.
- **gcc-12 must be installed** (`sudo apt install gcc-12`) — kernel built with gcc-12; its config uses a gcc-12-only flag. *User approved.*
- Install style (user choice): proper install to `/lib/modules/$(uname -r)/extra/` + depmod + autoload (no DKMS for now).

Driver source root below: `drv_wlan/MT6632/wlan/`. All fixes keep the driver's existing dual-version guard convention (`#if KERNEL_VERSION(x,y,z) <= LINUX_VERSION_CODE` / `CFG80211_VERSION_CODE`) so 5.4 builds keep working.

## Fix list (verified, file-by-file)

### 1. `os/linux/hif/usb/usb.c` (~line 111) — Samsung dongle ID
Add after the `0x0E8D:0x7668` entry in `mtk_usb_ids[]`:
```c
/* Samsung TV WiFi/BT dongle (WiFi interface, class ff/ff/ff) */
{	USB_DEVICE_AND_INTERFACE_INFO(0x04E8, 0x20B1, 0xff, 0xff, 0xff),
	.driver_info = (kernel_ulong_t)&mt66xx_driver_data_mt7668},
```

### 2. `os/linux/gl_init.c`
- **:113** — `MODULE_SUPPORTED_DEVICE` removed in 5.12 → guard `#if KERNEL_VERSION(5,12,0) > LINUX_VERSION_CODE`.
- **before :338** (`mtk_wlan_ops`) — add static wrappers: `mtk_cfg80211_update_mgmt_frame_registrations` (5.8+: maps `mgmt_frame_regs.interface_stypes` bits for PROBE_REQ/ACTION onto the old per-frame `mtk_cfg80211_mgmt_frame_register`); `*_key_mld` wrappers for add/get/del/set_default_key (6.1+ added `link_id` param — drop it, call existing handlers); `mtk_cfg80211_tdls_mgmt_mld` (6.5+ signature).
- **ops table** — version-guard each entry: `.update_mgmt_frame_registrations` vs `.mgmt_frame_register` (5.8), key ops (6.1), `.tdls_mgmt` (6.5).
- **:2232, :2243** — latent vendor bug `container_of(prAdapter, GLUE_INFO_T, prAdapter)` on a *pointer* member (now a static_assert error) → replace with `prAdapter->prGlueInfo` (back-pointer verified at `include/nic/adapter.h:1082`).
- **:2491** — write through const `dev_addr` (const since 5.17) → `eth_hw_addr_set()` under 5.15 guard; keep old memcpy in `#else`. (`perm_addr` memcpy adjacent is fine.)
- **:539-545** — `wlanSelectQueue` needs a 5.2+ branch `(dev, skb, struct net_device *sb_dev)` atop the existing ladder (was hidden by `-w` — type mismatch with 6.8's `ndo_select_queue`).

### 3. `os/linux/include/gl_os.h` (:981-992)
Matching 5.2+ prototype branch for `wlanSelectQueue` (also fixes the reference in `gl_p2p.c:478` with no change there).

### 4. `os/linux/gl_p2p.c`
- **before :128** (`mtk_p2p_ops`) — same wrapper pattern as gl_init.c: `update_mgmt_frame_registrations` (5.8), `stop_ap` + `set_bitrate_mask` (+`link_id`, guard **6.0**), key ops + `set_mgmt_key` (6.1), `change_beacon` taking `struct cfg80211_ap_update *` → pass `&info->beacon` (guard **6.7**).
- **:133-156** — guard the corresponding ops entries.
- **:947** — `eth_hw_addr_set()` under 5.15 guard (const dev_addr).

### 5. `os/linux/gl_kal.c`
- **:1071-1072** — `cfg80211_roam_info.bssid/.channel` → `.links[0].bssid/.channel` under **6.0** guard.
- **:931-934** — `netif_rx_ni` removed in 5.18 → plain `netif_rx()` under 5.18 guard (netif_rx handles any context since 5.18).
- **:4045-4084** (`kalFileOpen/Read/Write`) — bodies already use `kernel_read/kernel_write`; just guard out the `mm_segment_t`/`get_fs`/`set_fs(KERNEL_DS)` scaffolding with `#if KERNEL_VERSION(5,10,0) > LINUX_VERSION_CODE`.
- **:599** — `eth_hw_addr_set()` under 5.15 guard.
- **:4848-4863** — `kallsyms_on_each_symbol` unexported to modules since 5.12 (**link failure**); its only consumer is already `#if 0` → compile the lookup out under a 5.12 guard.
- **:4994-5000** — two MET proc `file_operations` → `struct proc_ops` (`.proc_write`) under 5.6 guard (registrations at :5047-5048 unchanged).

### 6. `os/linux/gl_cfg80211.c`
- **:868-869** — `scan_request.scan_width` removed in **6.7** → use `0` (`NL80211_BSS_CHAN_WIDTH_20`) on 6.7+.
- **station_parameters HT/VHT/rates moved to `.link_sta_params` in 6.1** → add `MTK_STA_SUP_RATES()/MTK_STA_SUP_RATES_LEN()/MTK_STA_HT_CAPA()/MTK_STA_VHT_CAPA()` accessor macros after the includes (6.1-guarded), then mechanical replace at :2717-2767 and :2820-2870 (replace `_len` occurrences first).

### 7. `os/linux/gl_proc.c` — proc_ops conversion (mandatory; currently "compiles" only because `-w` hides incompatible pointers, broken at runtime)
Convert 9 fops structs (`dbglevel_ops` :933, `csidata_ops` :940, `efusedump_ops` :951, `drivercmd_ops` :959, `cfg_ops` :965, `get_txpwr_tbl_ops` :973, `mcr_ops` :1099, `roam_ops` :1166, `country_ops` :1233) to dual-version `struct proc_ops` under `#if KERNEL_VERSION(5,6,0) <= LINUX_VERSION_CODE` (`read→proc_read`, `write→proc_write`, `open→proc_open`, `release→proc_release`, `llseek→proc_lseek`, drop `.owner`). Registrations (:1311-1361) unchanged.

### 8. `os/linux/platform.c` (:314, :379) — nvram helpers
Bodies call `fd->f_op->read/write` directly (NULL on modern filesystems — dead code even where it compiled) → rewrite with `kernel_read/kernel_write(fd, buf, len, &pos)` (4-arg form exists since 4.14, so 5.4 still builds); guard out the `set_fs` scaffolding (5.10). On Ubuntu the NVRAM path won't exist; driver falls back to `fgNvramAvailable=FALSE` — expected.

### 9. `common/wlan_oid.c` (:75)
Delete `#include <stddef.h>` (kernel dropped `-isystem` in 5.15; file compiles fine without it — no ccflags workaround needed).

### 10. `os/linux/include/gl_kal.h`
Add `#include <linux/sched/clock.h>` near the top — `KAL_GET_HOST_CLOCK()` → `local_clock()` no longer reachable via old include chain (header exists since 4.11, safe unguarded).

### 11. `drv_wlan/MT6632/wlan/Makefile`
- **:20** — remove `ccflags-y += -Werror` (6.8 kbuild's default `-Wmissing-prototypes` etc. trips ~200× on vendor style; the dangerous classes stay fatal via kbuild's own `-Werror=` flags).
- **:4/:6** — change `CONFIG_MTK_COMBO_WIFI_HIF` default `sdio`→`usb` and `MODULE_NAME` → `wlan_mt76x8_usb` (otherwise the .ko is misnamed `wlan_mt76x8_sdio.ko` even when built as USB).
- **`MT7668-WiFi/Makefile.x86`:1** — replace literal `LINUX_SRC=/lib/modules/kernel_version/build` with `/lib/modules/$(shell uname -r)/build`.

## Build & install

```bash
sudo apt install gcc-12
cd MT7668-WiFi
make -f Makefile.x86 hif=usb CONFIG_MTK_COMBO_WIFI_HIF=usb CC=gcc-12 \
     LINUX_SRC=/lib/modules/$(uname -r)/build
# → drv_wlan/MT6632/wlan/wlan_mt76x8_usb.ko (copied to wlan_mt76x8.ko)

# firmware (names built dynamically in gl_kal.c: WIFI_RAM_CODE_MT7668*.bin, mt7668_patch_e*_hdr.bin, ...)
sudo cp 7668_firmware/*.bin 7668_firmware/*.dat 7668_firmware/wifi.cfg /lib/firmware/

# install + autoload (user-chosen)
sudo install -D -m644 drv_wlan/MT6632/wlan/wlan_mt76x8_usb.ko \
     /lib/modules/$(uname -r)/extra/wlan_mt76x8_usb.ko
sudo depmod -a
echo wlan_mt76x8_usb | sudo tee /etc/modules-load.d/mt7668-wifi.conf
```

Caveat: if Secure Boot is enabled, the unsigned module won't load — check `mokutil --sb-state`; if enabled, sign the .ko with a MOK key or disable SB (surface this to the user if it bites).

## Verification (end-to-end)

1. `sudo modprobe wlan_mt76x8_usb` then `dmesg -w`: expect probe on `04e8:20b1` interface 2, ROM patch (`mt7668_patch_e*_hdr.bin`) + RAM code download, `wlan0` appears.
2. `ip link show wlan0` up; `sudo iw dev wlan0 scan | grep SSID` returns neighborhood networks.
3. Connect to the user's AP via NetworkManager (`nmcli dev wifi connect ...`), ping test.
4. Replug the dongle → auto-rebind. Reboot → module autoloads.
5. Smoke-test a `/proc/wlan/dbgLevel` read (validates the proc_ops conversion at runtime).
6. Confirm `btusb` can still claim interfaces 0–1 (BT is out of scope; the `new_id` trick from the user's notes applies unchanged).

## Known runtime watch-items (compile-verified but runtime-untested)
- `update_mgmt_frame_registrations` wrapper derives absolute state per call vs the old delta API — equivalent for this driver's usage; verify P2P probe-req RX if P2P is ever used.
- MLO `link_id` args ignored in all wrappers — correct for this non-MLO 11ac chip.
- NVRAM absent on Ubuntu → driver uses defaults; confirm MAC address looks sane (not random/zero).

## Out of scope / follow-ups
- Bluetooth: `echo "04e8 20b1" | sudo tee /sys/bus/usb/drivers/btusb/new_id` (mainline btusb has MT7668 WMT support) — zero code changes, test after WiFi.
- DKMS packaging (user declined for now; revisit if kernel updates become annoying).
- Commit the port on a branch with the fix list as the commit message (repo is on `main`; will ask before committing).

# MT7668 USB WiFi Driver

Out-of-tree Linux driver for the MediaTek **MT7668** 802.11ac (WiFi 5) USB chip. There is no mainline (in-kernel) driver for this chip — MediaTek never upstreamed it into `mt76`. This is the vendor `gen4` driver (originally extracted from a 5.4.213 vendor kernel used on the PS4 Pro and some Android/TV boxes), ported to build and run on modern kernels.

Verified working on **Ubuntu 22.04 (HWE), kernel 6.8.0-124-generic**, with a genuine MediaTek reference dongle (`0e8d:7668`) and a Samsung OEM-rebranded MT7668AUN dongle pulled from a Samsung Smart TV (`04e8:20b1`). Ubuntu 24.04 ships the same 6.8 kernel series by default, and the build's compiler auto-detection (see below) isn't hardcoded to a GCC version, so it should build there too — see [Ubuntu 24.04 notes](#ubuntu-2404-notes).

## Supported devices

USB IDs matched by `drv_wlan/MT6632/wlan/os/linux/hif/usb/usb.c`:

| VID:PID | Device |
|---|---|
| `0e8d:6632` | MediaTek MT6632 reference |
| `0e8d:7666` | MediaTek MT7666 reference |
| `0e8d:7668` | MediaTek MT7668 reference |
| `04e8:20b1` | Samsung "Wireless_Device" — OEM MT7668AUN (Samsung Smart TVs, and the same silicon shows up in some Amazon Fire TV Stick 4K / PS4 Pro units) |

The Samsung dongle is a combo WiFi+Bluetooth part; only the WiFi interface (vendor-specific, class `ff/ff/ff`) is claimed here. Bluetooth is handled separately by the mainline `btusb` driver (it already has MT7663U/MT7668U support — see `drivers/bluetooth/btusb.c`).

## Markings on the module
WCT734M
A3LWCT730M

## Pinout
Remove the module from TV with the harness, there are 2 rows of pins ,
connect the green pin to green of USB, white to white, and black to black (all next to each other)
and the VCC/RED connect behind the Green pin (it's a black with white stripe pin)

## Build & install

Requires kernel headers for your running kernel (`sudo apt install linux-headers-$(uname -r)`) and CMake 3.16+.

```bash
./build.sh              # configure + build -> drv_wlan/MT6632/wlan/wlan_mt76x8_usb.ko
./build.sh --install    # ...then install the module + firmware and enable autoload (sudo)
```

`build.sh` is a thin wrapper around the CMake configure/build/install steps, equivalent to:

```bash
cmake -S . -B build              # configure: detects kernel headers + a matching compiler
cmake --build build              # build: invokes kbuild, produces the .ko
sudo cmake --install build       # install: module -> /lib/modules/.../extra, firmware -> /lib/firmware,
                                  #          depmod -a, autoload via /etc/modules-load.d
```

Useful `cmake --build build --target <name>`: `driver` (default), `clean-driver` (kbuild clean), `load`/`unload` (insmod/rmmod for quick manual testing).

Configure-time options (`-D<OPTION>=<value>` on the `cmake -S . -B build` line, or passed straight through `build.sh`):

| Option | Default | Meaning |
|---|---|---|
| `KERNEL_DIR` | `/lib/modules/$(uname -r)/build` | Kernel headers/build directory |
| `KERNEL_CC` | auto-detected | Compiler to build with — auto-detected from the running kernel's own build compiler (parsed out of `/proc/version`); override if auto-detection picks the wrong one |

CMake invokes kbuild directly (`make -C $(KERNEL_DIR) M=drv_wlan/MT6632/wlan modules`) — there's no wrapper Makefile anymore. The old `Makefile`, `Makefile.ce`, and `Makefile.x86` were vendor multi-platform build wrappers (SDIO/PCIe/embedded-CE variants); this project targets one specific USB dongle, its kbuild Makefile (`drv_wlan/MT6632/wlan/Makefile`) is already hardcoded to USB, and none of those wrappers had anything left to parameterize, so they were removed.

If Secure Boot is enabled, this unsigned out-of-tree module won't load unless you sign it with an enrolled MOK key or disable Secure Boot.

### Ubuntu 24.04 notes

24.04 defaults to GCC 13 and the same 6.8 kernel series tested here. The compiler auto-detection parses whatever `gcc-NN` the running kernel reports itself built with out of `/proc/version` and looks for a matching `gcc-NN` binary — it isn't pinned to gcc-12, so it should pick up gcc-13 automatically. If `apt` hasn't installed a versioned `gcc-NN` binary matching your kernel, install it explicitly (`sudo apt install gcc-13`) or pass `-DKERNEL_CC=/path/to/compiler`.

## Kernel 6.x port notes

The vendor driver's newest version guard was `KERNEL_VERSION(5,3,0)`; it needed real porting work (not just a recompile) to build and run on 6.8:

- **cfg80211 API churn**: `mgmt_frame_register` → `update_mgmt_frame_registrations` (5.8+), key ops gained an MLO `link_id` parameter (6.1+), `tdls_mgmt` gained `link_id` (6.5+), P2P `stop_ap`/`set_bitrate_mask` gained `link_id` (6.0+), `change_beacon` signature changed (6.7+), `station_parameters` HT/VHT/rate fields moved into `link_sta_params` (6.1+), `cfg80211_roam_info` fields moved into `.links[0]` (6.0+), `scan_request.scan_width` removed (6.7+), `cfg80211_ch_switch_notify()` gained `link_id`/`punct_bitmap` args (6.0+/6.3+).
- **procfs**: all `/proc` entries converted from `struct file_operations` to `struct proc_ops` (mandatory since 5.6).
- **File I/O**: `set_fs()`/`KERNEL_DS`/`mm_segment_t` removed (5.10+) — NVRAM and generic file helpers rewritten around `kernel_read()`/`kernel_write()`.
- Misc: `MODULE_SUPPORTED_DEVICE` removed (5.12+), `eth_hw_addr_set()` required once `net_device.dev_addr` became const (5.15+), `netif_rx_ni()` removed (5.18+), `ndo_select_queue` dropped its fallback-handler argument (5.2+), `kallsyms_on_each_symbol()` unexported from modules (5.12+).
- A latent vendor bug in the TX timer callbacks used `container_of()` on a *pointer* member instead of following it — compiles fine on old GCC/kernels, but trips a `container_of` static assertion on modern kernels.

All fixes keep the driver's existing `#if KERNEL_VERSION(x,y,z) <= LINUX_VERSION_CODE` guard style, so it should still build against the original 5.4 baseline.

### Critical runtime fix: USB autosuspend

`glRegisterBus()` in `usb.c` force-enables `.supports_autosuspend`, but the driver's own vendor-request helper (`mtk_usb_vendor_request()`) never takes a PM reference around its `usb_control_msg()` calls. On a desktop system with the default aggressive autosuspend timeout, the kernel would suspend the device mid-initialization, and every subsequent chip-register read/write would fail with `-EHOSTUNREACH`, the firmware handshake would never complete, and the device would eventually wedge and fail to re-enumerate. **Autosuspend support is now disabled** (`supports_autosuspend = 0`) to fix this.

## Known issues

- `mtk_p2p_cfg80211_scan()` in `gl_p2p_cfg80211.c` builds its scan-request message into a struct whose trailing channel-list field is declared as a fixed `[1]`-element array (an old-style variable-length-struct idiom) but is indexed up to `MAXIMUM_OPERATION_CHANNEL_LIST` (32) — this trips UBSAN `array-index-out-of-bounds` warnings on P2P scans. The backing allocation (`cnmMemAlloc`) is sized correctly, so this hasn't been observed to cause real corruption, but it should be fixed properly (flexible array member, or a correctly-sized fixed array) rather than relying on it being harmless.
- No manufacture/NVRAM calibration data is present on desktop Linux installs (`wlanAdapterStart: load manufacture data fail` is expected/benign) — the driver falls back to the calibration data baked into the firmware blobs.

## Credits

Based on the community-maintained MT7668 WiFi+BT driver sources (originally extracted from PS4 Pro / Android TV vendor kernels), with the CoreELEC MT7668 tree as a cross-reference.

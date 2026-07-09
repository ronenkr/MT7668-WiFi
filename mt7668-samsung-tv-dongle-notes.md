# Samsung TV WiFi/BT Dongle — MediaTek MT7668AUN Notes

## Device Identification

| Field | Value |
|---|---|
| USB ID | `04e8:20b1` (Samsung Electronics Co., Ltd — "Wireless_Device") |
| FCC ID | A3LWCT730M |
| Actual chipset | MediaTek **MT7668AUN** — combo 802.11ac (WiFi 5) + Bluetooth 5.0, USB interface |
| Common hosts | Samsung Smart TVs, Amazon Fire TV Stick 4K, some PS4 Pro variants, Android TV boxes |
| bDeviceClass | 239 (Miscellaneous / Interface Association) |
| bNumInterfaces | 3 |

The `04e8:20b1` ID is Samsung's own OEM re-branding of the chip — the string descriptor says "MediaTek Inc." but the VID:PID doesn't match MediaTek's own reference dongle ID (`0e8d:7668`), which is why Linux doesn't recognize it out of the box even though drivers exist for the underlying silicon.

## Bluetooth — should be workable

Mainline Linux (`btusb`, since ~2019) has explicit MediaTek MT7663U/MT7668U support (`BTUSB_MEDIATEK` code path in `drivers/bluetooth/btusb.c`), which performs the WMT firmware-download handshake this chip needs before it acts as a normal HCI device.

**Problem:** the kernel's device-ID table matches MediaTek's reference VID:PID (`0e8d:7668`), not Samsung's `04e8:20b1`, so `btusb` won't auto-bind.

**Plan:**
```bash
# confirm BT firmware is present (from linux-firmware package)
ls /usr/lib/firmware/mediatek/ | grep -i 7668

# check current dmesg for any existing bind attempt
dmesg | grep -i -E "bluetooth|btusb|mtk"

# force btusb to also claim this VID:PID
echo "04e8 20b1" | sudo tee /sys/bus/usb/drivers/btusb/new_id
dmesg | tail -30
bluetoothctl list
```
If `btusb` binds and dmesg shows the MediaTek WMT setup sequence (register reads, firmware/rom-patch download) completing, Bluetooth should come up normally via `bluetoothctl`.

If it binds but the MTK-specific setup doesn't trigger, the interface number may need to be targeted explicitly — get a full `lsusb -v -d 04e8:20b1` to identify which of the 3 interfaces is the BT one (expected: class `e0`, subclass `01`, protocol `01`, with isoc alt-settings for audio).

## WiFi — no mainline driver exists

MediaTek never upstreamed MT7668 WiFi support into `mt76`. A 2018 linux-wireless mailing list thread concluded the chip's MCU/firmware-download architecture is different enough from the older MT76x0/MT76x2 family that it would need a near-standalone driver — this was never finished or merged. **As of today there is still no in-kernel WiFi driver for this chip.**

**Only existing option:** an out-of-tree community driver pulled from Android/PS4 vendor kernel sources:
- https://github.com/noob404yt/mt7668-wifi-bt
- Mirror: https://github.com/CoreELEC/MT7668

It builds `wlan_mt76x8.ko` plus firmware blobs, and is confirmed working — but only against **kernel 5.4.213**, since that's the vendor kernel it was extracted from.

### Porting plan (5.4 → modern 6.x kernel)

Ubuntu 24.04 runs a 6.8/6.11+ kernel, so this driver needs real porting work, not just a recompile:

1. **Check target kernel version**: `uname -r` — note if it's a GA or HWE kernel (HWE will be further from 5.4).
2. **Clone the driver source** and attempt a build against current kernel headers; catalogue every compile error.
3. **Expect API breaks in these areas** (typical for 5.4-era out-of-tree wifi drivers):
   - `cfg80211_ops` / `mac80211` callback signatures (params added/removed/reordered across kernel releases)
   - `netdev_ops` structure changes
   - Timer API (`timer_list` / `setup_timer` → `timer_setup` migration completed well before 5.4, but later releases changed more)
   - `usb_driver` / URB handling minor signature changes
   - Workqueue and RCU API changes
4. **Fix incrementally**, cross-referencing the diffs between how `mt76` (the in-tree sibling driver family) handles the same callbacks on modern kernels — useful as a reference for correct modern signatures even though `mt76` doesn't support this exact chip.
5. **Firmware**: copy the driver's bundled firmware blobs to `/usr/lib/firmware/` as instructed in the repo.
6. **Test load** with `insmod`/`modprobe`, watch `dmesg` for MCU firmware download and association behavior.

### Realistic alternatives (lower effort)
- **Bluetooth-only use** — treat the dongle as a free BT 5.0 adapter; effectively zero extra work beyond the `new_id` step above.
- **Run the WiFi function under an actual 5.4.x kernel** — a VM, container, or spare board (some Armbian/LibreELEC images for specific S905X3 boxes already carry a patched MT7668 driver) — if the goal is just to get the WiFi radio working somewhere, not necessarily on the main desktop.
- **Full porting project** — most flexible, but the real effort item; best tackled incrementally, one compile error at a time, against the currently running kernel headers.

## References
- linux-wireless mailing list thread on MT7668 vs `mt76` architecture differences (2018)
- `drivers/bluetooth/btusb.c` MediaTek WMT setup patches (Sean Wang, MediaTek, 2018–2019)
- https://github.com/noob404yt/mt7668-wifi-bt (out-of-tree WiFi+BT driver source, kernel 5.4.213 baseline)
- https://github.com/CoreELEC/MT7668 (mirror)

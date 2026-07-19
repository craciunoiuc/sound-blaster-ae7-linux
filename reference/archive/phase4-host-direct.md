# Phase 4 — enable AE-7 on the host directly

**Date:** 2026-07-16
**Root cause confirmed:** Plymouth (`splash`) was conflicting with the AE-7's
PCIe bridge during early boot. NOT the audio driver, NOT PCI enumeration per se.
Removing `splash` fixed boot completely.

**End goal:** use the AE-7 for sound directly on the host Linux system.

## Why this should just work

- Subsystem ID is **`1102:0081`** → the kernel `QUIRK_AE7` matches correctly.
- Bridge is **rev 03** → covered by the in-kernel ASMedia quirks.
- `snd_hda_intel` was blacklisted only as a precaution during diagnosis — it was
  never the actual problem. With boot fixed, the driver should bind cleanly.

## Steps

1. Remove `module_blacklist=snd_hda_intel` from `/etc/default/limine`.
2. Remove the host blacklist: `sudo rm /etc/modprobe.d/blacklist-ca0132.conf`.
3. `sudo limine-update` → reboot.
4. Run `./host/verify-host-audio.sh`.

## Expected results
- `lspci -k -s 14:00.0` shows `Kernel driver in use: snd_hda_intel`
- `lsmod | grep ca0132` shows `snd_hda_codec_ca0132` loaded
- `dmesg | grep ca0132` shows `Sound Blaster AE-7` + `ca0132 DSP downloaded`
- `/proc/asound/cards` lists the AE-7
- Test sound: `speaker-test -c 2 -D plughw:CARD=AE7`

## If it boots but no sound
This is the ca0132 driver-level debugging territory the original
`patch_ca0132.c` rig was built for. Common issues:
- IEC958 (digital) controls active by default → mute them in alsamixer
- `/etc/asound.conf` needs `pcm "CA0132 Analog"`
- DSP firmware `ctefx.bin` missing → `sudo pacman -S alsa-firmware`

## If it hangs on boot
Then the driver path (ca0132 init / BAR2 MMIO) has its own problem after all.
Re-add `module_blacklist=snd_hda_intel`, reboot, and we're back to the
QEMU/VFIO rig with patch 0001 to find the driver-level hang point.

## If the subsystem doesn't report 0081
Earlier `lspci -nnn` showed `1102:0010` (raw device ID) but `lspci -k` showed
`Subsystem: Sound Blaster AE-7`. If the quirk doesn't match, the model override
forces it: `snd_hda_intel.model=ae7` on the kernel cmdline.

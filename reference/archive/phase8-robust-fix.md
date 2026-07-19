# Phase 8 — robust fix (doesn't depend on subsystem device ID)

**Date:** 2026-07-16

## Why the previous fix (0x0081 subsystem override) failed

The log showed all three AMD controllers probing fine but ZERO lines from the
Creative controller. The `PCI_DEVICE_SUB(..., 0x0081)` override didn't match —
because `0x0081` is the *codec's* subsystem ID (what `QUIRK_AE7` in ca0132.c
matches on), NOT the *controller's* PCI function subsystem ID. The controller
function (`1102:0010`) has a different (unknown) subsystem, so the override was
bypassed and it fell through to the `CTHDA` entry → same hang.

## The robust fix: runtime caps override

Instead of matching on a specific subsystem device ID, override at runtime in
`azx_create` — if the controller was matched as `AZX_DRIVER_CTHDA` AND its
subsystem vendor is Creative (`0x1102`), convert it to `AZX_DRIVER_GENERIC`:

```c
if (chip->driver_type == AZX_DRIVER_CTHDA &&
    pci->subsystem_vendor == PCI_VENDOR_ID_CREATIVE) {
    dev_info(..., "CA0132 CTHDA->GENERIC override ...");
    chip->driver_caps = AZX_DRIVER_GENERIC;
    chip->driver_type = AZX_DRIVER_GENERIC;
}
```

This works regardless of the exact subsystem device ID. It fires for any
Creative-branded card that lands on the CTHDA match (which is the bug).

## A note on safety

This also affects real CA0110-IBG X-Fi cards (if they have a Creative subsystem).
But: the X-Fi is obsolete (last sold ~2008), and the wrong-caps hang is far worse
than a theoretical regression. The `snd-ctxfi` driver (if enabled) grabs X-Fi
cards first anyway via the `PCI_ANY_ID` entry below.

## Install (module-only swap)

```bash
sudo cp /home/cez/sound-card/build/staging/lib/modules/7.1.3-dirty/kernel/sound/hda/controllers/snd-hda-intel.ko.zst /lib/modules/7.1.3-dirty/kernel/sound/hda/controllers/snd-hda-intel.ko.zst
sudo depmod -a 7.1.3-dirty
```

Reboot the `linux-ae7dbg` entry.

## What to look for

The FIRST line from the Creative controller should now be:
```
snd_hda_intel 0000:XX:YY.Z: HDACTRLDBG: CA0132 CTHDA->GENERIC override (subsystem 1102:????)
```

That confirms the override fired. Then the normal probe sequence should complete:
```
azx_probe_continue start
azx_first_init ... after hda_intel_init_chip
azx_probe_codecs ... probe_codec OK
after azx_probe_codecs (err=0)
```

If it reaches `after azx_probe_codecs (err=0)` for the Creative device, the
controller hang is FIXED. Then the ca0132 codec driver loads and we test sound.

## ALSO: capture the subsystem ID

The override print shows the actual subsystem (`1102:????`). That value lets us
write the precise upstream patch later. Or run from the blacklisted boot:
```bash
cat /sys/bus/pci/devices/0000:14:00.0/subsystem_device
```

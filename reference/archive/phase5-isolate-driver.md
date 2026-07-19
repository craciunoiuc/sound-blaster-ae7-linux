# Phase 5 — isolate: is it snd_hda_intel (controller) or ca0132 (codec) that hangs?

**Date:** 2026-07-16
**Confirmed:** removing `module_blacklist=snd_hda_intel` → hang. Re-adding it →
boots. So the audio driver stack DOES hang boot (separate from the Plymouth
issue, which is already fixed by dropping `splash`).

**Two-driver stack:** `snd_hda_intel` is the controller driver; `ca0132`
(`snd_hda_codec_ca0132`) is the codec driver that loads on top of it. One of
them hangs. The fix is very different for each, so we isolate before patching.

## The two-driver model (why this matters)

```
snd_hda_intel        ← PCI controller driver (binds to 14:00.0)
   └── snd_hda_codec  ← codec framework
         └── snd_hda_codec_ca0132  ← the CA0132/AE-7 specific driver
```

- If **snd_hda_intel** hangs → it's the controller's probe/corb/rirb setup, or an
  interrupt (MSI) issue. Fix is at the HDA controller layer, possibly a `model=`
  param or an IRQ/MSI workaround.
- If **ca0132** hangs → it's the codec init: BAR2 MMIO map (`pci_iomap`), DSP
  firmware load, or the `ae5_register_set` / `ae7_setup_defaults` path. This is
  exactly what `patch_ca0132.c` + patch 0001 (AE7DBG) targets.

## The isolation test

We need TWO consecutive reboots to fully isolate. The principle: blacklist the
codec only (allow the controller), and see if it boots.

### Test 1 — Allow controller, blacklist codec

Replace the current `module_blacklist=snd_hda_intel` with:
```
module_blacklist=snd_hda_codec_ca0132
```

Full limine cmdline for this test:
```
KERNEL_CMDLINE[default]+="quiet nowatchdog rw root=UUID=cf0cc394-37e9-4774-b6be-57e55351af52 amd_iommu=on iommu=pt loglevel=3 module_blacklist=snd_hda_codec_ca0132"
```

(Keep NO `splash`, keep NO `nomodeset`.)

**Outcomes:**

| Result | Meaning |
|---|---|
| **Boots** | The **controller** (`snd_hda_intel`) loads fine. The **codec** (`ca0132`) is what hangs. → Proceed to Phase 6: build patch 0001 to find the exact ca0132 function. |
| **Hangs** | The **controller** itself (`snd_hda_intel`) hangs, even without the codec. → It's an HDA controller / interrupt / MSI problem. → Try controller-level params (see below). |

### Test 2 (only if Test 1 hangs) — controller-level workarounds

If blacklisting the codec still hangs, the controller is the problem. Try these
on the controller, one at a time:

```
module_blacklist=snd_hda_codec_ca0132 snd_hda_intel.enable_msi=0
```
(disable MSI for the HDA controller — a common hang fix)

then if that still hangs:
```
module_blacklist=snd_hda_codec_ca0132 snd_hda_intel.enable_msi=0 snd_hda_intel.power_save=0
```

then:
```
module_blacklist=snd_hda_codec_ca0132 snd_hda_intel.model=generic
```
(force generic codec handling)

## What to capture after a successful boot

After Test 1 (whether it boots or you move to Test 2), once the system is up,
run:
```bash
lspci -k -s 14:00.0
lsmod | grep snd_hda
dmesg | grep -iE 'snd_hda|ca0132|hda-intel' | tail -20
```
Paste these back — they show exactly which driver is bound and whether the
controller initialized cleanly.

## Decision tree after isolation

```
Test 1 (codec blacklisted, controller allowed)
  ├─ boots → ca0132 codec hangs → Phase 6 (build AE7DBG kernel)
  └─ hangs → controller hangs → controller params (Test 2)
              ├─ enable_msi=0 works → MSI bug, file upstream quirk
              └─ nothing works → deeper controller probe issue
```

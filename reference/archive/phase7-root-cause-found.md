# ROOT CAUSE FOUND — PCI ID collision: CA0132 matched as CA0110-IBG (X-Fi)

**Date:** 2026-07-16

## The smoking gun

The AE-7's HDA controller enumerates as `1102:0010` (Creative CA0132). But in the
`snd_hda_intel` PCI ID table (`sound/hda/controllers/intel.c:2798`):

```c
/* Creative X-Fi (CA0110-IBG) */
/* CTHDA chips */
{ PCI_VDEVICE(CREATIVE, 0x0010),                                       // ← THE COLLISION
  .driver_data = AZX_DRIVER_CTHDA | AZX_DCAPS_PRESET_CTHDA },
{ PCI_VDEVICE(CREATIVE, 0x0012),
  .driver_data = AZX_DRIVER_CTHDA | AZX_DCAPS_PRESET_CTHDA },
```

**The CA0132 (device 0x0010) shares the same PCI device ID as the CA0110-IBG
(Sound Blaster X-Fi).** The driver matches it to `AZX_DRIVER_CTHDA` and applies
`AZX_DCAPS_PRESET_CTHDA`:

```c
#define AZX_DCAPS_PRESET_CTHDA \
	(AZX_DCAPS_NO_MSI | AZX_DCAPS_POSFIX_LPIB |\
	 AZX_DCAPS_NO_64BIT |\
	 AZX_DCAPS_4K_BDLE_BOUNDARY | AZX_DCAPS_SNOOP_OFF)
```

These caps are for the **CA0110-IBG X-Fi controller**, NOT the CA0132. The
CA0132's HDA controller is a standard Intel-spec HDA controller — it should be
treated as `AZX_DRIVER_GENERIC` with normal caps.

## How this explains every symptom

1. **`AZX_DCAPS_NO_MSI`** — MSI disabled, forcing INTx. This explains why
   `enable_msi=0` didn't help (it was already off) AND why the interrupt delivery
   is broken — INTx through the ASMedia PCIe-to-PCI bridge is unreliable.

2. **`AZX_DCAPS_SNOOP_OFF`** — DMA snoop disabled. DMA transactions may not be
   coherent, breaking CORB/RIRB buffer operations.

3. **`AZX_DCAPS_NO_64BIT`** — 32-bit DMA only. May cause DMA allocation failures
   or wrong addresses through the bridge.

4. **The second `azx_init_chip(full_reset=1)`** in the logs: `probe_codec` fails
   (because the chip was misconfigured by the wrong caps), triggering the
   error-recovery reset at `controller.c:1224` (`azx_stop_chip` + `azx_init_chip`).
   The second reset through the bridge hangs.

5. **Why `snd_hda_codec_ca0132` never loads**: the controller never successfully
   probes codecs (it hangs on the reset-recovery loop), so no codec instance is
   ever created.

6. **Why the ca0132 codec driver blacklist didn't matter**: the controller hangs
   before it ever reaches codec loading.

## The fix

Add a subsystem-ID-specific entry for the AE-7 that overrides the CTHDA match,
OR (simpler) change the AE-7 entry to use GENERIC caps. Since the AE-7's
subsystem ID is `1102:0081`, we add a quirk entry BEFORE the 0x0010 CTHDA entry:

```c
/* Sound Blaster AE-7 / AE-9: CA0132 HDA controller, NOT CA0110-IBG X-Fi.
 * Shares device ID 0x0010 with the X-Fi — override with generic caps. */
{ PCI_DEVICE_SUB(PCI_VENDOR_ID_CREATIVE, 0x0010, PCI_VENDOR_ID_CREATIVE, 0x0081),
  .driver_data = AZX_DRIVER_GENERIC | AZX_DCAPS_PRESET_DEFAULT },
```

This must come BEFORE the `PCI_VDEVICE(CREATIVE, 0x0010)` entry so it matches first.

## Why this is consistent with everything observed

- ✅ Card boots when driver blacklisted (controller never misconfigured)
- ✅ Hang is in `snd_hda_intel`, not ca0132 codec (controller caps are wrong)
- ✅ Bus reset works on first init (line "bus_init_chip done")
- ✅ Hang on SECOND reset (probe_codec fails → error recovery → re-reset wedges)
- ✅ `enable_msi=0` no help (NO_MSI already forced by CTHDA preset)
- ✅ `polling_mode`/`single_cmd` got further (bypassed some of the broken config)
- ✅ Plymouth issue was separate and already fixed

## Next steps

1. Write patch 0004: add the AE-7 subsystem override entry.
2. Rebuild just `snd-hda-intel.ko` (module-only, fast).
3. Boot test. If it boots with the AE-7 visible in `/proc/asound/cards`, we're done
   with the controller hang — then test the ca0132 codec driver (Phase 8).

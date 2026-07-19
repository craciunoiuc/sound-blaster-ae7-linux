# Phase 7 — narrowing the hang (no full rebuild needed)

**Date:** 2026-07-16

## What the last logs told us

Last 3 HDACTRLDBG lines before hang:
```
bus_init_chip after reset_link
bus_init_chip done
azx_init_chip bus_init_chip returned true
```

**Meaning:** the entire HDA bus reset + CORB/RIRB setup SUCCEEDED. The chip is
initialized and ready. The hang is in the code that runs *after* `azx_init_chip`
returns. Tracing the call graph:

```
azx_first_init()
  ├─ hda_intel_init_chip()           ← last print is inside here
  │   ├─ snd_hdac_set_codec_wakeup(true)
  │   ├─ azx_init_chip()             ← prints "bus_init_chip returned true" (LAST SEEN)
  │   ├─ snd_hdac_set_codec_wakeup(false)   ← HANG CANDIDATE 1
  │   └─ intel_init_lctl() (if mlcap)        ← HANG CANDIDATE 2
  ├─ codec_mask detection
  └─ azx_acquire_irq()                       ← HANG CANDIDATE 3 (strongest)
```

The next print that WOULD have appeared is `after azx_first_init`, so the hang
is somewhere in the gap above.

## Strongest suspect: azx_acquire_irq

`azx_acquire_irq` does:
1. `pci_alloc_irq_vectors(..., PCI_IRQ_MSI)` — allocate MSI vectors through the
   ASMedia bridge (PCIe-to-PCI bridges are notorious for breaking MSI)
2. `request_irq(...)` — register the IRQ handler

Both are classic hang points through a PCIe-to-PCI bridge. This aligns perfectly
with the earlier finding that `enable_msi=0` alone didn't help — because even
falling back to INTX, the `request_irq` / `pci_alloc_irq_vectors` path through
the bridge may wedge.

## What was added (patch 0003)

Refined instrumentation bracketing the exact gap — in `intel.c` only:
- `hda_intel_init_chip`: before/after `set_codec_wakeup(false)`, before/after
  `intel_init_lctl` (with mlcap pointer), END
- `azx_first_init`: after `hda_intel_init_chip`, codec_mask, before/after
  `azx_acquire_irq`
- `azx_acquire_irq`: entry (msi flag), MSI-failed→INTX, before `request_irq`,
  SUCCESS

## Install (module-only swap — NO kernel rebuild)

Only `snd-hda-intel.ko` changed. Copy just the module:
```bash
sudo cp /home/cez/sound-card/build/staging/lib/modules/7.1.3-dirty/kernel/sound/hda/controllers/snd-hda-intel.ko.zst /lib/modules/7.1.3-dirty/kernel/sound/hda/controllers/snd-hda-intel.ko.zst
sudo depmod -a 7.1.3-dirty
```

No initramfs rebuild needed (module loads from root, not initramfs). No limine
entry changes. Just reboot the existing `linux-ae7dbg` entry.

## Expected log sequence — report where it stops

```
azx_init_chip bus_init_chip returned true       ← LAST SEEN LAST TIME
hda_intel_init_chip after azx_init_chip
hda_intel_init_chip before set_codec_wakeup(false)
hda_intel_init_chip after set_codec_wakeup(false)
hda_intel_init_chip before mlcap/intel_init_lctl check (mlcap=0x...)
hda_intel_init_chip END
azx_first_init after hda_intel_init_chip
azx_first_init codec_mask=0x...
azx_first_init before azx_acquire_irq
azx_acquire_irq entry, msi=...
azx_acquire_irq MSI failed, trying INTX         ← if stops here, MSI alloc wedges
azx_acquire_irq before request_irq (irq=...)    ← if stops here, INTX alloc wedges
azx_acquire_irq SUCCESS irq=... msi=...         ← if stops AFTER here, IRQ fine
azx_first_init after azx_acquire_irq (irq=...)
after azx_first_init (err=0)
```

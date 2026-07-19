# Iteration log — project memory

Every run gets an entry here (append-only). This file survives across sessions
and agents — it's how we avoid re-learning the same dead ends.

Format:
```
## <label>  YYYY-MM-DD
- patches / module state
- cmdline
- outcome + hang point
- next step
```

Authoritative findings summary: `reference/complete-findings.md`

---

## project bootstrap  2026-07-15
- v7.1.3 cloned; patch 0001 (ca0132 AE7DBG) applies clean.
- Built minimal defconfig bzImage, booted card-absent in QEMU → SUCCESS.
- Confirms patch→build→boot→capture pipeline.

## MAJOR PIVOT  2026-07-16  (blacklist test)
- Blacklisting BOTH ca0132 AND snd_hda_intel → boot STILL hangs.
- Disproved "hang is in the audio driver" → it's earlier (PCI enumeration / boot).
- Led to the PCI-param investigation (nommconf, aspm, etc.) — see archive/.

## Plymouth found  2026-07-16
- Removing `splash` + adding debug-visibility params → **boots to login**.
- Plymouth (`splash`) was conflicting with the bridge during early KMS.
- FIX #1: drop `splash` permanently.

## snd_hda_intel isolation  2026-07-16
- Blacklist ca0132 only, allow snd_hda_intel → HANGS.
- The HDA **controller** driver hangs, not the codec.
- Module params tested blind (enable_msi, single_cmd, polling_mode, probe_mask).
  All failed — but blind (no instrumentation).

## Instrumented kernel built + booted  2026-07-16
- Built full CachyOS-config kernel `7.1.3-dirty` with patches 0001-0003
  (HDACTRLDBG prints across intel.c, controller.c, core/controller.c).
- Booted via limine `linux-ae7dbg` entry.
- Hang definitively at `pci_alloc_irq_vectors(PCI_IRQ_MSI)`.
- FIX #2: `snd_hda_intel.enable_msi=0` → past MSI, IRQ acquired.

## Concurrent-probe lockup found  2026-07-16
- AE-7 has TWO PCI functions (14:00.0 + 14:00.1), probed concurrently via async
  workqueue → hard CPU lockup (`clocksource: Watchdog remote CPU read timed out`).
- FIX #3: serialize `azx_probe_continue` with `azx_probe_serialize_mutex`.
- After fix: no more lockup; both functions probe sequentially.

## res=0x0 (UNSOLVED)  2026-07-16
- With MSI + serialization fixed, controller probes, but `probe_codec(addr=1)`
  returns `res=0x0` — codec never responds to vendor-ID query via CORB/RIRB.
- Tried: 32-bit DMA override, snoop-off (uncached buffers). `res=0x0` persists.
- AE-7's active probing destabilizes the PCIe bus (AHCI 16:00.0 dies → emergency
  mode because RAID root can't mount).
- Card works in Windows → hardware capable; Linux bridge init differs.

## NOT YET RUN: single_cmd=1  (the key remaining experiment)
- `snd_hda_intel.single_cmd=1` bypasses CORB/RIRB DMA, uses PIO immediate
  registers (controller MMIO — which the bridge DOES forward).
- Never tested WITH serialization + enable_msi=0 (the three blockers that foiled
  the early blind test are now fixed).
- If `res` becomes non-zero → PIO works, path to host audio.
- If `res=0x0` again → bridge can't forward HDA verbs at all → VFIO to Windows.

## current working state
- kernel/ tree has: patches 0001-0004 applied + serialization mutex + DMA/snoop
  bridge override + bulletproof bridge-detection logging.
- Host cmdline: `quiet nowatchdog rw root=UUID=... amd_iommu=on iommu=pt
  loglevel=8 ignore_loglevel snd_hda_intel.enable_msi=0` (no splash)
- snd_hda_intel currently BLACKLISTED on the host (bootable, safe state).
- linux-ae7dbg limine entry exists for instrumented-kernel testing.

# Complete findings from the AE-7 investigation

**Date:** 2026-07-16
**Scope:** every finding from the full investigation, including ones noted in
passing but never fully documented, and experiments that were never run.

---

## Hardware facts (confirmed)

- **Host:** MSI MAG X670E Tomahawk WiFi, Ryzen 7800X3D, 64 GB RAM, RAID root
  (`/dev/md0`), boot via Limine + `cachyos-hooks` + `mkinitcpio`.
- **AE-7 topology** (two PCI functions behind one bridge):
  - `13:00.0` — ASMedia ASM1083/1085 PCIe-to-PCI bridge, `1b21:1080`, **rev 03**
  - `14:00.0` — Creative CA0132 HDA controller, `1102:0010`, rev 01
  - `14:00.1` — **second** HDA function (identity never captured; likely HDMI or
    a second CA0132 function). Its existence is what caused the concurrent-probe
    lockup.
- **Bridge config (from `lspci -vvv` in working/blacklisted state):**
  - Memory behind bridge: `f2300000-f23fffff` (1 MB, 32-bit)
  - **Prefetchable memory: disabled**
  - **I/O behind bridge: disabled**
  - **Interrupts: pin B routed to IRQ 255** ← "no IRQ assigned" for the bridge
    itself; the controller behind it gets IRQ 41 from elsewhere. The IRQ routing
    through the bridge is suspect.
  - `sec-latency=32`
  - Capabilities detail never captured (`<access denied>` without root).

## The three CONFIRMED, FIXED software bugs

### Bug 1 — Plymouth (`splash`) blocks early boot
- **Symptom:** with the card installed and `splash` on the cmdline, boot hangs
  behind the Plymouth spinner.
- **Root cause:** Plymouth's early KMS handoff conflicts with the bridge during
  initial PCI enumeration.
- **Fix:** remove `splash` from the kernel cmdline.
- **Status:** confirmed — removing `splash` alone lets the system boot to login
  with the card present and `snd_hda_intel` blacklisted.

### Bug 2 — MSI allocation hangs through the bridge
- **Symptom:** `pci_alloc_irq_vectors(pci, 1, 1, PCI_IRQ_MSI)` never returns.
  Confirmed by instrumentation: last line `azx_acquire_irq entry, msi=1`, then
  freeze (no "MSI failed" fallback).
- **Root cause:** the ASMedia bridge cannot handle MSI vector allocation.
- **Fix:** `snd_hda_intel.enable_msi=0` on the cmdline, OR add the controller to
  the `msi_deny_list` in `intel.c`.
- **Note:** earlier the CTHDA preset included `AZX_DCAPS_NO_MSI`, which masked
  this bug for years. Switching to GENERIC exposed it.

### Bug 3 — Concurrent probe of two PCI functions causes hard CPU lockup
- **Symptom:** `clocksource: Watchdog remote CPU N read timed out` ~500 ms after
  both AE-7 functions start probing simultaneously.
- **Root cause:** async `schedule_delayed_work` probes `14:00.0` and `14:00.1`
  concurrently; both hammer the bridge with MMIO → one CPU wedges waiting for a
  completion blocked by the other's stuck transaction.
- **Fix:** serialize `azx_probe_continue` with a global mutex
  (`azx_probe_serialize_mutex` in `intel.c`).
- **Status:** confirmed — with the mutex, no more watchdog timeout; both
  functions probe sequentially.

## The UNSOLVED core problem

### `probe_codec(addr=1) → res=0x0` (codec never responds)
- The codec IS physically present: `codec_mask=0x2` (STATESTS bit 1 set during
  bus reset — a passive hardware line).
- But the active vendor-ID query via CORB/RIRB always returns 0.
- Tested with: GENERIC caps, +32-bit DMA, +snoop-off (uncached buffers),
  +serialized probe. **`res=0x0` in every configuration.**
- This means the CORB→codec→RIRB command path does not work through the bridge.
- **The card works in Windows**, so the hardware is capable — Windows must
  initialize the bridge or codec differently.

## The MOST IMPORTANT MISSED EXPERIMENT

### `single_cmd=1` was never tested WITH serialization + `enable_msi=0`

The HDA driver has **two command paths** to the codec:

1. **CORB/RIRB (DMA):** the controller DMAs commands to a host buffer, the codec
   reads them, and DMAs responses back. This is what's failing (`res=0x0`).
   Crucially, **the DMA goes through the bridge** to host RAM — and the bridge is
   a 32-bit PCI device that may not be forwarding these DMA cycles correctly.

2. **PIO / single_cmd (MMIO registers):** the CPU writes the command directly to
   the controller's `IC` (Immediate Command) register and reads the response from
   the `IR` (Immediate Response) register — both **controller MMIO**, NOT DMA
   through the bridge. The bridge already forwards MMIO correctly (the controller
   init/reset all work).

`single_cmd=1` forces path #2 from the start. If the bridge breaks DMA forwarding
but handles MMIO, PIO would successfully reach the codec.

**Why this was missed:** `single_cmd=1` *was* tested early (Phase 5b) and reported
"a bit more progress, then hang." But that test was:
- BEFORE the serialization mutex (so it hit the concurrent-probe lockup)
- BEFORE `enable_msi=0` (so it hit the MSI allocation hang)
- WITHOUT instrumentation (so "a bit more progress" was ambiguous)

Those three blockers are now fixed. **Re-testing `single_cmd=1` on top of the
current working baseline (serialized + `enable_msi=0`) is the highest-value
remaining experiment.** It directly targets the failing mechanism.

### How to test it
Add to the cmdline alongside the existing fixes:
```
snd_hda_intel.enable_msi=0 snd_hda_intel.single_cmd=1
```
Then look for `probe_codec after azx_get_response (err=0 res=0x????????)`:
- **Non-zero** (e.g. `0x1102xxxx`) → PIO works, the codec responds. This is the
  path to working host audio.
- **`0x0` again** → the bridge can't forward HDA verbs at all (even via MMIO
  PIO), confirming it's a fundamental bridge limitation and the only option is
  VFIO passthrough.

> Note: `single_cmd` is officially "not preferred" per the Intel HDA spec
> (intended for BIOS only, may confuse unsolicited responses), but it's a
> legitimate documented operating mode and is the right tool when CORB/RIRB
> DMA is broken.

## Other findings (lower priority, documented for completeness)

### The codec is at address 1, not address 0
`codec_mask=0x2` → the CA0132 sits at codec address 1. Standard HDA codecs are at
address 0. This is set by the bridge's secondary-bus configuration and is normal
for cards behind a bridge, but it means `probe_codec` queries slot 1.

### `probe_mask=0xffffffff`
Default; means "probe all slots." Not a problem, but worth noting the AE-7 isn't
in the `probe_mask_list` quirk table.

### Bridge IRQ = 255 (unassigned)
The ASMedia bridge itself reports `IRQ 255`, meaning it has no interrupt routed.
The controller behind it gets IRQ 41 from elsewhere. INTx delivery through a
bridge with no IRQ is suspect and may contribute to interrupt-handling issues —
but since `probe_codec` fails before interrupts matter, this is downstream of the
blocker.

### `res=0x1bec0b00` for the AMD `19:00.6` controller
This is the AMD Ryzen HD Audio controller's codec vendor ID. `0x1bec` is not AMD's
PCI vendor (0x1022) — it's the codec-level vendor ID (a different namespace).
Appears normal.

### `azx_get_response timeout, switch to polling mode` on AMD HDMI
Seen on `19:00.1` in early logs. Normal for AMD HDMI codecs (slow first response);
the fallback resolved it and the probe succeeded. Not related to the AE-7.

### The CTHDA preset was partially correct
The old `AZX_DCAPS_PRESET_CTHDA` (NO_MSI, SNOOP_OFF, NO_64BIT) was applied to the
AE-7 by mistake (PCI ID collision with the X-Fi CA0110-IBG), but two of its caps
were actually *correct* for this hardware:
- `AZX_DCAPS_NO_MSI` — MSI doesn't work through the bridge (Bug 2)
- `AZX_DCAPS_SNOOP_OFF` — uncached DMA is appropriate for a non-coherent bridge

The preset was wrong overall (the CA0132 isn't an X-Fi), but its individual flags
weren't entirely wrong. This is why the card may have worked on older kernels
where the CTHDA preset masked the MSI bug — until the concurrent-probe lockup
(Bug 3) was introduced by some other change.

### GCAP was never logged
The controller's GCAP register (stream counts, 64-bit DMA capability) is read in
`azx_first_init` but never printed. Would confirm whether `AZX_GCAP_64OK` was set.

### `pci=nommconf` was never re-tested in isolation
Early in Phase 1, `nommconf` didn't fix the boot hang — but that was before we
knew about Plymouth and the concurrent-probe lockup. It was never re-tested with
just `splash` removed. Likely irrelevant now (the controller probe works via MMIO,
so ECAM vs port-I/O isn't the issue), but noted for completeness.

### `display_power` / amdgpu audio component
The HDA probe calls `display_power(chip, true)` which binds to the amdgpu DRM
audio component. The logs show `bound 0x1002:... amdgpu_dm_audio_component_bind_ops`
for the AMD controllers. This binding was never investigated as a contributor —
unlikely to be the cause (it's for HDMI audio power), but it's an interaction
surface that wasn't audited.

## Summary table

| Finding | Status | Action |
|---|---|---|
| Plymouth blocks boot | ✅ Fixed | Remove `splash` |
| MSI alloc hangs | ✅ Fixed | `enable_msi=0` |
| Concurrent-probe lockup | ✅ Fixed | Serialize mutex |
| `res=0x0` (CORB/RIRB DMA) | ❌ Unsolved | **Try `single_cmd=1` next** |
| Bridge IRQ=255 | 📝 Noted | Downstream of the blocker |
| Codec at addr 1 | 📝 Noted | Normal for bridged cards |
| CTHDA preset partially right | 📝 Noted | Explains historical behavior |
| GCAP never logged | 📝 Missed | Minor; would confirm 64OK |
| `nommconf` not re-isolated | 📝 Missed | Likely irrelevant |
| amdgpu audio component bind | 📝 Not audited | Unlikely cause |

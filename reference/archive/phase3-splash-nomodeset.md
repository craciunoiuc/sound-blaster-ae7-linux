# Phase 3 — it boots without splash/nomodeset: isolating the real culprit

**Date:** 2026-07-16
**Breakthrough:** Removing `quiet splash` + adding `nomodeset` made it boot.
The card is now visible and enumerated.

## Confirmed hardware state
```
13:00.0 PCI bridge: ASMedia ASM1083/1085 [1b21:1080] (rev 03)
14:00.0 Audio device: Creative CA0132 [1102:0010] (rev 01)
```
- Bridge is **rev 03** — covered by the kernel quirks (not an unknown revision)
- The bridge's secondary bus is `14`, memory window `f2300000-f23fffff` (1M)
- Card is in **IOMMU group 23**

## IMPORTANT anomaly: subsystem ID
`lspci -nnn` shows device ID `1102:0010`, but the kernel `QUIRK_AE7` matches on
**subsystem** PCI ID `1102:0081`. The `0010` is the raw CA0132 device ID. The
subsystem ID (which distinguishes AE-5/AE-7/AE-9/SBZ) is either not being read
correctly through the bridge, or this card revision reports it differently.
- Implication: even once the boot hang is fully fixed, the ca0132 driver may
  fall to `QUIRK_NONE` instead of `QUIRK_AE7`, producing no sound.
- To investigate later: `lspci -vvv -s 14:00.0` (needs root) should show the
  Subsystem field. If it's `1102:0081`, the quirk matches. If `1102:0010`, the
  quirk table needs a new entry.

## The problem with the current "fix"

`nomodeset` made it boot, but it's NOT a real fix:
- `DRIVER=simple-framebuffer` — the amdgpu driver is NOT doing KMS
- GPU is running in basic VESA/framebuffer mode at 2560×1440
- **Lost:** hardware GPU acceleration, proper resolution handling, display
  hotplug, and (if applicable) reclocking / power management

This matches Bugzilla #217510's finding: "the only fix was removing the Intel GPU
firmware." The GPU driver stack (amdgpu + KMS) is conflicting with the card
during early boot — possibly a BAR/MMIO resource conflict, or the KMS init path
touching the bridge's config space in a way that hangs.

## Isolation plan

The working cmdline currently has BOTH `nomodeset` AND removed-`splash`. We don't
yet know which one matters. Test by adding ONE thing back per boot:

### Test 1 — Was it just `splash` (Plymouth)?
Add back `quiet` (harmless) but NOT `splash`, and remove `nomodeset`:
```
quiet loglevel=3 module_blacklist=snd_hda_intel iommu=pt amd_iommu=on nowatchdog
```
(Removed: splash, nomodeset, initcall_debug, earlyprintk, plymouth.enable=0)
If this boots with full GPU acceleration → **Plymouth (splash) was the culprit.**
This is the best outcome — Plymouth is purely cosmetic and safe to drop.

### Test 2 — Was it `nomodeset` that mattered?
If Test 1 hangs, the GPU/KMS driver itself is the problem (not Plymouth). Then:
- Boot back with `nomodeset` (the known-working state)
- The long-term fix is one of:
  - `amdgpu.mm_pg_size=32` or other amdgpu BAR/MMIO tuning
  - Blacklist amdgpu from initramfs (`kms` hook in mkinitcpio pulls it in early)
  - A BIOS setting (Above 4G Decoding / Resizable BAR) that changes MMIO layout

### Test 3 — Does the audio driver also work now?
Once boot is stable, remove `module_blacklist=snd_hda_intel`:
- If it boots → the controller driver is fine
- Then check: `lsmod | grep ca0132`, `cat /proc/asound/cards`
- The subsystem-ID anomaly (above) may prevent QUIRK_AE7 from matching, so the
  ca0132 driver may load but produce no AE-7-specific setup.

## What's going on, technically

The `kms` hook in mkinitcpio loads amdgpu INTO the initramfs so it starts very
early (before the root filesystem is mounted). When amdgpu initializes, it:
1. Probes the GPU's PCI BARs
2. Sets up KMS (kernel mode setting) — claims the display
3. May re-allocate or re-map PCI MMIO regions

If the AE-7's bridge (or the card's BAR) shares an MMIO resource window with the
GPU, or if the early amdgpu probe touches the bridge's config space, boot hangs.
`nomodeset` defers/disables the amdgpu probe → no conflict → boots.

This is consistent with: the card works from Live USBs (different initramfs, no
early KMS hook) but fails on the installed system (early KMS via mkinitcpio kms
hook). Exactly the bug title.

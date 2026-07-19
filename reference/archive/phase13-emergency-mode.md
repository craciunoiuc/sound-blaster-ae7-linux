# Phase 13 — AE-7 probes but destabilizes the PCIe bus

**Date:** 2026-07-16

## What happened

With serialization + enable_msi=0, the system **booted to emergency mode** (not a
hard hang). This is major progress — the CPU lockup is gone. But three serious
problems remain:

### 1. The AE-7 controller DID probe (partially)
```
14:00.0: azx_first_init (err=0)              ✅
14:00.0: azx_acquire_irq SUCCESS irq=41 msi=0 ✅ (INTX works!)
14:00.0: codec_mask=0x2                       ✅ (codec detected during bus reset)
14:00.0: probe_codec(addr=1) res=0x0          ❌ (codec returned garbage)
14:00.0: "no AFG or MFG node found"           ❌
14:00.0: "no codecs initialized" (err=-6)     ❌
```
The bridge CAN see the codec during reset (codec_mask=0x2), but active
command/response returns 0x0 (the bridge can't forward HDA verbs to the codec).

### 2. 220-second delay
`probe_work ENTERED` at 10.000s, `azx_acquire_irq` at 231.575s. The AE-7's probe
spent ~220 seconds stuck somewhere (likely the codec timeout fallback loop:
RIRB → polling → single_cmd, each with multi-second timeouts).

### 3. Sibling PCIe devices DIED
```
ahci 0000:16:00.0:    "AHCI controller unavailable!"     ← SATA (your RAID root!)
xhci_hcd 0000:15:00.0: "HC died; cleaning up"            ← USB controller
pcieport 0000:00:07.0: "Unable to change power state"    ← PCIe root port
```
The AE-7's active probing **destabilized the PCIe bus**, killing the AHCI
controller (which holds the RAID root filesystem) → emergency mode.

## What this means

This is looking like **hardware-level PCIe bus instability**. The ASMedia
PCIe-to-PCI bridge on the AE-7, when actively probed by the HDA controller
driver, disrupts sibling PCIe devices — the link-level fault recovery takes
~220s and the AHCI/xHCI controllers don't survive.

The codec itself returns garbage (res=0x0) — the bridge can detect it during
reset (passive STATESTS read) but can't forward active command verbs (CORB/RIRB
transactions) to it. This is consistent with the bridge being fundamentally
broken for HDA command traffic.

## The two fixes that WORKED (proven)

1. ✅ **`snd_hda_intel.enable_msi=0`** — eliminated the MSI allocation hang
2. ✅ **Probe serialization mutex** — eliminated the concurrent-probe hard lockup

These are real fixes for real bugs and should be kept / upstreamed.

## The remaining problem: hardware-level

No software patch can fix:
- The bridge failing to forward HDA commands (res=0x0)
- The PCIe bus destabilization killing AHCI/xHCI

## Options

### Option A: Blacklist + VFIO passthrough (pragmatic)
Keep `snd_hda_intel` blacklisted on the host (so the buggy probe never runs),
bind the AE-7 to vfio-pci, and pass it through to a Windows VM. The Windows
driver may handle the bridge better, or at least a VM crash is recoverable.

### Option B: Accept the delay, fix the root mount
Add `rootdelay=300` to cmdline so the initramfs waits for the AHCI controller to
recover before mounting root. The AE-7 would be "present" but non-functional
(no codecs). Host audio won't work but the system boots.

### Option C: BIOS link-speed downgrade
Set the AE-7's PCIe slot to Gen 1 in BIOS (if the MSI Click BIOS exposes it for
that slot — earlier research suggested it may not for chipset-wired slots).

### Option D: Different physical slot
Move the AE-7 to a slot on a different PCIe root port, away from the AHCI/xHCI
controllers, so its bus destabilization doesn't take them down.

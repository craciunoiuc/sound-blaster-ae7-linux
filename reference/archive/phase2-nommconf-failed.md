# Phase 2 — nommconf failed: what it means + next steps

**Date:** 2026-07-16
**New data:** `pci=nommconf pcie_aspm=off` → still hangs. Adding
`pci=noaer pcie_bus_peer2peer` → still hangs. No Gen 1 option for PCI_E3 in MSI
Click BIOS 5 (MAG X670E Tomahawk).

## What the nommconf failure proves

`pci=nommconf` forces legacy Type-1 port I/O config access (0xCF8/0xCFC) instead
of ECAM memory-mapped access. Since that *also* hangs, **the failure is NOT in
the config-space access mechanism itself.** This rules out "bad ECAM read" as the
proximate cause and points to things that run *independently* of how config
space is read:

1. **AMD IOMMU domain setup** for the bridge (runs regardless of conf method).
   The kernel has `quirk_use_pcie_bridge_dma_alias` for exactly this bridge
   (1b21:1080) — its DMA aliasing breaks IOMMU setup. `iommu=pt` does NOT disable
   the IOMMU; the AMD-Vi driver still fully initializes and walks every device.
2. **Interrupt storm** — the ASM1083/1085 is notoriously broken on interrupts.
3. **PCIe resource reallocation loop** — BIOS left the bridge's MMIO window
   mis-sized; kernel spins trying to size it.

## The other problem: we are flying blind

The cmdline has `quiet splash` → **Plymouth is hiding the actual error.** We do
not know which initcall/device is hanging. **Visibility is job one.** Until we
see the hang point, every param test is a guess.

## MSI MAG X670E Tomahawk findings

- The per-slot `Max Link Speed` override is under: **Del → F7 (Advanced Mode) →
  Settings → Advanced → PCI Subsystem Settings**. It's hidden in EZ Mode — must
  be in Advanced Mode (F7) to see it. MSI calls it `PCI_E3 - Max Link Speed`.
- **However:** MSI typically only exposes the override for CPU-wired (PEG) slots
  (PCI_E1). If PCI_E3 is chipset-wired (likely), there may be no Gen1 option —
  that matches what you saw. Not user error; board limitation.
- PCI_E2 is PCIe 3.0 x1 — the AE-7 (x4 physical) won't fit.
- **BIOS update available:** 7E12v1KB changelog explicitly says
  "Improved PCIe-based device compatibility." Avoid 7E12v1K7 (causes BSODs).
  → https://www.msi.com/Motherboard/MAG-X670E-Tomahawk-wifi/support

## Recommended next steps (in order)

See `boot-hang-phase2-order.md` for the full in-order sequence.

### Step A — Get visibility (do this FIRST, alone)
Remove `quiet splash`; add the debug-visibility params. The last line on screen
before the freeze names the culprit. This collapses the hypothesis space.

### Step B — Test `amd_iommu=off` (leading new suspect)
The IOMMU-domain setup for a bridge with DMA-aliasing bugs is config-method-
independent — exactly matching the nommconf failure. Cleanest single test.

### Step C — Test `pci=realloc` (resource reallocation)
Highest-probability untried PCI param. If the BIOS left the bridge window
mis-sized, the kernel re-allocates it instead of spinning.

### Step D — BIOS update to 7E12v1KB
Has an explicit PCIe-compatibility fix. Check if PCI_E3 Gen1 appears after.

### Step E — Move card to PCI_E1, force Gen 1 there (diagnostic test)
PCI_E1 is CPU-wired and definitely has the Max Link Speed override. If the card
boots there at Gen1, link-speed forcing is the cure and we work from there.

# AE-7 boot hang — Phase 2 in-order test list

`pci=nommconf` failed, which rules out config-space-access mechanism as the cause.
Two new leading suspects: **AMD IOMMU domain setup** (config-method-independent)
and **PCIe resource reallocation loops**. Plus we've been flying blind behind
Plymouth (`quiet splash`).

## Step A — SEE the hang point (do this FIRST, alone)

This is the single most important step. Edit `/etc/default/limine`:

```
KERNEL_CMDLINE[default]+="rw root=UUID=cf0cc394-37e9-4774-b6be-57e55351af52 amd_iommu=on iommu=pt module_blacklist=snd_hda_intel loglevel=8 ignore_loglevel initcall_debug plymouth.enable=0 earlyprintk=vga,keep nomodeset printk.time=1"
```

Key changes vs current:
- **Remove `quiet` and `splash`** (these hide everything behind Plymouth)
- **`initcall_debug`** — prints each init step; the last one that prints "calling"
  but never "returned" is the culprit
- **`earlyprintk=vga,keep`** — shows messages on screen before the console loads
- **`nomodeset`** — stops the GPU driver from taking over the framebuffer
- **`printk.time=1`** — timestamps so you can tell hang (frozen) vs slow (advancing)

Then `sudo limine-update`, reboot with the card.

**Action:** Photograph the screen when it freezes. The last line (e.g.
`calling amd_iommu_init+0x0` or `pci 0000:xx:xx.x: ...`) tells us exactly which
subsystem to target. **This collapses the hypothesis space — report it back.**

> If `earlyprintk=vga` makes it worse (rare), drop it but keep `initcall_debug`.
> If you have a USB-TTL serial adapter, the board may have a UART header —
> `console=ttyS0,115200n8 earlyprintk=serial,ttyS0,115200` is more reliable than
> VGA for a hard freeze.

## Step B — Test the IOMMU hypothesis

The ASM1083 has a documented DMA-aliasing quirk (`quirk_use_pcie_bridge_dma_alias`
in `drivers/pci/quirks.c`). When the AMD-Vi IOMMU tries to build a DMA domain
for a bridge whose request ID aliases all downstream traffic, setup can hang —
and this is independent of how config space is read (matching nommconf failing).

**`iommu=pt` does NOT disable the IOMMU** — it still fully initializes.

### B1 (cleanest test): `amd_iommu=off`
```
KERNEL_CMDLINE[default]+="... amd_iommu=off ..."
```
(replace `amd_iommu=on iommu=pt` with `amd_iommu=off`)

If this boots → IOMMU setup was the hang. Then try:
- `iommu=soft` — software bounce buffers (keeps swiotlb, no hw IOMMU)
- Later, for VFIO you'd need IOMMU back on — that's a separate problem to solve

### B2 (if B1 boots): `amd_iommu=on iommu=pt amd_iommu=fullflush`
If you need IOMMU on eventually, `fullflush` flushes TLB on every map — works
around stale-translation hangs on broken bridges (perf cost).

## Step C — PCIe resource reallocation

Highest-probability **untried** PCI param. If the BIOS left the bridge's
secondary-bus MMIO window too small/overlapping, the kernel spins trying to size
it. `nommconf` doesn't help because the problem isn't the *access*, it's the
*resource allocation loop*.

```
KERNEL_CMDLINE[default]+="... pci=realloc pci=assign-busses pci=hpmemsize=32M hpbussize=8 ..."
```
- `pci=realloc` — ignore firmware windows, let kernel re-allocate
- `pci=assign-busses` — kernel assigns bus numbers (fixes unconfigured bridge)
- `pci=hpmemsize=32M hpbussize=8` — give the bridge a generous MMIO window
  (default is only 2MB, may be too small for the CA0132 BAR)

Try `pci=realloc` alone first, then add the others if needed.

## Step D — BIOS update

MSI 7E12v1KB changelog: *"Improved PCIe-based device compatibility under certain
CPU or system combinations."* Directly relevant.
- Download: https://www.msi.com/Motherboard/MAG-X670E-Tomahawk-wifi/support
- **Avoid 7E12v1K7** — documented to cause DPC_WATCHDOG_VIOLATION BSODs.
- After update, re-check: Del → F7 → Settings → Advanced → PCI Subsystem Settings
  → does `PCI_E3 - Max Link Speed` appear now?

## Step E — Move card to PCI_E1 + force Gen 1 (diagnostic)

PCI_E1 (the GPU slot, CPU-wired) **definitely** has the `Max Link Speed` override.
This is a diagnostic test, not a permanent setup:
1. Move AE-7 to PCI_E1, move GPU to another slot (or use iGPU).
2. BIOS → PCI_E1 Max Link Speed → **Gen 1**.
3. Boot. If it works → link-speed forcing is the cure. Then figure out how to
   apply it to PCI_E3 (BIOS update may add the option; or `setpci` post-boot).

## Step F — Other untried params (lower priority)

If Steps A–E don't resolve:
- `pci=pcie_bus_safe` (drop down from peer2peer — doesn't touch MRRS)
- `pci=nomsi` (disable MSI/MSI-X entirely — distinct from noaer)
- `pci=nocrs` (ignore ACPI _CRS host bridge windows)
- `pcie_aspm=force` (take ASPM control from BIOS, vs `off` which leaves BIOS state)

## Key rule: change ONE thing per boot

Don't stack Step B + Step C at once — if it works you won't know which fixed it,
and they interact (both change DMA/resource paths). Read the `initcall_debug`
output from Step A first; it will likely point directly at B or C.

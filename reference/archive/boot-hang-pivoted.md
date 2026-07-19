# Re-diagnosis: the hang is at PCI enumeration, not the driver

**Date:** 2026-07-16
**Trigger:** user reported that blacklisting BOTH `snd_hda_codec_ca0132` AND
`snd_hda_intel` (the entire HDA audio stack) did **not** fix the boot hang.
The machine still failed to boot with the AE-7 installed.

## What this proves

The hang is **not in the audio driver**. It happens **before any driver loads**,
during early-boot **PCI enumeration / config-space probing** (BAR sizing, ECAM
reads, PCIe link training). The `ca0132` driver, `QUIRK_AE7`, the BAR2
`pci_iomap(...,2,0xC20)` path — none of it ever runs. The kernel wedges the
moment it touches the AE-7's PCI config space.

This is consistent with the original bug title *"works only from Live
distributions"* — Live media often apply different default PCI handling.

**Implication:** kernel *code* patches to `ca0132.c` cannot fix the boot hang.
The fix is a **kernel command-line parameter** and/or a **BIOS setting**. The
existing `patch_ca0132.c` rig is still valuable, but only for a *potential
second* hang at the driver level, which we'll only reach after the enumeration
hang is resolved.

## Prioritized kernel parameters (CachyOS / limine syntax)

Test ONE change at a time. Syntax in `/etc/default/limine`:
```
KERNEL_CMDLINE[default]+="<params>"
sudo limine-update
```

### Step 0 — Capture the hang point first
```
earlyprintk=vga loglevel=8 ignore_loglevel initcall_debug
```
The **last line on the frozen screen** names the failing step. Photograph it.
(Drop `earlyprintk=vga` if it makes the hang *worse* — rare.)

### Step 1 — `pci=nommconf`  (MOST LIKELY FIX)
Disables ECAM memory-mapped config access → falls back to legacy port I/O
(0xCF8/0xCFC), which times out gracefully on a wedged link instead of hanging.
The single most-reported fix for this exact symptom.

### Step 2 — Stack `pcie_aspm=off`
```
pci=nommconf pcie_aspm=off
```
Prevents low-power link states (L0s/L1) that fail to retrain.

### Step 3 — ASPM alone
```
pcie_aspm=off
```
(Revert `nommconf` for this isolated test.)

### Step 4 — AER / MSI storm
```
pci=noaer pci=nomsi
```
If the card floods corrected-error interrupts → AER handler livelocks.

### Step 5 — BAR reallocation
```
pci=realloc
```
Only if Step 0 showed a "not enough MMIO window" / BAR assignment error.

### Step 6 — Max Payload Size
```
pcie_bus_peer2peer
```
Forces MPS=128 everywhere; fixes malformed-TLP storms from MPS mismatch.

### Step 7 — Hotplug
```
modprobe.blacklist=pciehp
```
Only if the slot is hotplug-capable and generating spurious events.

## Field-proven BIOS fix (AE-7 / AE-9 specific)

Across openSUSE, EndeavourOS, Linux Mint, MSI, Reddit threads: the most
consistently reported fix is a **BIOS setting**, not a kernel param:
- BIOS → Advanced / PCIe settings → **set the AE-7 slot Max Link Speed to Gen 1**
  (PCIe 1.0), and/or reduce lane width to x1.
- The AE-7/AE-9 has marginal PCIe Gen-4 link negotiation; Gen 1 trains reliably.

## Testing protocol

1. Keep current blacklists in place (harmless).
2. Apply Step 0 to capture the hang line.
3. Add params one at a time (Steps 1–7), reboot each time.
4. When boot succeeds: confirm the card is visible via `lspci -nn -d 1102:0081`.
5. **Then** begin removing blacklists one by one:
   a. Remove `snd_hda_intel` blacklist → boot? (controller driver, ≠ codec)
   b. Remove `ca0132` blacklist → boot? (THIS is where a driver-level hang would
      surface — at which point the `patch_ca0132.c` rig becomes relevant again.)
6. If step 5b hangs, the enumeration fix may also resolve the driver hang
   (since BAR2 MMIO is separate from ECAM config space), or it may require
   its own deeper investigation using the QEMU/VFIO rig.

## Sources
- kernel.org kernel-parameters.html
- Bugzilla #217510 (canonical), #219552 (AE-9 sibling)
- openSUSE / EndeavourOS / Mint / MSI forums (Gen 1 link-speed fix)
- Altera KB: "system hang during PCIe enumeration (BAR sizing)"

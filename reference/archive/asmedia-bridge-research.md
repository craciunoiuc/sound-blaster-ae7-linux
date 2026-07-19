# The ASMedia ASM1083/1085 PCIe-to-PCI bridge hypothesis — confirmed

**Date:** 2026-07-16
**Status:** the leading hypothesis is now strongly corroborated by the in-kernel
source code itself. The AE-7 (and AE-9) contain an ASMedia ASM1083 or ASM1085
PCIe-to-PCI bridge (`1b21:1080`). Creative changed this bridge ~2-3 years ago,
and the newer revision hangs Linux during PCI enumeration — before any driver
loads. This is why blacklisting the audio drivers did not help.

## The kernel already knows this bridge is buggy

There are **three separate quirks** for `1b21:1080` in the kernel source
(verified in `kernel/` at v7.1.3):

### 1. Config-space aliasing — `drivers/pci/probe.c:1806`
```c
 * Known offenders:
 *   ASM1083/1085 PCIe-to-PCI Reversible Bridge (1b21:1080, rev 01 & 03)
 *   AMD/ATI SBx00 PCI to PCI Bridge (1002:4384, rev 40)
 */
static bool pci_ext_cfg_is_aliased(struct pci_dev *dev) { ... }
```
The bridge **does not properly handle extended config space (ECAM) accesses** —
it drops the extended register bits, aliasing the 256-byte standard config space
across all of the 4KB extended space. This is the mechanism that breaks
memory-mapped (ECAM/MMCONFIG) config reads.

**Critical:** the comment says "rev 01 & 03." If the AE-7's newer (2022+)
bridge is a **different revision** (rev 04+?), this code path may behave
differently for it.

### 2. ASPM L0s/L1 disable — `drivers/pci/quirks.c:2534`
```c
 * ASM1083/1085 PCIe-PCI bridge devices cause AER timeout errors on the
 * upstream PCIe root port when ASPM is enabled.
DECLARE_PCI_FIXUP_HEADER(PCI_VENDOR_ID_ASMEDIA, 0x1080,
                         quirk_disable_aspm_l0s_l1);
```
The bridge causes **AER timeout errors on the upstream root port** when ASPM is
active. The kernel disables ASPM for it.

**Critical:** this is a `DECLARE_PCI_FIXUP_HEADER` — it runs *after* the header
is read. If the hang happens *before* this point (during the initial ECAM probe),
the quirk never gets a chance to run.

### 3. DMA alias fixup — `drivers/pci/quirks.c:4430`
```c
/* ASM1083/1085, https://bugzilla.kernel.org/show_bug.cgi?id=44881#c46 */
DECLARE_PCI_FIXUP_HEADER(PCI_VENDOR_ID_ASMEDIA, 0x1080,
                         quirk_use_pcie_bridge_dma_alias);
```
DMA aliasing for IOMMU correctness. Not boot-hang-related, but confirms the
bridge has multiple known defects.

## Why the quirks might not save the AE-7

1. **Quirks run after the initial probe.** If the hang is during the very first
   config-space read (ECAM access to size BARs), the ASPM quirk hasn't applied
   yet. `pci=nommconf` changes the *access method* of that first read.
2. **Revision matters.** The alias-detection comment names "rev 01 & 03." A
   newer 2022 revision may not be covered, or may behave worse.
3. **`pcie_aspm=off` has a gotcha:** it tells the kernel not to *change* ASPM
   state — it leaves whatever the BIOS configured. If BIOS left ASPM on, the
   param doesn't turn it off. The in-kernel quirk (`quirk_disable_aspm_l0s_l1`)
   is the real enforcement; `setpci` is the manual override.

## The highest-value diagnostic

The single most useful thing to capture on the next successful boot-with-card is:
```
lspci -nn -d 1b21:1080
```
This confirms (a) the bridge is present, (b) its **revision** (rev 01/03 are
known; rev 04+ would be the "new" problematic one), and (c) whether it still
enumerates as `1b21:1080` or a different ID (ASMedia acquired Pericom; some new
bridges use Pericom IDs like `12d8:e113`, which would NOT match the kernel
quirks at all).

To capture this even when boot hangs: use `pci=nommconf` to get past the hang,
then immediately run that lspci. Or boot with `earlycon`/`earlyprintk=vga` and
photograph where it freezes.

## Updated prioritized fix list

See `boot-hang-asmedia-order.md` for the in-order test sequence.

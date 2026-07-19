# AE-7 boot hang — updated in-order test list (ASMedia bridge theory)

The hang is at **PCI enumeration**, caused by the AE-7's ASMedia ASM1083/1085
PCIe-to-PCI bridge (`1b21:1080`). Driver blacklists cannot help. Each test below
requires a reboot (not necessarily a card swap — see "minimizing card swaps").

## Before you start: the cheap win

**Disable Windows Fast Boot** (if you dual-boot). Fast Boot leaves the card's PCI
config space in a state Linux can't recover from. Also check BIOS for any
**ASPM disable** toggle for the AE-7's slot.

## Minimizing card swaps

Once the card is installed, you can iterate via reboots alone (no re-seat) by
editing `/etc/default/limine`, running `sudo limine-update`, and rebooting. Only
remove the card if you need the machine for something else. So: **install the
card once, then test the whole list via reboots.**

For each test: edit limine → `sudo limine-update` → reboot → observe. If it
boots, run `lspci -nn -d 1b21:1080` immediately to confirm the bridge + grab its
revision, then move to narrowing.

## The list, in order

### Test 1 — `pci=nommconf` + `pcie_aspm=off` together (best single bet)
```
KERNEL_CMDLINE[default]+="pci=nommconf pcie_aspm=off"
```
**Why:** `pci=nommconf` is the highest-probability fix for an ECAM config-read
hang on a PCIe-to-PCI bridge (it switches to legacy port I/O which times out
gracefully). `pcie_aspm=off` covers the ASPM/AER-timeout failure mode. Stacking
both gives the best odds for a single reboot. Many ASMedia-bridge hang reports
are resolved by exactly this combination.

If it boots → go to **Narrowing** below.

### Test 2 — `pci=nommconf` alone (isolate the variable)
```
KERNEL_CMDLINE[default]+="pci=nommconf"
```
Revert `pcie_aspm=off`. If this still boots, ECAM was the culprit and you don't
need ASPM changes. If it hangs, ASPM was also a factor — keep both (Test 1).

### Test 3 — add `pci=noaer` (silence AER storm)
```
KERNEL_CMDLINE[default]+="pci=nommconf pcie_aspm=off pci=noaer"
```
The bridge floods AER errors on the upstream root port. Even if boot succeeds,
this stops log flooding. Worth adding permanently once things work.

### Test 4 — `pcie_aspm=off` + `pci=noaer` WITHOUT `nommconf`
```
KERNEL_CMDLINE[default]+="pcie_aspm=off pci=noaer"
```
If you want extended config space back (some features need it), test whether ASPM
disable alone is enough. `nommconf` kills extended config space access, so this
tests the alternative.

### Test 5 — Max Payload Size (`pcie_bus_peer2peer`)
```
KERNEL_CMDLINE[default]+="pci=nommconf pcie_bus_peer2peer"
```
Forces MPS=128 bytes everywhere. Fixes malformed-TLP storms from MPS mismatch
between the bridge and root port. (Avoid `pcie_bus_perf` — known to crash some
systems.)

### Test 6 — BIOS: slot Max Link Speed → Gen 1
**This is not a kernel param** — it's the most consistently field-reported fix
for AE-7/AE-9 across openSUSE, EndeavourOS, Linux Mint, MSI forums:
- BIOS → Advanced / PCIe settings → set the AE-7's slot **Max Link Speed to Gen 1**
  (PCIe 1.0). Optionally reduce lane width to x1.

The bridge has marginal Gen-3/Gen-4 link negotiation; Gen 1 trains reliably.

### Test 7 — `setpci` to force-clear ASPM on the bridge
Because `pcie_aspm=off` leaves BIOS-configured ASPM untouched (documented
gotcha), the manual override is:
```
# Find the bridge BDF first:
lspci -nn -d 1b21:1080
# Clear ASPM bits in the Link Control register (offset 0x50, bits 0-1):
setpci -s <BDF> CAP_EXP+10.w=0000
```
Put this in an early init/systemd unit if it helps, or better, disable ASPM in
BIOS if exposed.

### Test 8 — interrupt / hotplug (if slot is hotplug-capable)
```
KERNEL_CMDLINE[default]+="pci=nomsi modprobe.blacklist=pciehp"
```

## Once boot succeeds: capture the bridge revision

```
lspci -nn -d 1b21:1080
lspci -vvv -s <bridge-BDF>
```
- If the bridge is **rev 04+**, that's the "new revision from 2022" and explains
  why the in-kernel quirks (written for rev 01/03) don't fully cover it.
- If the ID is **not** `1b21:1080` (e.g., a Pericom `12d8:*` ID), the kernel
  quirks don't match at all — that's the root cause, and the fix is a new quirk.

## Once boot succeeds: re-enable drivers one by one

After the enumeration hang is fixed, test whether the audio driver also works:
1. Keep the winning param(s).
2. Remove `snd_hda_intel` blacklist → reboot → does it still boot?
3. Remove `ca0132` blacklist → reboot → does it still boot + produce sound?
4. If step 3 hangs at the driver level, *that's* where the `patch_ca0132.c` rig
   becomes relevant (BAR2 MMIO path). But `pci=nommconf` may also fix it, since
   BAR2 is separate from ECAM.

## Narrowing (after a working combo is found)

Remove params one at a time to find the minimal set:
- Drop `pci=noaer` first (it's just log noise suppression).
- Then test dropping `pcie_aspm=off`.
- Then test dropping `pci=nommconf` (this is the one most likely to be essential).
The goal is the smallest param set that keeps boot reliable.

## Sources (ASMedia bridge specifics)
- Kernel quirk `quirks.c:2534` — ASPM disable for ASM1083/1085 (AER timeouts)
- Kernel `probe.c:1806` — config-space aliasing, names "rev 01 & 03"
- Kernel `quirks.c:4430` — DMA alias (bug 44881)
- EndeavourOS — "ASM1085 new revision from 2022" quote
- Osmocom — rev 04 works with `pcie_aspm=off pci=noaer,nocrs`
- Bugzilla #208667 — AER errors on ASM1083/1085
- Bugzilla #217510 — AE-7 works only from Live distros
- Patchwork — the ASPM-disable quirk patch (Robert Hancock, 2020)

# Enabling AMD IOMMU on the host (one-time)

VFIO passthrough of the AE-7 requires the AMD IOMMU enabled in the kernel. This
host (Ryzen 7800X3D) has AMD-V and **33 IOMMU groups are already present** even
without explicit cmdline args, which means the firmware likely has AMD-Vi on. We
confirm and tighten it explicitly below.

> **Read before doing anything else:** this project's safety model depends on the
> host *never* loading the ca0132 driver. Install `blacklist-ca0132.conf` (this
> directory) BEFORE installing the card. See that file's header.

## 1. Add IOMMU params to the kernel command line

This host uses **`cachyos-hooks`** with **`mkinitcpio`** (confirmed: `pacman -Q
mkinitcpio cachyos-hooks`). The kernel cmdline is authored in
**`/etc/kernel/cmdline`** (currently contains `quiet nowatchdog splash rw
root=UUID=...`) and the `cachyos-hooks` kernel-install hook bakes it into the
boot artifact at install time. `/boot` is a separate vfat ESP on
`/dev/nvme2n1p1`.

Append these two parameters to `/etc/kernel/cmdline`:

```
amd_iommu=on iommu=pt
```

- `amd_iommu=on` — explicitly enable the AMD IOMMU.
- `iommu=pt` — passthrough mode for host devices (identity mapping = no perf hit;
  only VFIO-assigned devices get translated). The recommended mode for KVM
  passthrough rigs.

### How to apply (this exact host)

```bash
# View the current cmdline (running kernel):
cat /proc/cmdline

# Edit the central cmdline file:
sudo $EDITOR /etc/kernel/cmdline
#   → append to the existing line:  amd_iommu=on iommu=pt

# Re-bake the kernel package so the new cmdline takes effect. CachyOS uses
# mkinitcpio via the kernel-install hook, so reinstall the kernel package:
sudo pacman -S linux-cachyos      # re-triggers the hook → rebuilds initramfs + boot entry
# (If you also run linux-cachyos-lts, reinstall that too.)

# If you prefer not to reinstall, the explicit rebuild is:
sudo mkinitcpio -P
```

Reboot.

## 2. Verify after reboot

```bash
# IOMMU is active — the AMD-Vi/DMAR banner should appear:
dmesg | /usr/bin/grep -iE 'AMD-Vi|AMD-Vi.*enabled|IOMMU' | head

# IOMMU groups exist (should be ~33 on this board):
ls /sys/kernel/iommu_groups/ | wc -l

# The vfio modules are loadable:
modprobe vfio_pci
lsmod | /usr/bin/grep vfio
```

> **Host caveat:** this CachyOS box has a `grep` shell-function wrapper that
> rejects combined flags like `-iE` ("conflicting matchers specified"). Always
> call `/usr/bin/grep` (as above) or `command grep` in scripts and one-liners.

## 3. Install the host blacklist (do this BEFORE seating the card)

```bash
sudo cp host/blacklist-ca0132.conf /etc/modprobe.d/blacklist-ca0132.conf
sudo mkinitcpio -P    # rebuild so the blacklist is in the initramfs too
```

## 4. Seat the card, then isolate it

Once the AE-7 is physically installed and the host boots cleanly (it will,
because the module is blacklisted), run:

```bash
sudo ./host/isolate-card.sh
```

That detects the AE-7's PCI BDF, confirms it's alone in its IOMMU group, and
binds it to `vfio-pci`. After that, pass the card through to a Windows VM via
libvirt/QEMU (`-device vfio-pci,host=$BDF`).

## Troubleshooting

- **No IOMMU groups after reboot:** enter the BIOS/UEFI → Advanced / AMD CBS →
  enable `IOMMU` (sometimes under `AMD CBS → NBIO Common Options → IOMMU`).
- **Card shares a group with the GPU:** unsafe to pass through alone. Use the
  `acs_override` kernel patch (or the `pcie_acs_override=` param) at your own
  risk, or move the card to a different PCIe slot to get a cleaner grouping.
- **Host still hangs on boot despite the blacklist:** the blacklist may not be in
  the initramfs. Rebuild it (`mkinitcpio -P` / `dracut --regenerate-all`) and
  verify `lsmod | /usr/bin/grep ca0132` is empty after a clean boot.

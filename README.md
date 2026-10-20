# Sound Blaster AE-7 on Linux: fix for boot hang and no sound

A working fix for the **Creative Sound Blaster AE-7** on Linux. Newer AE-7 cards put
the CA0132 audio controller behind an **ASMedia ASM1083/1085 PCIe-to-PCI bridge**.
With the stock `snd_hda_intel` driver this bridge locks up during probe: boot hangs
for minutes, USB and SATA controllers on the same chipset die, and the card gives no
sound. Two kernel patches fix it. This repository packages them as a DKMS module
(`ae7-hda`) for `snd-hda-intel` and `snd-hda-codec-ca0132`.

Status (2026-10-20): playback (headphone, front out) and the microphone work on
Linux 7.2.10 (CachyOS), MSI MAG X670E Tomahawk WiFi, Ryzen 7 7800X3D. The patches
are not upstream yet.

## Is this your problem?

```sh
lspci -nn | grep -E '1102:0010|1b21:1080|10e3:8111'
```

- `1102:0010` (Creative CA0132) and `1b21:1080` (ASMedia ASM1083/1085, rev 03):
  this fix is for you. Reports with this bridge fail on Intel and AMD boards,
  with kernels 4.x to 7.2.
- `10e3:8111` (Tundra/IDT Tsi381 bridge, early AE-7 batches): the stock driver
  works with this bridge. Your problem is a different one.
- AE-5 and AE-5 Plus (`1102:0012`, no bridge) are not affected.
- AE-9: same bridge, same lockup, but its audio path also needs codec work. Not
  tested here; see [verzic/sb-ae9](https://github.com/verzic/sb-ae9).

Typical symptoms with the stock kernel:

- Boot takes 4-5 minutes or stops. With Plymouth (`splash`) it can stop at the
  splash screen.
- USB devices and SATA disks behind the same chipset drop out. If the root
  filesystem is there, the system goes to emergency mode.
- The card works "only from live USB" or only on some boots.
- Kernel log lines like these (`xx` is your bus number):

```
snd_hda_intel 0000:xx:00.0: CORB reset timeout#2, CORBRP = 65535
snd_hda_intel 0000:xx:00.0: no AFG or MFG node found
snd_hda_intel 0000:xx:00.0: no codecs initialized
watchdog: BUG: soft lockup - CPU#N stuck for NNs!   (snd_hdac_bus_init_cmd_io, azx_probe_work)
Watchdog detected hard LOCKUP on cpu N
xhci_hcd 0000:xx:00.0: HC died; cleaning up
ahci 0000:xx:00.0: AHCI controller unavailable!
```

With the fix but without `iommu=pt`, playback stops after a few seconds and the
log shows:

```
snd_hda_intel 0000:14:00.0: AMD-Vi: Event logged [IO_PAGE_FAULT domain=0x0028 address=0xfff40000 flags=0x0000]
snd_hda_intel 0000:14:00.0: azx_get_response timeout, switching to polling mode: last cmd=0x1161c0c0
snd_hda_intel 0000:14:00.0: azx_get_response timeout, switching to single_cmd mode: last cmd=...
```

## Cause

The ASM1083/1085 rev 03 bridge on the card wedges after a burst of about 14-18
back-to-back posted MMIO writes with no read between them. The stock HDA init does
such a burst (`azx_int_clear()` and `snd_hdac_bus_init_cmd_io()`) before its first
read. After that every read returns all-ones after a ~220 ms timeout, the CORBRP
poll spins for minutes with interrupts off, and the chipset switch takes its other
devices down with it. Kernel options (`single_cmd`, `enable_msi=0`, `probe_mask`,
`pcie_aspm=off`) do not help, because the burst comes first.

The fix reads each register back after it is written:

- [`0002-ALSA-hda-flush-posted-writes-on-CTHDA.patch`](vm/patches/0002-ALSA-hda-flush-posted-writes-on-CTHDA.patch):
  `snd_hdac_reg_write{b,w,l}()` read back when `bus->flush_writes` is set.
  `snd_hda_intel` sets it for Creative CTHDA controllers
  (`snd_hda_intel.flush_writes=-1/0/1`, auto/off/on).
- [`0003-ALSA-hda-ca0132-flush-region-2-writes.patch`](vm/patches/0003-ALSA-hda-ca0132-flush-region-2-writes.patch):
  the same for the ca0113 (BAR2) writes in `ca0132.c`.

The controller also reads past the end of its PCM ring at each wrap. A translating
IOMMU faults on that read, so the host needs `iommu=pt`. Details and evidence:
[`reference/findings.md`](reference/findings.md).

## Install the fix

You need git, make, dkms and the headers for your running kernel. Kernels built
with clang (CachyOS) also need clang and lld. Only CachyOS with 7.2.10 is tested;
the scripts expect the `sound/hda/` source layout of recent kernels.

If the machine hangs at boot with the card installed, first add
`pci-stub.ids=1102:0010` to the kernel command line once at the boot menu. This
keeps all drivers off the card.

```sh
git clone https://github.com/craciunoiuc/ae7-investigation.git
cd ae7-investigation
vm/kernel/fetch.sh             # shallow linux-stable clone (source of the modules)
host/dkms/mkdkms.sh            # sources for the running kernel + patches 0002/0003, test build
sudo host/dkms/install.sh      # DKMS ae7-hda into updates/dkms + guarded vfio-pci claim
```

Add `iommu=pt` to the kernel command line and remove `splash`:

- GRUB: `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then
  `sudo grub-mkconfig -o /boot/grub/grub.cfg`.
- systemd-boot / UKI: `/etc/kernel/cmdline`, then rebuild the image.
- limine (CachyOS): `KERNEL_CMDLINE[default]+=" iommu=pt"` in
  `/etc/default/limine`, then `sudo limine-update`.

Then `sync` and reboot. Be at the machine the first time.

Set the mixer once (`sudo alsactl store` keeps it):

```sh
amixer -c Creative cset name='HP/Speaker Auto Detect Playback Switch' off
amixer -c Creative cset name='Output Select' Headphone      # or Speakers (front out)
amixer -c Creative cset name='Master Playback Volume' 90
amixer -c Creative cset name='Mic Boost Capture Switch' 2   # 20 dB
```

`Master` scales both the DAC amp and the DSP volume: at 60 or less the card is
silent. Jacks on the rear bracket, counted from the right: 1 = mic, 2 = headphone,
3 = front out. Rear, Center/Sub and optical are untested.

- **After a kernel update** run `host/dkms/mkdkms.sh` and
  `sudo host/dkms/install.sh` again. Until then the guarded claim keeps the card
  on vfio-pci: safe, but silent. The stock driver never touches the card.
- **Undo:** `sudo host/dkms/install.sh --uninstall` (back to the vfio-pci claim),
  `sudo host/setup.sh --undo` (removes the claim and the sudoers entry).
- **Own kernel build:** apply the two patches with `git am` to a 7.2 tree.

## Upstream status and related work

The patches are not submitted yet. Kernel bug reports:
[217510](https://bugzilla.kernel.org/show_bug.cgi?id=217510) (AE-7),
[221614](https://bugzilla.kernel.org/show_bug.cgi?id=221614) (AE-7 soft lockup),
[219552](https://bugzilla.kernel.org/show_bug.cgi?id=219552) (AE-9).

Other people found the same write-burst wedge in 2026:

- [AffSeda/Creative_AE7_Linux](https://github.com/AffSeda/Creative_AE7_Linux):
  AE-7, flush every write, Debian kernel source package.
- [verzic/sb-ae9](https://github.com/verzic/sb-ae9): AE-9 DKMS, minimal flush
  patch, Windows driver analysis.
- Kira Backes, replacement AE-7 driver:
  [bug 221614 attachment](https://bugzilla.kernel.org/attachment.cgi?id=310852).

More sources: [`reference/research.md`](reference/research.md).

## The VM rig (for further driver work)

QEMU direct-boots a patchable guest kernel (linux-stable v7.2.10 in `vm/linux/`)
with the card passed through via VFIO. The guest root is the host `/` over
read-only virtio-9p; a test script runs, output lands in `logs/run-NNN[-label]/`,
the VM powers off. One iteration takes seconds and needs no host reboot.

To switch the card from the host driver to the VM rig:

```sh
sudo host/setup.sh             # sudoers for qemu/dmesg/lspci (keeps the guarded claim)
# /etc/default/limine: KERNEL_CMDLINE[default]+=" pcie_acs_override=downstream,multifunction"
sudo limine-update && reboot
sudo host/bind.sh --bind       # snd_hda_intel -> vfio-pci (stop using the card first)
host/bind.sh --check
```

Then:

```sh
vm/kernel/fetch.sh             # clone v7.2.10, branch ae7, apply vm/patches
vm/kernel/build.sh             # bzImage + modules into vm/build/
vm/run.sh --emulated --test probe                          # rig check, no card
vm/run.sh --passthrough --mmap --test sweep --test-args "30 all 90"
```

Reboot to give the card back to the host driver. See [`AGENTS.md`](AGENTS.md)
for the loop and the safety rules, and [`vm/experiments.md`](vm/experiments.md)
for the experiments and their results.

## Layout

```
README.md               this file
AGENTS.md               agent hand-off: loop, conventions, safety rules
reference/
  findings.md           result, root cause, evidence, hardware, wrong old conclusions
  research.md           external research (bug reports, out-of-tree fixes)
  ae7-outputs.md        jack map and output hardware research
host/
  dkms/mkdkms.sh        DKMS source tree + test build for a host kernel
  dkms/install.sh       sudo: DKMS install/uninstall, guarded vfio-pci claim
  setup.sh              sudo: vfio-pci claim, sudoers for the VM rig; --undo
  bind.sh               --check / --status; sudo --bind / --unbind
  capture.sh            root lspci, IOMMU group, reset_method, host dmesg
vm/
  config.sh             shared variables (KVER, IDs, paths, QEMU defaults)
  run.sh                boot the guest, run one test, collect output
  experiments.md        experiment plan and results
  kernel/               fetch.sh, build.sh, ae7.config
  patches/              guest patch series: 0002/0003 fix, 0001/0004 debug
  guest/                init.sh (PID 1), tests/*.sh, tools/hda-mmio.py
  linux/, build/        guest kernel source and build (gitignored)
logs/
  STATUS.md             append-only log of runs and decisions
  run-*/, capture-*/    per-run and host capture output (gitignored)
```

## License

GPL-2.0, the same as the Linux kernel. See [`LICENSE`](LICENSE).

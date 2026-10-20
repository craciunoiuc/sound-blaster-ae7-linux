# AE-7 on Linux

The Creative Sound Blaster AE-7 now works on this CachyOS host (MSI MAG X670E
Tomahawk, Ryzen 7 7800X3D): headphone, front out and mic.

The card is a CA0132 HDA controller (`1102:0010`) behind an ASMedia ASM1083/1085
PCIe-to-PCI bridge (`1b21:1080` rev 03). The bridge wedges after a burst of posted
MMIO writes, and the stock HDA init does such a burst. The fix reads back after
each register write. Details: [`reference/findings.md`](reference/findings.md).

## Host setup (the fix)

```sh
host/dkms/mkdkms.sh            # as user: linux-stable sources + patches 0002/0003, test build
sudo host/dkms/install.sh      # DKMS ae7-hda into updates/dkms + guarded vfio-pci claim
# /etc/default/limine: KERNEL_CMDLINE[default]+=" iommu=pt"   (no "splash")
sudo limine-update
sync && reboot                 # first time: be at the machine
```

Then set the mixer once (`sudo alsactl store` keeps it):

```sh
amixer -c Creative cset name='HP/Speaker Auto Detect Playback Switch' off
amixer -c Creative cset name='Output Select' Headphone      # or Speakers (front out)
amixer -c Creative cset name='Master Playback Volume' 90
amixer -c Creative cset name='Mic Boost Capture Switch' 2   # 20 dB
```

Jacks on the rear bracket, counted from the right: 1 = mic, 2 = headphone,
3 = front out. Rear, Center/Sub and optical are untested.

- **`iommu=pt` is required.** The controller reads past the end of its PCM ring;
  a translated IOMMU faults on that read and the codec stops answering.
- **After a kernel update** run `host/dkms/mkdkms.sh` and
  `sudo host/dkms/install.sh` again. Until then the guarded claim keeps the card
  on vfio-pci: safe, but silent.
- **Undo:** `sudo host/dkms/install.sh --uninstall` (back to the vfio-pci claim),
  `sudo host/setup.sh --undo` (removes the claim and the sudoers entry).

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

# Agent hand-off

This file is for driver work in this repository. To install the fix on a machine
with an AE-7, follow [`README.md`](README.md), "Install the fix".

The Creative AE-7 is a CA0132 HDA controller behind an ASMedia ASM1083/1085
PCIe-to-PCI bridge. It works on the host since 2026-10-20 with the DKMS package
`ae7-hda` (guest patches 0002 + 0003) and `iommu=pt`. Driver work happens in a
QEMU/VFIO rig with a patchable guest kernel; bare-metal reboots are not part of
the loop.

The card is in one of two modes:

- **Host mode** (default): the DKMS `snd-hda-intel` drives the card. The guarded
  claim in `/etc/modprobe.d/ae7-vfio.conf` hands the card to vfio-pci only on
  kernels without the DKMS modules.
- **VM mode**: the card is on vfio-pci (`sudo host/bind.sh --bind`), and the host
  cmdline has `pcie_acs_override=downstream,multifunction` so that the card's
  IOMMU group holds only the bridge and the controller. Reboot to go back.

## Read first

1. [`reference/findings.md`](reference/findings.md): result, root cause, host
   requirements, evidence, hardware, wrong old conclusions, open items.
2. [`vm/experiments.md`](vm/experiments.md): the experiment plan and its results.
3. The tail of [`logs/STATUS.md`](logs/STATUS.md): the last runs and decisions.
4. [`reference/research.md`](reference/research.md) and
   [`reference/ae7-outputs.md`](reference/ae7-outputs.md): external research.

Git history before the 2026-10-20 restructure (`80f4339`) has the old bare-metal
docs and patches. Do not reuse any conclusion from them unless findings.md
confirms it.

## Before a passthrough run

`host/bind.sh --check` must pass: the card is bound to vfio-pci and its IOMMU group
is viable. If it fails, the card is in host mode or the ACS override is missing.
Ask the user to switch to VM mode (README, "The VM rig"). Agents do not do these
steps.

## Iteration loop

1. **Edit** the guest kernel in `vm/linux/` (branch `ae7`). The main files are
   `sound/hda/controllers/intel.c` (PCI driver, caps, probe),
   `sound/hda/common/controller.c` (CORB/RIRB, `probe_codec`),
   `sound/hda/core/controller.c` (reset, cmd I/O) and `sound/hda/codecs/ca0132.c`.
   Print with `dev_*()` / `codec_*()` so that each line carries the BDF. The old
   notes could not tell the AE-7 lines apart from the AMD HDA controllers.
2. **Build**: `vm/kernel/build.sh` (incremental, output in `vm/build/`).
3. **Run**:
   - `vm/run.sh --emulated --test NAME` if you changed shared HDA code. It checks
     that a normal controller still works.
   - `vm/run.sh --passthrough --test NAME --name LABEL` for the card. run.sh runs
     `sync` first. BAR access is trapped by default (`x-no-mmap=on`), which
     spaces writes; `--mmap` gives real timing.
   - Tests live in `vm/guest/tests/NAME.sh` (default `probe`): `probe`, `play`,
     `verbs`, `regs`, `pio`, `shell`, `sweep` (each output in turn, voice/tone),
     `outdiag` (play + record "What U Hear"), `mictest` (record, play back).
     `regs` and `pio` use `vm/guest/tools/hda-mmio.py` to read BAR0 and send
     immediate commands with no driver loaded.
   - Use `Master` 90 or more when a person listens: Master scales both the DAC amp
     and the DSP volume (`sweep`/`mictest` take it in `--test-args`).
   - `--modparams "..."` takes bare `snd_hda_intel` parameters, for example
     `--modparams "ae7_debug=1"`. Default is empty. Patch 0002 flushes each
     register write on CTHDA unless `flush_writes=0` (that is the upstream driver).
     Add `enable_msi=0` only if a patch removes the CTHDA NO_MSI cap.
   - Other options: `--append "..."` (guest cmdline), `--test-args`, `--trace`
     (QEMU vfio MMIO trace, disables mmap), `--timeout N`, `--interactive`,
     `--dry-run`. See `vm/run.sh --help`.
   - The last line is `RESULT: PASS|FAIL|TIMEOUT|NO-RESULT — reason — dir`. The
     exit code is 0 only on PASS.
4. **Read** `logs/run-NNN[-label]/`: `serial.log` (guest console), plus
   `host-dmesg.txt` for passthrough runs and `qemu-trace.log` with `--trace`. If
   the host log has IOMMU/AER/vfio lines, the RESULT reason shows how many.
5. **Record**: append an entry to `logs/STATUS.md` (format in its header). If a
   result changes what is known, update `reference/findings.md`.
6. **Keep** a kernel change: commit it on `ae7` in `vm/linux`, then re-export the
   whole series from the repo root (keep the fix patches free of the debug
   patches, so that `host/dkms/mkdkms.sh` can apply 0002 + 0003 alone):
   ```sh
   rm -f vm/patches/*.patch
   git -C vm/linux format-patch -o "$PWD/vm/patches" v7.2.10..ae7
   ```
   `vm/kernel/fetch.sh` rebuilds `ae7` from `v7.2.10` + `vm/patches/`. It refuses
   to run if the tree has local changes or commits that are not exported.
   `--force` discards them.

## Conventions

- Change one thing per run. Use a `--name` label that says what changed.
- Run directories are gitignored. Copy the lines that matter (register values,
  `res=`, errors, host dmesg) into `logs/STATUS.md`.
- Find devices by ID (`1102:0010`, bridge `1b21:1080`), never by BDF. Bus numbers
  shift when the card is installed. `ae7_bdfs` in `vm/config.sh` does the lookup.
- In findings.md, keep observed facts apart from inferences. Mark guesses.
- Shell scripts: bash, `set -euo pipefail`, source `vm/config.sh`. shellcheck is
  not installed, so run at least `bash -n`.
- Do not commit or push unless the user asks.

## Safety rules

- **Never run `--mmap` with `flush_writes=0`.** Direct BAR access with the
  upstream write bursts is the known bridge wedge (see `reference/findings.md`);
  it can take down host devices on the same chipset.
- **The stock `snd_hda_intel` must never probe the card.** Only the DKMS module
  (with `flush_writes`) may drive it. Keep `/etc/modprobe.d/ae7-vfio.conf`; after
  a kernel update the card stays on vfio-pci until the user rebuilds the DKMS
  package for that kernel. The onboard AMD HDA controllers use `snd_hda_intel`
  as normal.
- **Host mode needs `iommu=pt`.** Without it the controller's read past the PCM
  ring end faults in the IOMMU and the codec stops answering.
- **The VM does not isolate the physical bus.** On bare metal, probing the card
  killed the sibling xHCI and SATA controllers on chipset 2. nvme2 is half of the
  root RAID0 and sits behind the same chipset uplink. A link fault can take down
  the host's root filesystem. Therefore:
  - Run `sync` before every passthrough run (`vm/run.sh` does it). Do the same
    before anything else that touches the card from the host.
  - The first passthrough run must be attended. The same applies to the first run
    of a new kind of access (new test, DMA started a new way, reset changes): the
    user is at the machine and ready to power-cycle. Ask before you start such a run.
  - Stop and ask the user after any run that shows host AER, `IO_PAGE_FAULT`, or
    errors from devices other than the card.
- **No sudo** except the NOPASSWD entries that the scripts use
  (`sudo -n qemu-system-x86_64`, `sudo -n dmesg`, `sudo -n lspci`). The user makes
  all host changes (`host/setup.sh`, `host/dkms/install.sh`, cmdline, reboots).
- Keep `vm/run.sh --emulated` working. It is the rig check before passthrough.
- Changing the CTHDA caps is risky. When the old work dropped NO_MSI on bare metal,
  `pci_alloc_irq_vectors()` hung.

## Host quirks

- CachyOS has a `grep` shell-function wrapper that rejects combined flags
  (`grep -iE` gives "conflicting matchers specified"). Use `/usr/bin/grep` in
  commands and scripts.
- shellcheck is not installed.
- The host cmdline lives in `/etc/default/limine` (`KERNEL_CMDLINE[default]`). It
  must not contain `splash`.
- The old bare-metal flow may have left `/lib/modules/7.1.3-dirty` and a
  `linux-ae7dbg` limine entry. They are unused. Do not boot them.

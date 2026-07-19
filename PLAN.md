# Plan — AE-7 Linux boot-hang investigation (methodology + what actually happened)

> This was the original plan. The investigation **pivoted from QEMU/VFIO to
> direct-to-hardware module-rebuild testing** once it became clear the card had
> to be probed on real hardware (QEMU can't emulate the ASMedia bridge). The
> authoritative findings live in `reference/complete-findings.md`.

## The problem

The Creative Sound Blaster AE-7 (CA0132 codec behind an ASMedia ASM1083/1085
PCIe-to-PCI bridge, PCI `1102:0010` / subsystem `1102:0081`) hangs Linux boot on
a CachyOS host. Kernel Bugzilla #217510. Creative ships no official Linux driver.

## What was actually done (direct-to-hardware)

1. Cloned Linux v7.1.3; instrumented `sound/hda/{controllers/intel.c,
   common/controller.c, core/controller.c}` and `codecs/ca0132.c` with
   HDACTRLDBG/AE7DBG prints (patches 0001-0003).
2. Built the full CachyOS-config kernel once (`make olddefconfig && make -j8
   bzImage modules`), then iterated by rebuilding individual modules
   (`make M=sound/hda/controllers modules`) — seconds per change.
3. Booted via a `linux-ae7dbg` limine entry created with
   `limine-entry-tool --add-kernel`.
4. Read HDACTRLDBG prints off the console at each freeze; tightened
   instrumentation to narrow the hang point across ~8 iterations.

## Findings

See `reference/complete-findings.md` for the full list. Headline:

- **FIXED:** Plymouth (`splash`), MSI allocation hang (`enable_msi=0`),
  concurrent-probe hard lockup (serialize mutex).
- **UNSOLVED:** `probe_codec → res=0x0` (CORB/RIRB verbs don't reach the codec
  through the bridge). Card works in Windows.
- **NEXT (not yet run):** `snd_hda_intel.single_cmd=1` — bypasses CORB/RIRB DMA,
  uses PIO immediate registers (MMIO the bridge forwards correctly).

## Iteration loop (for future work)

```
   edit kernel/sound/hda/{controllers,common,core,codecs}/*.c
              │
              ▼
   make M=sound/hda/controllers modules    (or =sound/hda/codecs)
              │
              ▼
   zstd + cp to /lib/modules/7.1.3-dirty/... + depmod -a
              │
              ▼
   reboot linux-ae7dbg limine entry
              │
              ▼
   read HDACTRLDBG prints → last line before freeze = hang point
              │
              ▼
   append to logs/STATUS.md → decide next patch
```

## One-time host setup (for VFIO passthrough, if single_cmd fails)

If `single_cmd=1` doesn't fix `res=0x0`, the bridge fundamentally can't forward
HDA verbs and the path is VFIO passthrough to Windows (where the card works):

1. Install the host blacklist: `sudo cp host/blacklist-ca0132.conf /etc/modprobe.d/`
   + `sudo mkinitcpio -P`.
2. Enable AMD IOMMU per `host/enable-iommu.md`, reboot.
3. Isolate the card: `sudo ./host/isolate-card.sh` (binds to vfio-pci).
4. Pass `14:00.0` (and `14:00.1`) through to a Windows VM via libvirt/QEMU.

## Sources

- Kernel Bugzilla #217510 (the bug), #219552 (AE-9 sibling).
- `reference/complete-findings.md` — verified anchors + decision table.
- `../ZCodeProject/ae7-linux-testing.md` — original testing checklist.

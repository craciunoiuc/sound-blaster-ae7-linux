# sound-card — Creative AE-7 Linux boot-hang investigation

Investigation into why the Creative Sound Blaster AE-7 (CA0132 codec behind an
ASMedia ASM1083/1085 PCIe-to-PCI bridge) hangs Linux boot on a CachyOS host
(MSI MAG X670E Tomahawk, Ryzen 7800X3D).

> **Start here:** [`reference/complete-findings.md`](reference/complete-findings.md)
> is the authoritative summary of every finding, fix, and remaining experiment.

## Outcome

**Three real software bugs found and fixed** (in the working `kernel/` tree):
1. Plymouth (`splash`) blocks early boot → remove `splash`
2. MSI allocation hangs through the bridge → `snd_hda_intel.enable_msi=0`
3. Concurrent probe of two PCI functions causes a hard CPU lockup → serialize
   `azx_probe_continue` with a mutex

**One unsolved core problem:** the CORB/RIRB command path to the codec returns
`res=0x0` — the bridge doesn't forward HDA verbs under Linux. The card works in
Windows, so the hardware is capable; Windows must initialize the bridge
differently.

**Highest-value next experiment (not yet run):** `snd_hda_intel.single_cmd=1`
on top of the working baseline. This bypasses CORB/RIRB DMA and uses the PIO
immediate-command registers (controller MMIO, which the bridge *does* forward
correctly). See complete-findings.md §"The MOST IMPORTANT MISSED EXPERIMENT".

## Status

| Item | State |
|---|---|
| Card installed | ✅ `14:00.0` (CA0132) + `14:00.1` behind `13:00.0` ASMedia bridge |
| Plymouth fix (`splash` removed) | ✅ |
| MSI fix (`enable_msi=0`) | ✅ |
| Probe serialization mutex | ✅ in `kernel/sound/hda/controllers/intel.c` |
| DMA/snoop bridge override | ✅ in tree (didn't fix res=0x0 but is correct for the bridge) |
| Host boots with `snd_hda_intel` blacklisted | ✅ |
| Host boots with `snd_hda_intel` loading | ⚠️ reaches emergency mode (AHCI dies, codec returns 0x0) |
| **`single_cmd=1` test** | ⬜ **NOT YET RUN — the key remaining experiment** |

## Working kernel cmdline (current best)

```
quiet nowatchdog rw root=UUID=cf0cc394-37e9-4774-b6be-57e55351af52 amd_iommu=on iommu=pt loglevel=8 ignore_loglevel snd_hda_intel.enable_msi=0
```
- No `splash` (Plymouth fix)
- `snd_hda_intel.enable_msi=0` (MSI fix)
- `loglevel=8 ignore_loglevel` only needed while reading HDACTRLDBG prints

## How the kernel was built/tested (direct-to-hardware)

The investigation went direct-to-hardware via module rebuilds, not QEMU:
1. Edit `kernel/sound/hda/controllers/intel.c` (and `controller.c`, `ca0132.c`)
2. `cd kernel && make M=sound/hda/controllers modules` (seconds, not minutes)
3. `sudo cp snd-hda-intel.ko.zst /lib/modules/7.1.3-dirty/.../ && sudo depmod -a`
4. Reboot the `linux-ae7dbg` limine entry (created via `limine-entry-tool --add-kernel`)

The full `bzImage` was built once via `make olddefconfig && make -j8 bzImage modules`
using the CachyOS `.config`, then individual modules rebuilt per iteration.

## Project layout

```
sound-card/
├── README.md                       ← you are here
├── AGENTS.md                       ← agent hand-off (needs update for direct-hardware flow)
├── PLAN.md                         ← original methodology (QEMU-centric, partly superseded)
├── reference/
│   ├── complete-findings.md        ← AUTHORITATIVE summary of all findings + next step
│   ├── ae7-code-anchors.md         ← ca0132.c function/line anchors (v7.1.3)
│   └── archive/                    ← superseded phase docs (historical narrative)
├── patches/
│   ├── README.md                   ← patch conventions
│   ├── 0001-ae7-debug-instrumentation.patch        ← ca0132 codec AE7DBG prints
│   ├── 0002-hda-controller-debug-instrumentation.patch  ← controller HDACTRLDBG prints
│   ├── 0003-narrow-irq-gap-instrumentation.patch   ← azx_acquire_irq + probe entry prints
│   └── 0004-ae7-pci-id-fix.patch                   ← failed PCI-ID override (iteration artifact)
├── host/
│   ├── blacklist-ca0132.conf       ← host safety (install to /etc/modprobe.d/)
│   ├── enable-iommu.md             ← AMD IOMMU setup for CachyOS/limine
│   └── isolate-card.sh             ← bind AE-7 to vfio-pci (for passthrough)
├── kernel/                         ← Linux v7.1.3 with all fixes applied (working tree)
├── build/                          ← bzImage + initramfs + staged modules
└── logs/STATUS.md                  ← iteration memory
```

## Key facts

- **PCI IDs:** bridge `1b21:1080` rev 03; controller `1102:0010`; codec subsystem `1102:0081`
- **Source (v7.1):** `sound/hda/controllers/intel.c` (controller),
  `sound/hda/common/controller.c` (core), `sound/hda/codecs/ca0132.c` (codec)
- **The card works in Windows** — the hardware is capable; the blocker is
  Linux-side bridge initialization.

## Sources
- [Kernel Bugzilla #217510](https://bugzilla.kernel.org/show_bug.cgi?id=217510)
- `../ZCodeProject/ae7-linux-testing.md` — original testing checklist

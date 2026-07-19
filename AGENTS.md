# Agent hand-off — read this first

You are continuing work on the Creative AE-7 (CA0132 behind an ASMedia
ASM1083/1085 PCIe-to-PCI bridge) Linux boot-hang investigation.

## Current state (read this before anything else)

**Authoritative summary:** [`reference/complete-findings.md`](reference/complete-findings.md)

Three software bugs are FIXED (in the `kernel/` working tree):
1. Plymouth (`splash`) blocks boot → removed from cmdline
2. MSI allocation hangs → `snd_hda_intel.enable_msi=0`
3. Concurrent-probe hard lockup → `azx_probe_serialize_mutex` in `intel.c`

**Unsolved:** `probe_codec(addr=1)` returns `res=0x0` — the codec doesn't respond
to the CORB/RIRB vendor-ID query through the bridge. The card works in Windows.

**The key experiment NOT YET RUN:** `snd_hda_intel.single_cmd=1`. This bypasses
CORB/RIRB DMA and uses PIO immediate-command registers (controller MMIO, which
the bridge *does* forward). The early blind test of `single_cmd=1` failed because
the MSI hang and concurrent-probe lockup weren't fixed yet — they are now.

## How to iterate (direct-to-hardware, NOT QEMU)

The investigation builds individual kernel modules and boots them on the host via
a limine entry. Steps:

1. **Edit source** in `kernel/sound/hda/`:
   - `controllers/intel.c` — the controller driver (probe, IRQ, caps)
   - `common/controller.c` — core HDA bus (CORB/RIRB, probe_codec, reset)
   - `core/controller.c` — bus init/reset primitives
   - `codecs/ca0132.c` — the CA0132 codec driver

2. **Rebuild just the module** (seconds):
   ```bash
   cd kernel
   make M=sound/hda/controllers modules    # for snd-hda-intel changes
   # OR
   make M=sound/hda/codecs modules          # for ca0132 changes
   ```

3. **Stage + install** (the rebuild produces an uncompressed `.ko`; compress it):
   ```bash
   zstd -f -19 kernel/sound/hda/controllers/snd-hda-intel.ko \
     -o build/staging/lib/modules/7.1.3-dirty/kernel/sound/hda/controllers/snd-hda-intel.ko.zst
   sudo cp build/staging/lib/modules/7.1.3-dirty/kernel/sound/hda/controllers/snd-hda-intel.ko.zst \
     /lib/modules/7.1.3-dirty/kernel/sound/hda/controllers/
   sudo depmod -a 7.1.3-dirty
   ```

4. **Reboot** the `linux-ae7dbg` limine entry (created once via
   `sudo limine-entry-tool --add-kernel "linux-ae7dbg" "/boot/initramfs-linux-ae7dbg.img" "/boot/vmlinuz-linux-ae7dbg"`).

5. **Read the HDACTRLDBG prints** on the console (or photograph the freeze).
   The last line before silence = the hang point.

6. **Append to `logs/STATUS.md`** what happened.

## The working cmdline

```
quiet nowatchdog rw root=UUID=cf0cc394-37e9-4774-b6be-57e55351af52 amd_iommu=on iommu=pt loglevel=8 ignore_loglevel snd_hda_intel.enable_msi=0
```
- No `splash` (Plymouth fix)
- `loglevel=8 ignore_loglevel` only needed while reading HDACTRLDBG prints
- `snd_hda_intel.enable_msi=0` required (MSI hangs through the bridge)
- `module_blacklist=snd_hda_intel` is currently ON (safe/bootable state);
  remove it to test the driver

## The single_cmd experiment (do this next)

Add to the cmdline (on top of the working baseline):
```
snd_hda_intel.enable_msi=0 snd_hda_intel.single_cmd=1
```
Remove `module_blacklist=snd_hda_intel`. Boot. Look for:
```
14:00.0: probe_codec after azx_get_response (err=0 res=0x????????)
```
- **Non-zero** (e.g. `0x1102xxxx`) → PIO works; the codec responds. Path to
  host audio opens up (then debug ALSA/PipeWire for actual sound).
- **`0x0` again** → bridge can't forward HDA verbs even via PIO. Confirm
  hardware-level limitation → set up VFIO passthrough to Windows (the card works
  there). Use `host/isolate-card.sh` + keep `snd_hda_intel` blacklisted.

## Reading a hang (decision tree)

| Last HDACTRLDBG line | Meaning |
|---|---|
| `azx_acquire_irq entry, msi=1` | MSI alloc hangs → ensure `enable_msi=0` |
| `clocksource: Watchdog ... timed out` | Concurrent-probe lockup → ensure mutex present |
| `probe_codec after azx_get_response (err=0 res=0x0)` | Bridge not forwarding CORB/RIRB → try `single_cmd=1` |
| `probe_codec after azx_get_response (err=0 res=0x????)` | Codec responds! → debug the codec driver (ca0132.c) |
| `ahci ... unavailable` / `xhci ... HC died` | Bus destabilized by AE-7 probing → the codec-query failure is the upstream cause |

## Safety rules

- **Do NOT boot without `snd_hda_intel.enable_msi=0`** if the driver is loading —
  MSI allocation hangs the host (not recoverable without power-cycle).
- **Do NOT remove the serialization mutex** if both AE-7 functions are present —
  concurrent probe causes a hard CPU lockup.
- Keep `module_blacklist=snd_hda_intel` as the safe default; only remove it for
  active testing.
- The AE-7's active probing can destabilize the PCIe bus and kill the AHCI
  controller (RAID root). If you hit emergency mode, that's why.

## Host quirk

This CachyOS box has a `grep` shell-function wrapper that rejects combined flags
(`grep -iE` → "conflicting matchers specified"). Use `/usr/bin/grep` everywhere.

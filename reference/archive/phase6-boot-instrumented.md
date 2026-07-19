# Phase 6 — boot the instrumented kernel to find the exact hang line

**Date:** 2026-07-16

## What we built

Patch `0002-hda-controller-debug-instrumentation.patch` adds `HDACTRLDBG:` prints
to every step of the HDA controller probe path:
- `sound/hda/controllers/intel.c` — `azx_probe_continue` (probe entry, before/after
  `display_power`, `azx_first_init`, `azx_probe_codecs`)
- `sound/hda/common/controller.c` — `probe_codec` (before cmd send, after send,
  after get_response), `azx_init_chip`, `azx_probe_codecs`
- `sound/hda/core/controller.c` — `snd_hdac_bus_reset_link` (every register read
  bracketed: GCTL read, enter/exit link reset, ready check, STATESTS codec_mask),
  `snd_hdac_bus_init_chip` (reset_link, int_clear, init_cmd_io, int_enable)

The **last `HDACTRLDBG:` line printed before the freeze** is the exact hang point.

## Why this is the definitive step

The param tests proved the hang is in the controller's register access through
the ASMedia bridge — but params can't tell us *which* register read/write wedges.
The instrumentation does. A `readl()` to MMIO behind a bridge that never returns a
completion will block the CPU indefinitely — no timeout, no fallback. The print
*before* that read will fire; the print *after* never will. That gap is the bug.

## How to boot the instrumented kernel

### Option A — replace the host kernel (fastest iteration)

The build produces `build/bzImage` (kernel release `7.1.3-dirty`). To boot it via
limine alongside the stock kernel:

```bash
# After build completes:
sudo cp build/bzImage /boot/vmlinuz-linux-ae7dbg
# The initramfs from build/initramfs.img matches this kernel — install it too:
sudo cp build/initramfs.img /boot/initramfs-linux-ae7dbg.img
sudo limine-update
```

Then boot with these cmdline params (REMOVE `module_blacklist=snd_hda_intel` so
the controller driver loads — we WANT it to run and hit our prints):
```
KERNEL_CMDLINE[default]+="quiet nowatchdog rw root=UUID=cf0cc394-37e9-4774-b6be-57e55351af52 amd_iommu=on iommu=pt loglevel=8 ignore_loglevel"
```

- `loglevel=8 ignore_loglevel` — ensures the HDACTRLDBG prints actually show
- NO `splash` (Plymouth fix stays)
- NO `module_blacklist=snd_hda_intel` — we need the driver to load and hang so we
  can see where

### Capturing the hang

The system will hang. You need the last lines on screen. Options:
1. **Photograph the screen** — the HDACTRLDBG prints go to the console; the last
   one before the freeze is the answer.
2. **If you have a serial header / USB-TTL adapter** on the motherboard, capture
   to another machine: add `console=ttyS0,115200n8` to cmdline.

### What to look for

The HDACTRLDBG sequence, in order:
```
HDACTRLDBG: azx_probe_continue start, before display_power
HDACTRLDBG: after display_power
HDACTRLDBG: azx_init_chip(full_reset=1)
HDACTRLDBG: bus_init_chip calling reset_link
HDACTRLDBG: reset_link reading GCTL          ← if freezes here, GCTL read wedges
HDACTRLDBG: reset_link after GCTL read
HDACTRLDBG: reset_link after enter_link_reset
HDACTRLDBG: reset_link after exit_link_reset
HDACTRLDBG: reset_link reading GCTL for ready check  ← if freezes here, GCTL ready check wedges
HDACTRLDBG: reset_link codec_mask=0x...      ← if freezes here, STATESTS read wedges
HDACTRLDBG: bus_init_chip after reset_link
HDACTRLDBG: bus_init_chip after init_cmd_io   ← if freezes here, CORB/RIRB setup wedges
HDACTRLDBG: bus_init_chip done
HDACTRLDBG: azx_init_chip bus_init_chip returned true
HDACTRLDBG: before azx_probe_codecs codec_mask=0x...
HDACTRLDBG: azx_probe_codecs max_slots=...
HDACTRLDBG: probe_codec(addr=0) cmd=0x...
HDACTRLDBG: probe_codec after azx_send_cmd   ← if freezes here, CORB write wedges
HDACTRLDBG: probe_codec after azx_get_response  ← if here, codec didn't reply
HDACTRLDBG: probe_codec FAIL addr=0
HDACTRLDBG: codec #0 probe error, resetting
HDACTRLDBG: after codec-error chip reset
```

The line where it stops = the exact faulting operation. Report it back.

## Decision tree after capturing the hang line

| Last HDACTRLDBG seen | Meaning | Next fix direction |
|---|---|---|
| `reset_link reading GCTL` | First MMIO read wedges | Bridge doesn't forward controller MMIO at all — BAR mapping issue |
| `reset_link reading GCTL for ready check` | Reset worked, but ready check wedges | Link reset confuses the bridge |
| `reset_link codec_mask=...` freezes AFTER | STATESTS read wedges | Codec detection read through bridge fails |
| `bus_init_chip after init_cmd_io` never prints | CORB/RIRB DMA buffer setup wedges | DMA through bridge to codec command buffer fails |
| `probe_codec after azx_send_cmd` | CORB write wedges | Command outbox write through bridge fails |
| `probe_codec after azx_get_response` with res=0xffffffff | Codec never replied | Bridge doesn't forward command to codec, or codec can't reply |
| `probe_codec FAIL` then loops forever | Reset-on-error loop | Each reset re-wedges the same way |

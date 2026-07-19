# Phase 5c — controller hang analysis from param tests

**Date:** 2026-07-16

## What the param results tell us

| Test | Param | Result | Interpretation |
|---|---|---|---|
| 1 | `enable_msi=0` | hang, no progress | MSI not the issue |
| 2 | `single_cmd=1` | screen refreshed once, then hang | got PAST the RIRB init, hung somewhere after |
| 3 | `polling_mode=1` | both screens showed console, then hang | **furthest progress** |
| 4 | `probe_only=1` | same as Test 3 | hung at same place as Test 3 |
| 5 | `power_save=0 bdl_pos_adj=0` | same as Test 2 | no improvement over baseline |

## Decoding this

The progression `enable_msi (nothing) < single_cmd (some) < polling (most)` is the
classic signature of an **interrupt-delivery problem through the PCIe-to-PCI
bridge**. Each param changes how the controller waits for things:

- `enable_msi=0` alone → still uses normal interrupt-based RIRB waits → hangs
  waiting for an interrupt that the ASMedia bridge never delivers
- `single_cmd=1` → bypasses RIRB, uses immediate IRS register polling → gets
  further (past CORB/RIRB init) but then hits another interrupt wait
- `polling_mode=1` → polls for everything → gets furthest → still eventually
  hangs at a register read or write that the bridge doesn't complete

The fact that `polling_mode=1` + `probe_only=1` hang at the same point means the
hang is **not in codec init verbs** (probe_only skips those) — it's in the
controller's own register access path, most likely:

1. `probe_codec()` → `azx_send_cmd()` + `azx_get_response()` → polls IRS
   register → the register read through the bridge never returns VALID
2. OR `azx_init_chip()` → `snd_hdac_bus_reset_link()` → the bus reset doesn't
   complete because the bridge doesn't forward the reset to the codec

## The key realization: combining params

You noted you removed previous params each time. But these params are
**complementary, not alternatives**. `polling_mode` + `single_cmd` together
address different layers. The combination that gets furthest is likely:

```
snd_hda_intel.enable_msi=0 snd_hda_intel.single_cmd=1 snd_hda_intel.polling_mode=1
```

But even that probably won't fully fix it, because the root issue is the bridge
not completing register transactions — and no snd_hda_intel param can fix a
hardware bridge that doesn't return reads.

## What this means for the path forward

We've squeezed all the diagnostic value out of module params. The hang is in the
controller's register access through the ASMedia bridge. The options now are:

1. **probe_mask** — force-skip the problematic codec slot. If `probe_mask=0x101`
   (force slot 0 only), the controller won't try to probe the slot that hangs.
   This is a diagnostic — it confirms whether a specific codec slot is the hang
   point. If it boots, we know which slot is wedged.

2. **Build the instrumented kernel** — add printk to `azx_probe_continue`,
   `probe_codec`, `snd_hdac_bus_init_chip`, and the reset/corb/rirb functions in
   `sound/hda/core/controller.c` and `sound/hda/common/controller.c`. One boot
   with these prints shows the exact hang line. This is the definitive next step.

3. **The hardware reality** — if the ASMedia bridge doesn't complete register
   transactions for the HDA controller, no software param can fix it. The only
   software-level fix would be a kernel patch that adds timeouts/retries to
   every register access through this bridge, OR the VFIO-to-Windows path.

## Recommended next test (one more param before building)

### Test 6 — combine the three that helped + force codec mask
```
snd_hda_intel.enable_msi=0 snd_hda_intel.single_cmd=1 snd_hda_intel.polling_mode=1 snd_hda_intel.probe_mask=0x101
```
`probe_mask=0x101` forces probing only codec slot 0 (the AZX_FORCE_CODEC_MASK
bit 0x100 + mask 0x01). If the AE-7's codec is on a different slot and probing
that slot is what hangs, this skips it.

If this boots → the hang is probing a non-existent/wedged codec slot, and
probe_mask is the permanent fix (or a quirk-table entry).

If this still hangs → the controller itself can't talk through the bridge at all.
Build the instrumented kernel.

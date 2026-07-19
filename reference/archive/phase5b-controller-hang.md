# Phase 5b — the HDA controller (snd_hda_intel) hangs

**Date:** 2026-07-16
**Finding:** blacklisting `snd_hda_codec_ca0132` but allowing `snd_hda_intel` →
hang. So the **controller driver itself** hangs during probe, before the codec is
ever loaded.

## What "controller hangs" means

The HDA controller driver (`snd_hda_intel`, source:
`sound/hda/controllers/intel.c` in v7.1) does this during probe:

```
azx_probe_continue()
  ├─ azx_first_init()        ← maps BARs, allocates IRQ, reads GCAP
  │   └─ azx_init_chip()     ← HDA bus reset + CORB/RIRB init   ← HANG LIKELY
  ├─ azx_probe_codecs()      ← sends commands to codecs via CORB/RIRB  ← OR HERE
  ├─ azx_codec_configure()
  └─ snd_card_register()
```

The CORB (command outbox) / RIRB (response inbox) is how the controller talks to
the codec. If the AE-7's ASMedia bridge doesn't forward these correctly, the
controller's response-wait loops spin → hang. The kernel has fallbacks
(polling mode, single_cmd mode) but they only kick in AFTER a timeout — and if
the register reads themselves wedge (behind the bridge), even the timeout never
fires.

## Module parameters to try (NO kernel build needed)

`snd_hda_intel` accepts params via the kernel cmdline as
`snd_hda_intel.<param>=<value>`. Try these one at a time. Each targets a
different hang point:

### Test 1 — disable MSI (common controller hang fix)
```
module_blacklist=snd_hda_codec_ca0132 snd_hda_intel.enable_msi=0
```
MSI delivery through a PCIe-to-PCI bridge is unreliable. If the controller is
waiting for an MSI interrupt that never arrives (because the bridge mis-routes
it), this fixes it. **Most likely to work.**

### Test 2 — force single_cmd mode (bypass RIRB)
```
module_blacklist=snd_hda_codec_ca0132 snd_hda_intel.single_cmd=1
```
Bypasses the RIRB (response inbox) entirely — uses immediate command/response.
Works around a wedged RIRB. (Note: this is automatically tried as a fallback
after timeout, but forcing it upfront avoids the timeout hang.)

### Test 3 — force polling mode
```
module_blacklist=snd_hda_codec_ca0132 snd_hda_intel.polling_mode=1
```
Polls register status instead of waiting for interrupts. Same logic as Test 1
but broader.

### Test 4 — probe only, don't configure (diagnostic)
```
module_blacklist=snd_hda_codec_ca0132 snd_hda_intel.probe_only=1
```
Probes codecs but skips configuration/init. If this boots, the hang is in the
codec *configuration* (init verbs), not probe. Diagnostic only — no sound.

### Test 5 — disable power management
```
module_blacklist=snd_hda_codec_ca0132 snd_hda_intel.power_save=0
```

### Test 6 — bdl_pos_adj (DMA position buffer)
```
module_blacklist=snd_hda_codec_ca0132 snd_hda_intel.bdl_pos_adj=0
```

## If none of the params work — build the instrumented kernel

Then we add AE7DBG-style prints to `azx_probe_continue`, `azx_first_init`,
`azx_init_chip`, and the CORB/RIRB functions in
`sound/hda/common/controller.c` to find the exact line. The patch would target
the controller source, not ca0132.c.

## Full limine cmdline template

For each test, the full line (replace `<PARAMS>`):
```
KERNEL_CMDLINE[default]+="quiet nowatchdog rw root=UUID=cf0cc394-37e9-4774-b6be-57e55351af52 amd_iommu=on iommu=pt loglevel=3 module_blacklist=snd_hda_codec_ca0132 <PARAMS>"
```

No `splash`, no `nomodeset` — keep the Plymouth fix.

## After a successful boot, capture

```bash
lspci -k -s 14:00.0
lsmod | grep snd_hda
dmesg | grep -iE 'snd_hda|hda-intel|ca0132|codec' | tail -30
cat /proc/asound/cards
```

# AE-7 outputs: jack map and output path (research, 2026-10-20)

Facts carry a source. Inferences are marked **[I]**. Anecdotes are marked **[A]**.

**Outcome on this card (tested 2026-10-20):** rear bracket from the right:
1 = Mic/Line in, 2 = Headphone/Headset out, 3 = Front out. All three work with the
upstream output and input paths (plus the write-flush fix). The GPIO 4/7, I2S-init
and relay changes listed below were not needed. The silence before was the
volume (`Master` scales the DAC amp and the DSP volume). Rear, Center/Sub and
optical were not tested.

## Jacks

- Card bracket: TOSLINK optical out, 3.5 mm Rear out, 3.5 mm Center/Sub out,
  3.5 mm Mic/Line in (default Mic), 3.5 mm Headphone/Headset out (default
  Headphone), 3.5 mm Front out ([Creative](https://us.creative.com/p/sound-cards/sound-blaster-ae-7)).
  Order and colours: no source found.
- ACM: 6.3 mm + 3.5 mm headphone, 6.3 mm + 3.5 mm mono mic, volume knob, mic
  array. It plugs into the card's Mic in and Headset out with two 3.5 mm plugs
  ([mmorpg review](https://www.mmorpg.com/hardware-reviews/creative-sound-blaster-ae-7-hi-res-dacamp-sound-card-review-2000108552)).
  So the ACM headphone jack carries the card headphone output **[I]**. Knob is a
  passive resistor **[A]** (reader comment on
  [thepcenthusiast](https://thepcenthusiast.com/creative-sound-blaster-ae-7-pcie-sound-card-review/)).
- Codec pins (upstream `ae7_pincfgs`, `out_pins`): 0x0b Front line out,
  0x0f Rear, 0x10 Center/LFE, 0x11 headphone (Windows pincfg says Line In, so
  the jack shows as "Line Jack"), 0x12 mic/line in, 0x0c/0x0d S/PDIF out.

## Output hardware

- ESS SABRE-class 9018 DAC, "Dynamic Range (Stereo)" (Creative). It is on ca0113
  serial group 0x48. Rear and Center/Sub come from CA0132 DACs **[I]**.
- Relay: serial group 0x30 reg 0x30 = 0x00 speakers, 0x3f headphones (Kira
  Backes, [bug 221614 att. 310852](https://bugzilla.kernel.org/attachment.cgi?id=310852)).
- Creative INF, AE-7 = AE-5 values ([verzic](https://github.com/verzic/sb-ae9/blob/HEAD/docs/INVESTIGATION.md)):
  `HPAMP_SHDNPin 0x02010004` = ca0113 GPIO 4, output, inverted;
  `Front_MutePin 0x00010007` = ca0113 GPIO 7; AntiPop 0, DAC 192k sel 1,
  DAC reset 5 (decode in verzic `ctxhda-acm-analysis.md` 10.7).
- BAR2 GPIO block: 0x100 low nibble = pin 4-7 function select (clear = GPIO),
  0x304 direction (set = out), 0x300 level (read), 0x320 = pin | level<<8.

## What upstream does not do on AE-7 (Kira's working driver does)

1. Never drives ca0113 GPIO 4 or 7. Kira: GPIO7 high, then GPIO4 high
   (`0x320=0x0107`, `0x320=0x0104`) after the DAC setup; verify 0x300 bits 4,7.
   SBZ precedent in upstream: HP mode pins 7=1, 4=1.
2. `ca0132_mmio_init()` has no `case QUIRK_AE7`, so the AE-7 branches in
   `ca0132_mmio_init_ae5()` (commit 4e356d56) never run: no HDis (0x400-0x4fc,
   0x100, 0x410, 0x40c), no 0x830, no 0x1c=0x00880680. Kira runs the same writes
   (with gate polls on 0x89c) before HDA init.
3. Kira skips 0x30:0x32 (absent from the Windows AE-7 path), stream 0x21 /
   NID 0x09 n2sid, and chipIO 0x18b038=0x88. She clears 0x18b008 bit 3 before
   each stream start and masks 0x18b03c with 0x7f.
4. Kira uses the DSP image from `CtxHda.sys` (655,436 B, sha256 90ba1de2...).

## Linux reports

- AffSeda: flush patch + stock `ctefx.bin` gives audio "through the line-out".
- targz (bug 217510, ASMedia card, stock driver): audio works; relay clicks
  4-5 times at boot; headphones "should be in Speakers position" **[A]**.
  His working mixer (2023 alsa-info): Master 98, PCM 255, Front/Surround/
  Center/LFE 90 on, Output Select Headphone, auto detect off, DAC 0x02
  Amp-Out 0x59 (not muted).
- Arch FS#72568: headphones work after a switch, then go silent after a few
  seconds unless a sound settings window is open **[A]**.
- Upstream author never had an AE-7 ([lkml](https://lkml.rescloud.iu.edu/hypermail/linux/kernel/2012.1/03709.html),
  [bug 209281](https://bugzilla.kernel.org/show_bug.cgi?id=209281)).

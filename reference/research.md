# AE-7 / ASM1083 research report

Date: 2026-10-20. Scope: external evidence (bugzilla, mailing lists, forums,
out-of-tree drivers, vendor docs) for the AE-7 (CA0132 `1102:0010` ss `1102:0081`
behind ASMedia ASM1083/1085 `1b21:1080` rev 03) on the MSI MAG X670E Tomahawk WiFi.
Bugzilla was read through its REST API (the HTML front end is behind an Anubis
bot wall). Reddit is blocked for our fetcher, so Reddit threads are cited only
where other sources quote them.

## 1. TL;DR (ranked by actionability for the VFIO-guest-kernel plan)

1. **The failure is understood and reproduced by three independent out-of-tree
   efforts in 2026.** The ASM1083/1085 rev 03 bridge (or the CA0132 PCI target
   behind it) wedges after a burst of about 14-18 back-to-back *posted* MMIO
   writes with no intervening read. The stock driver issues exactly that burst
   once, in `snd_hdac_bus_init_chip()` -> `azx_int_clear()` + `snd_hdac_bus_init_cmd_io()`
   (13 + 5 writes), before the first read (the CORBRP poll). After the wedge every
   MMIO read of the card *and config reads of the bridge* return all-ones after a
   ~220 ms completion timeout until the link is reset; the 1000-iteration CORBRP
   poll under `spin_lock_irq` then takes ~220 s, and sibling devices on the same
   chipset switch (xHCI, AHCI, EC) die. Inserting a single read-back between the
   writes makes the card probe, load the DSP and play audio. Sources:
   AffSeda (AE-7, Threadripper X399, Debian 7.2.6, bisected with a replay module,
   rows 10/11 differ only by the flushing reads) [AffSeda ANALYSIS](https://github.com/AffSeda/Creative_AE7_Linux/blob/HEAD/ANALYSIS.md);
   verzic (AE-9, same bridge, AMD 600-series chipset switch, "Reproduced 5x,
   cured 1x, with every other variable held") [verzic INVESTIGATION](https://github.com/verzic/sb-ae9/blob/HEAD/docs/INVESTIGATION.md);
   Kira Backes (AE-7, Fedora 7.2.5, bounded "checked" init that reads back and
   rejects all-ones) [bug 221614 att. 310852](https://bugzilla.kernel.org/attachment.cgi?id=310852).
   **This matches our symptoms exactly** (reset/STATESTS reads succeed because
   they precede the burst; `res=0x0`; "~220 s"; xHCI/AHCI death; works in Windows).
2. **`single_cmd=1` will not help.** The burst happens in `init_chip` before any
   verb is sent; AffSeda tested `single_cmd=1 enable_msi=0` against the stock
   driver and it hung (ANALYSIS table row 3). Replace that experiment with the
   flush patch.
3. **The fix is a guest/host *kernel module* change, not a cmdline/BIOS knob.**
   Minimal form (verzic `0001`, 9 lines): read `INTSTS` at the end of
   `azx_int_clear()`, read `GCTL` at the end of `snd_hdac_bus_init_cmd_io()`
   (both `sound/hda/core/controller.c`), plus read-backs in `sound/hda/core/stream.c`
   [patch](https://github.com/verzic/sb-ae9/blob/HEAD/patches/0001-ALSA-hda-flush-posted-writes-in-azx_int_clear.patch).
   Blanket form (AffSeda): read-back inside `snd_hdac_reg_write{b,w,l}` in
   `include/sound/hdaudio.h` + a GCAP read after each of the 45 BAR2 writes in
   `ca0132.c` [patch](https://github.com/AffSeda/Creative_AE7_Linux/blob/HEAD/patches/workaround-flush-every-hda-write.patch).
   Nobody has sent either upstream (no lore/linux-sound hits as of 2026-10-20);
   AffSeda explicitly declined to submit AI-written code (bug 217510 c70).
4. **A VFIO Linux guest does not protect the host from the wedge.** With the BARs
   mmap'ed, the guest's stock driver issues the same burst and the *hardware*
   wedges, taking the host's chipset siblings (our RAID AHCI) with it. verzic:
   "a VFIO VM would only protect the host from the stock driver's lockup ... The
   real cost is the hardware wedge: card and ASM1083 answer 0xFF until reset"
   (INVESTIGATION, 17:25). Only `x-no-mmap=on` (every access trapped) sidesteps
   it, which is how the Windows-driver MMIO captures were made. Conclusion: test
   the flush patch on the host (module rebuild, card parked on `pci-stub` and
   bound at runtime), or in a guest *with the patched module*.
5. **Reboot-free recovery exists.** verzic's `ae9recover.ko`: remove the dead
   bridge+card, secondary-bus-reset the chipset downstream port, pulse the
   bridge's own secondary reset, rescan (INVESTIGATION 17:25/17:35). Worth
   porting for iteration on this box (not published as a file in the repo tree
   listing we fetched; described in the log).
6. **Card revision is the discriminator, not the platform.** Release-era AE-7s
   use an IDT/Tundra Tsi381 bridge and work on Linux since 5.10; 2022+ batches use
   the ASM1085 and fail on every board reported (Intel Z690/Z790/Z370-class, AMD
   990FX, X399, X570, B650E, X670E, X870/X870E). Same for AE-9 (`10e3:8111` Tsi381
   vs `1b21:1080`). Sources: bug 217510 c20 (photos vs 2019 review), bug 219552
   c59, linux-sound 2026-04 post, EndeavourOS p5.
7. **Slot/BIOS changes will not cure the wedge but can limit collateral.** The
   Tomahawk's PCI_E1 (Gen5 x16) and PCI_E3 (Gen4 x4) are CPU-attached; PCI_E2
   (Gen3 x1) and PCI_E4 (Gen4 x2, shares with M2_4) hang off the X670 chipset
   (MSI manual). Our bridge at bus 0x13 is in the chipset bus range; moving the
   card to PCI_E3 removes the Promontory switches (and the RAID AHCI) from the
   blast radius. `iommu=pt` must stay (verzic/Kira: the controller prefetches past
   the end of the PCM ring -> `AMD-Vi IO_PAGE_FAULT` with a translating IOMMU).
8. **Two things in our own notes deserve a re-check:** (a) the CA0132 has no MSI
   capability at all (only a PM cap at 0x50 per AffSeda's `lspci -vvv`), so
   `pci_alloc_irq_vectors(PCI_IRQ_MSI)` should fail fast rather than hang; the
   "MSI hang" was more likely the bridge wedge from the concurrent probe.
   (b) No other AE-7 report shows a `.1` function; our `14:00.1` may be a phantom
   function of the same conventional-PCI device (compare `lspci -xxx -s 14:00.0`
   and `14:00.1`). If so, the "concurrent probe lockup" was two probes bursting
   the same hardware.

## 2. Findings per question

### Q1. Kernel bugzilla entries and mailing-list threads

**Bug 217510** "Creative AE-7 working only from Live Distributions"
[link](https://bugzilla.kernel.org/show_bug.cgi?id=217510). Filed 2023-05-30 by
Evgenii (targz), status NEW, 74 comments, last 2026-10-09, no maintainer comment
(Takashi Iwai never posted; bjorn.bidar c41: "I suspect we won't get much help
asking here. The original author suggested to pass the card through to a Windows
VM"). Reporter: MSI Pro Z790-A, Intel iGPU; boots are probabilistic (title is
misleading; c5/c23/c45 attribute boot success to RAM timing, distro, kernel 6.1 vs
6.5, all anecdotal). Reports in the thread, all ASM1083/1085 rev 03 + CA0132 rev 01:
- c6/c14 Pascal Pharand: MSI MEG X670E ACE + 7950X, also reproduced on an X99
  Rampage V Extreme; "nothing meaningful is being logged ... just reboot".
  Workaround `options snd_hda_intel enable=1,0,1` (c30).
- c11: "CORB reset timeout#2, CORBRP = 65535 / no AFG or MFG node found / no
  codecs initialized" (same signature as ours).
- c17/c20 someguy108: MSI Z790 Edge + 13900K; AE-5 and AE-5 Plus work; tore the
  AE-7 down and found the IDT chip replaced by an ASM1085
  ([photos](https://i.imgur.com/zFjvGIs.jpg), [2019 review for comparison](https://thepcenthusiast.com/creative-sound-blaster-ae-7-pcie-sound-card-review/)).
- c26 Stefan: Gigabyte B650E Aorus Master + 7800X3D (our CPU), `08:00.0 ASM1083/1085
  (rev 03) ... IRQ 255`, hard+soft lockups on every distro.
- c29: Gigabyte X570 Aorus Pro + 5900X. c32: ASUS Prime X670E-Pro + 7950X (AE-9,
  ASM1085). c39: ASUS Prime X670E-Pro + AE-7, openSUSE 15.6.
- c25 gexpower: AE-7 worked on Z590/11900KF with kernels 6.1-6.6, broke after
  moving to Z790/14900KF (same card) - the only "worked then broke" report; the
  card's bridge revision is not stated.
- c44/c52 (Oct 2025): new card bought Oct 2025 still fails everywhere.
- c63-c68 (Sep 2026): cross-reference to bug 221614 and AffSeda's repo; c70/c73:
  AffSeda's patch gives working sound on Debian; targz reports kernel 7.2.9 on
  openSUSE boots with the card without patches (his boots were always
  probabilistic, treat as anecdotal).
- Attachment 304358 (alsamixer screenshot); 310867 is an HTML e-mail dump.

**Bug 221614** "snd_hda_intel: soft lockup in snd_hdac_bus_init_cmd_io with
Creative AE-7 behind ASMedia ASM1083 PCI bridge"
[link](https://bugzilla.kernel.org/show_bug.cgi?id=221614). Filed 2026-06-04 by
moskrc: MSI PRO X870-P WiFi, 9950X, Fedora 7.0.10; bridge `0d:00.0`, card
`0e:00.0`, IOMMU group 20. Attached log (att. 310262) shows: `Disabling MSI`,
`Force to non-snoop mode`, then `soft lockup CPU#0 ... smp_call_function_many_cond`
(the `set_memory_uc` IPI from non-snoop mode), `hard LOCKUP on cpu 18` with
`RIP: snd_hdac_bus_init_cmd_io+0x1fe` in `azx_probe_work`. The regressions bot
asked for maintainer/mailing-list reporting; no maintainer reply. c2: MSI MEG
X570 Unify + 5800X3D, "4.x, 5.x, 6.x, 7.2.x ... same results". c4 (2026-09-15)
Kira Backes attached a working replacement driver (`snd_hda_ae7` +
`snd_hda_codec_ca0132_ae7`, v0.1.1, Fedora 7.2.5) with `MAINTAINER-NOTES.md`:
"A prototype that called stock shared HDA initialization froze in the CORBRP
reset-clear path with reads of 0xffff"; her `checked_init.c` keeps stock widths
and order but reads back after each stage, rejects all-ones, and bounds the CORBRP
poll to 1000 reads / 1 ms. Also: Windows-derived "HDis/HdIc interface-mode-0"
BAR2 sequences, masked writes to BAR2 `+0x1c`, relay control (serial group 0x30
reg 0x30: 0x00 speakers / 0x3f headphones; GPIO7 front mute; GPIO4 inverted HP-amp
shutdown), DSP image extracted from `CtxHda.sys` (655,436 B, sha256 `90ba1de2...`,
identical to verzic's extraction), and a PCM-ring fault "exactly at the exclusive
ring end" cured by a persistent 1 MiB coherent allocation. "Most initialization
writes were tested together. Their individual necessity is unproved."

**Bug 219552** "CA0132 Creative Soundblaster AE-9 no sound at all [1102:0010]"
[link](https://bugzilla.kernel.org/show_bug.cgi?id=219552). Filed 2024-12-03
(Starfoxfs, Intel H370, Tsi381-bridge AE-9, no lockup, just no sound). Takashi
Iwai: c1 (enable CA0132, use latest kernel), c6 (one-liner `SND_PCI_QUIRK(0x1102,
0x0071, "Sound Blaster AE-9", QUIRK_AE7)`), c9. c21-c23: AE-9 has two codecs
(`1102:0011` ss 0071 "AE-9" and ss 0072 "AE-9s"), correct AE-9 pincfgs, probe of
codec 2 fails `-16`. c28-c31: Connor McAdams' unfinished AE-9 patches + e-mail
dump (from [SteamOS issue 1763](https://github.com/ValveSoftware/SteamOS/issues/1763));
McAdams: "You'd need to capture the correct commands/GPIO settings from watching
the Windows driver ... more work than I have time for". c50 (2026-02-25,
s3boun3t): captured the Windows driver's MMIO with QEMU VFIO tracing
(`x-no-mmap=on`, `vfio_region_write/read`), 2.2M lines (att. 309459-309461).
c52-c55 (jdsangster24, 2026-06): custom `snd-hda-codec-creative-ae9` that bypasses
`snd_hda_intel` (`enable=0,1`); CORB/RIRB, I2C to the ACM, DSP load all work, DSP
output pipeline stays silent. c53: "there exists two versions of this card. More
exactly the pcie bridge", IRQ storms with the normal HDA path. c56 (2026-07-16,
Kaiba): AE-9 on **MSI MPG X870E Carbon WiFi + 9800X3D, kernel 7.1.3 CachyOS**:
"azx_probe_work stalls, kernel stack trace in snd_hdac_bus_init_cmd_io; CORB reset
timeout#2, CORBRP = 65535; no codecs initialized; boot takes ~4.5 minutes;
workaround `pci-stub.ids=1102:0010`". **c57 Takashi Iwai (2026-07-16): "This is
a different issue, and likely a bug in the PCI core side"**, asked to test
removing `pci_pm_power_up_and_verify_state(dev)` from `pci_pm_init()`; c61: no
effect on vanilla 7.1.3. c59: "The AE-7 also has 2 versions with the same pcie to
pci bridge chips as i also own a AE-7 with the IDT bridge".

**Bug 218344** "Sound Blaster AE-9 make linux boot freeze"
[link](https://bugzilla.kernel.org/show_bug.cgi?id=218344) (2024-01-04, Paul
Dufresne, Fedora 39, AE-9 ss 0071, `snd_hda_intel.enable=N,N,Y` -> `Disabling
MSI / Force to non-snoop mode` then freeze). One comment, NEW. Originally posted
to linux-sound:
[lore thread](https://lore.kernel.org/linux-sound/18cd5be2bc7.e19fbd7b17331.5233193232348276602@zoho.com/T/#u).

**Other threads**
- linux-sound + linux-pci, 2026-04-07, Andrii: "Creative SoundBlaster AE-7/AE-9
  fails to boot if contains ASMedia ASM1083/85 chip"
  [archive](https://ratatoskr.run/linux-sound/2026/04/11364619). Working AE-9:
  `Tundra Tsi381 [10e3:8111] rev 02`; failing: `[1b21:1080]`. Fails before 6.18
  and on 6.18.18 with Bjorn Helgaas' ASPM-quirk rework
  (`30579eebba6a` "PCI/ASPM: Convert quirks to override advertised link states",
  Nov 2025, makes the ASM1083 L0s/L1 quirk a HEADER quirk). Log shows the quirk
  applied ("ASPM: Link Capabilities L0s L1 treated as unsupported to avoid device
  defect") and the boot still fails. No reply.
- linux-sound 2026-06, Kai: AE-9PE ACM dark, codec 2 probe `-16`, ASUS Z790
  [archive](https://ratatoskr.run/linux-sound/2026/06/17098469/t). No reply.
- Debian #1115581 (AffSeda, 2025-09) [link](https://bugs.debian.org/1115581):
  Uwe Kleine-Koenig forwarded to 217510 and CC'd Connor McAdams (2025-10-22); the
  2026-09-27 "Further Development" mail announces the GitHub workaround.
- Stable backport dispute 2020: Takashi Iwai asked Greg KH to drop the AE-7
  quirk-ID patches from 5.9-stable: "AE-7 won't work without the full backport"
  [LKML](https://lkml.iu.edu/hypermail/linux/kernel/2010.3/09705.html).
- Original AE-7 series (Connor McAdams, Aug 2020, "another user has confirmed
  that they work on the AE-7") [cover letter](https://lkml.iu.edu/hypermail/linux/kernel/2008.3/03249.html);
  Phoronix [announcement](https://www.phoronix.com/news/SoundBlaster-AE-7-Linux).

### Q2. Does the AE-7 work on Linux for others; regressions; AM5; revisions

- Works: IDT/Tsi381-bridge AE-7 (release batches, 2019-2021) on Linux 5.10+
  (bug 217510 c20/c25, bug 219552 c59, EndeavourOS p5 "worked on an Asus Dark
  Hero for about two years"). Manjaro 5.13.8 on an ASUS X570-class board probed
  the AE-7 and loaded the DSP but output was intermittent
  [computerbase](https://www.computerbase.de/forum/threads/manjaro-creative-ae7-kein-sound.2037062/).
- Fails: every ASM1083/1085 rev 03 report regardless of platform: Intel Z790
  (Pro Z790-A, Z790 Edge, MEG Z790), X99, Z370-class H270; AMD 990FX, X399,
  X570 (Aorus Pro, MEG Unify), B650E (Aorus Master, Taichi Lite
  [Mint thread](https://forums.linuxmint.com/viewtopic.php?t=432162): 7950X3D,
  "boot takes about 5 minutes", second monitor dead), X670E (MEG ACE, Prime
  X670E-Pro, ProArt X670E Creator), X870/X870E (PRO X870-P, MPG X870E Carbon).
  Kernels 4.x through 7.2.x (bug 221614 c2). Fedora 42 thread concludes "AE-7 is
  incompatible on linux"
  [link](https://discussion.fedoraproject.org/t/sound-blaster-ae-7-build-42-fedora-kde-plasma-desktop/169201).
- The EndeavourOS thread (ASUS ProArt X670E -> MSI MEG X670E ACE, 7950X, 2023)
  tried kernels 5.10-6.4rc1, `pci=noacpi`, `amd_iommu=off iommu=soft`, `acpi=force`,
  slot Gen1, BIOS reset/beta, xHCI handoff, blacklist; only
  `options snd_hda_intel enable=1,0,1` boots
  [p1](https://forum.endeavouros.com/t/unable-to-boot-after-installing-new-sound-card-ae-7/40457)
  [p5](https://forum.endeavouros.com/t/unable-to-boot-after-installing-new-sound-card-ae-7/40457?page=5).
- Regression by kernel version: none identifiable. The `ca0132.c` history since
  2020 is cleanups/quirk additions only (`7c005292e20a` 2024-12 quirk-helper
  conversion, `6cce08122f70` 2025-07 new probe method, `6014e9021b28` move to
  `sound/hda/codecs/`). Anecdotes of "6.1.29 boots, 6.1.30 does not" (217510 c5)
  come from a reporter whose boots were probabilistic.
- AM5 specifics: none beyond the collateral pattern. One Level1Techs poster: on
  X670(E)/X870E "issues pop up ... only on the stuff connected to the second
  daisy-chained chipset" (grouping/reset context, not this card)
  [L1T](https://forum.level1techs.com/t/am5-iommu-vfio-best-motherboard/189720?page=4).
  The ALSA driver denylisted the **X870E** Tomahawk by DMI ID in 2026-03 because
  its onboard audio is USB and `snd_hda_intel` logged "no codecs found" - unrelated
  to our board/card (`696b0a9bd2e4`, revert `ed4da361bf94`, bug 221274).
- Card revisions: orlfman (EndeavourOS p5) and someguy108 (217510 c20) date the
  ASM1085 batch to 2022; Creative never documented it. Our card: rev 03 bridge,
  matching all failing reports; AffSeda notes rev 01/02 bridges are untested.

### Q3. ASMedia ASM1083/1085 known problems and in-tree quirks

In-tree (verified in current `drivers/pci/quirks.c` / `probe.c`):
- `quirk_disable_aspm_l0s_l1` HEADER fixup for `1b21:1080`: AER "Timeout" floods
  and failed suspend with ASPM, bug 208667 (Robert Hancock, 5.9,
  `b361663c5a40`); ASMedia's page says "No PCIe ASPM support"; Windows logs the
  same WHEA errors
  [bug](https://bugzilla.kernel.org/show_bug.cgi?id=208667)
  [LKML](https://lkml.iu.edu/hypermail/linux/kernel/2007.2/09173.html).
- `quirk_use_pcie_bridge_dma_alias` for `1b21:1080` (bug 44881 c46): the bridge
  omits/hides its PCIe capability so the wrong DMA alias was used for devices
  behind it (IOMMU faults with DVB cards; Alex Williamson's fix, 3.17)
  [commit](https://git.kernel.org/linus/ebdb51eb7806df56221d4536a6a9702751d6df85)
  [bug](https://bugzilla.kernel.org/show_bug.cgi?id=44881).
- `pci_ext_cfg_is_aliased()` comment: "ASM1083/1085 PCIe-to-PCI Reversible Bridge
  (1b21:1080, rev 01 & 03)" alias extended config space onto 0x000-0x0ff; Linux
  treats them as 256-byte config
  [probe.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/pci/probe.c).
- No in-tree quirk for the INTx/posted-write problems. The 2012 "ASM1083
  PCIx-PCI bridge interrupts - widespread problems" thread (Chris Palmer, Robert
  Hancock: "the bridge chip is delaying PCIe INTx deassert messages ... can't fix
  without input from ASMedia") and the AMD E-450 "Unhandled IRQs" thread led to
  Jeroen Van den Keybus' `poll_spurious_irqs()` polling hack, carried by Fedora
  as `unhandled-irqs-switch-to-polling.patch` and later dropped
  [LKML 2012](https://lkml.iu.edu/hypermail/linux/kernel/1201.3/03042.html)
  [AMD E-450](https://lkml.iu.edu/hypermail/linux/kernel/1204.3/02015.html)
  [Fedora patch](https://git.stg.centos.org/rpms/kernel/blob/5bbe9ea49d6d1c9184054e1d23f3cb18213c1bcc/f/unhandled-irqs-switch-to-polling.patch)
  [drop](https://git.almalinux.org/rpms/kernel/commit/e5a9699c021ebf300b633f430af2b0fa33dd0fe1).
- AMD-Vi: an ASM1083 + MegaRAID on X370 threw `IO_PAGE_FAULT` with the IOMMU in
  translated mode (Arch, 5.17; no resolution captured)
  [thread](https://bbs.archlinux.org/viewtopic.php?id=275425). ASMedia does not
  answer technical mail (SteamOS issue, bug 217510 c34).
- Revision differences: the Osmocom "PCIe->PCI bridges" wiki reportedly says
  rev 04+ with ASPM disabled worked for their (network) cards and that
  ASM1083/1085 flood "PME: Spurious native interrupt!"; the page itself is behind
  Anubis and could not be fetched, so this is from a search snippet only
  [page](https://osmocom.org/projects/retronetworking/wiki/PCIe-%3EPCI_bridges).
- Posted-write burst wedge (the one that matters here): not in any vendor
  erratum we could find; evidence is the three 2026 investigations in section 1.
  AffSeda measured: card DMA, INTx, write-combining buffers, IOMMU on/off, MSI
  vs INTx were each excluded; "`pcie_aspm=off` is in effect, so ASPM is not the
  mechanism". verzic: stock `azx_int_clear`(13 writes) + `init_cmd_io`(5 writes)
  fails; the same 18 writes with one `readl(GCTL)` after the 13th pass; a 37-entry
  BAR2 `writel` loop in `ca0132_mmio_init_ae5()` is "well past the 14..18
  threshold" so BAR2 writes must be flushed too (INVESTIGATION 17:40). Windows'
  driver "follows every MMIO write with a read of the same register" is verzic's
  inference (MSVC volatile + fence), not a measured fact; the Windows VFIO
  capture did show "one verb at a time (CORBWP write + RIRBSTS poll per verb)".

### Q4. CA0132 controller specifics in Linux and other OSes

- Linux matches `1102:0010` as `AZX_DRIVER_CTHDA` with
  `AZX_DCAPS_PRESET_CTHDA` (NO_MSI | POSFIX_LPIB | NO_64BIT | 4K_BDLE_BOUNDARY |
  SNOOP_OFF). AffSeda: `GCAP=0x6401` (6 out/4 in streams, 64OK set but masked
  by NO_64BIT). The device exposes only a PM capability (no MSI cap, D2 only,
  no D3hot) per `lspci -vvv` in
  [evidence/00-hardware.txt](https://github.com/AffSeda/Creative_AE7_Linux/blob/HEAD/evidence/00-hardware.txt).
  `azx_init_pci()`'s TCSEL clear is a no-op on this card (verzic: cfg[0x44]
  0x00 -> 0x00; cfg[0x40] already 0x0080).
- Codec address: all CA0132 desktop cards sit on SDI 1 (`STATESTS=0x0002`;
  AE-9 `0x0006` = addresses 1 and 2). It is the card's wiring, not the bridge
  (AffSeda S1/S3, bug 219552 c54, AE-9PE thread). Codec vendor ID answered by
  hand-driven CORB/RIRB on the AE-7: `0x11020011`.
- Required controller init before the codec responds: nothing beyond the
  standard HDA sequence - the hand bring-up in AffSeda's `ae7probe` (reset,
  CORB/RIRB DMA, GET_PARAMETER, UNSOL, INTCTL, real INTx handler) works when
  each write is followed by a read
  [evidence/04](https://github.com/AffSeda/Creative_AE7_Linux/blob/HEAD/evidence/04-hand-bringup-works.txt).
  Kira Backes adds Windows-derived BAR2 "interface mode 0 / transport mode 1"
  sequences for the external DAC/relay, needed for *audio routing*, not for
  codec enumeration.
- `single_cmd` (IC/IR/IRS immediate command): kernel docs call it a debugging
  last resort for BIOS use; a Qubes user got a codec detected with it but no
  sound [HD-Audio notes](https://www.kernel.org/doc/html/latest/sound/hd-audio/notes.html)
  [Qubes](https://groups.google.com/g/qubes-users/c/79Xu02alass/m/PHmBoIE6BgAJ).
  Nobody has shown it working on CA0132; AffSeda showed it does not avoid the
  wedge (the burst precedes it).
- BAR2: CA0113 MMIO window (GPIO at +0x320, command engine +0x20c/+0x204/+0x804,
  UART to the AE-9 ACM at +0xc00). Upstream `ca0132_mmio_init()` dispatches only
  R3D/SBZ/ZXR and AE5; `QUIRK_AE7` falls to `default` (no table write at
  mmio_init), but the AE-7 paths (`ae7_setup_defaults`, `ae5_register_set`,
  `ca0113_mmio_command_set*`) still do short BAR2 bursts (8x `+0x304`, 2x
  `+0x1c`), which AffSeda flushed individually
  [ca0132.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/sound/hda/codecs/ca0132.c).
- FreeBSD `hdac.c`: `1102:0012` ("Creative SB Audigy FX", AE-5 controller ID)
  gets `HDAC_QUIRK_64BIT`; `1102:0010` falls to the generic "Creative" entry;
  codec `1102:0011` is listed as CA0132. The 217510 reporter says FreeBSD hangs
  with the AE-7 too (c5, anecdotal)
  [hdac.c](https://cgit.freebsd.org/src/tree/sys/dev/sound/pci/hda/hdac.c)
  [hdac.h](https://cgit.freebsd.org/src/tree/sys/dev/sound/pci/hda/hdac.h).
- Haiku: ticket 16921 (AE-5) is a placeholder, no driver work
  [ticket](https://dev.haiku-os.org/ticket/16921). macOS: only old AppleHDA/
  VoodooHDA CA0132 patches for onboard Core3D; nothing for AE-5/AE-7 controller
  init [InsanelyMac](https://www.insanelymac.com/forum/topic/309283-creative-ca0132-g1sniper-m3-patch-for-applehda-or-voodoohda/).
- Windows: `CtxHdb.sys` is an HDA-bus lower filter ("Sound Blaster Audio
  Controller", matches `PCI\VEN_1102&DEV_0010`) that pre-initialises BAR2 before
  the class driver; `CtxHda.sys` is the codec driver and embeds the DSP image.
  verzic's `ctxhdb-analysis.md` / `windows-vs-linux-init.md` document the
  sequences (AE-9). Windows uses the Microsoft generic HDA driver for the AE-9's
  second codec.

### Q5. VFIO passthrough of Creative cards

- Reset: the CA0132 has no FLR and no D3hot (PM reset impossible); vfio-pci can
  only do a secondary bus reset through the ASM1083 (the card is alone on that
  bus, so `pci_reset_bus` on the bridge is allowed when the whole group is user
  owned). libvirt refuses to assign or reset `pci-bridge` devices and VFIO
  handles bridges automatically; do not bind the ASM1083 to vfio-pci
  [libvirt](https://lists.libvirt.org/archives/list/devel@lists.libvirt.org/thread/MFGEQWHX4J4NY5T7ZLNQJGKEM754GTFJ)
  [Proxmox](https://forum.proxmox.com/threads/cant-passgtrough-pcie-to-pci-brigde-of-sound-card.93582/).
- Success reports: AE-9 (ASM1083) passed to a Windows 11 guest on an AMD
  600-series host (whole IOMMU group incl. NIC/Wi-Fi/xHCI/SATA, no ACS override)
  runs Creative's driver well enough to capture its full init - QEMU
  `-device vfio-pci,host=...,x-no-mmap=on -trace enable=vfio_region_*`, plus a
  139-line QEMU patch mirroring CORB verbs/RIRB responses into the trace
  (verzic INVESTIGATION 20:05-21:05; s3boun3t bug 219552 c50). Caveat: after a
  VFIO/Windows session the card stays wedged for a host driver until a reboot
  (verzic 22:24). "VFIO passthrough keeps working with iommu=pt" (verzic README).
- Problems: AE-5 to Windows 10: works on first boot, after a VM restart volume is
  stuck at max (reset problem; suggested unbind/rebind hook, unresolved)
  [L1T](https://forum.level1techs.com/t/sound-blaster-ae-5-reset-bug-sound-card-passthrough/167025).
  X-Fi Titanium HD (EMU20k2): works in an Ubuntu guest, Windows 7/10/11 guests
  detect it but no audio and broken playback clocks; poster gave up
  [L1T](https://forum.level1techs.com/t/unsolved-sound-card-passthrough-doesnt-work-properly-inside-windows-vm/235718).
  AE-9 in QEMU: "i cant get any output from the pci in qemu either" (219552 c36).
  ESI Maya44 behind a TI XIO2001 bridge: Windows guest no audio (Proxmox above).
- Our plan: the flush fix is required inside any Linux guest too (item 4 of the
  TL;DR); ACS override on the Tomahawk was used by a Proxmox user
  (`pcie_acs_override=downstream,multifunction`, groups then one device each)
  [Proxmox](https://forum.proxmox.com/threads/proxmox-vm-setup-issue-usb-crashes-and-gpu-output-failure-on-pci-ports.146947/).

### Q6. MSI MAG X670E Tomahawk WiFi slots, BIOS, IOMMU

- Slots (MSI manual, "PCI_E1~4: PCIe Expansion Slots", p.29 of the 252-page PDF
  [download.msi.com](https://download.msi.com/archive/mnu_exe/mb/MAGX670ETOMAHAWKWIFI.pdf),
  also [manualslib](https://www.manualslib.com/manual/3270652/Msi-Mag-X670e-Tomahawk-Wifi.html)):
  PCI_E1 = PCIe 5.0 x16 from CPU; PCI_E2 = PCIe 3.0 x1 from X670 chipset;
  PCI_E3 = PCIe 4.0 x4 from CPU; PCI_E4 = PCIe 4.0 x2 from X670 chipset, shares
  bandwidth with M2_4 (M2_4 drops to x2 when PCI_E4 is populated). Physical
  order top to bottom: PCI_E1, PCI_E2, PCI_E3, PCI_E4.
- Which chipset: the manual does not say which of the two Promontory 21 dies
  serves PCI_E2/PCI_E4. A Tomahawk IOMMU dump (with ACS override) shows two
  chipset trees (`03:00.0/04:0x.0` and `0a:00.0/0b:0x.0`) with chipset endpoints
  on buses 0x06-0x16 and CPU devices at 01-02 and 17-18; our bridge at 0x13 next
  to USB `13:00.0`/`15:00.0` and SATA `14:00.0`/`16:00.0` in that dump places the
  card in the second (daisy-chained) chipset tree. Confirm with `lspci -tv`.
- BIOS: the manual's text layer has no PCIe BIOS option list; MSI Click BIOS 5
  normally exposes per-slot "PCI_Ex Gen Switch", "Above 4G memory", "Re-Size BAR"
  under Settings > Advanced > PCIe/PCI Sub-system Settings (not verified from
  this manual). BIOS changelogs found (7E12v1E Aug 2024 AGESA 1.2.0.0a; AGESA
  1.0.0.7c Aug 2023) mention memory/CPU items only, nothing about PCIe/bridges
  [MSI](https://www.msi.com/news/detail/NEW-AMD-AGESA-PI-1-0-0-7c-BIOS-Update-Supports-Higher-Frequency-Memory-Modules---Stability-Bug-Fixes-142145).
- IOMMU grouping: X670E boards lump everything behind the second chipset into
  one group unless ACS override is used (L1T AM5 thread; Taichi BIOS 2.00 had
  broken groups, fixed in 2.02). No native (no-override) Tomahawk dump found.

### Q7. Alternatives, firmware, Creative, out-of-tree work

- Creative: "Creative does not provide an official (thus does not directly
  support) Linux driver ... Users may wish to contact ALSA community"
  [Phoronix](https://www.phoronix.com/news/SoundBlaster-AE-7-Linux).
- Out-of-tree work (all 2025-2026, all AI-assisted, none upstream):
  - [AffSeda/Creative_AE7_Linux](https://github.com/AffSeda/Creative_AE7_Linux):
    AE-7, flush-every-write patch for Debian `linux-source-7.2` 7.2.6, `ae7probe`
    diagnostic module, stock `ctefx.bin`, DSP loads and audio plays (warm reboots
    only tested). Debian-only install scripts; openSUSE user failed to build.
  - [verzic/sb-ae9](https://github.com/verzic/sb-ae9) (fork: DarkNikGr/sb-ae9):
    AE-9 DKMS (6.17+), patch 0001 (core flush, "upstream candidate"), patch 0002
    (AE-9 codec), `ae9recover`, QEMU CORB-trace patch, Windows-vs-Linux init
    analysis; "none of this has been run on an AE-5 or AE-7".
  - Kira Backes' hand-off (bug 221614 att. 310852): AE-7, replacement modules,
    Fedora 7.1.5/7.2.5, working headphone/speaker relay, Windows DSP image.
  - [s3boun3t/ae9_build](https://github.com/s3boun3t/ae9_build): AE-9 ACM/I2C
    protocol, DSP init works, outputs still silent.
  - Connor McAdams' unfinished AE-9 patches + e-mail dump (219552 att. 307447/307448).
- Firmware: upstream loads `ctefx-desktop.bin` only for SBZ/R3D/AE5
  (`ca0132_download_dsp_images`); **AE-7 and ZxR use `ctefx.bin`** with no
  desktop variant. `linux-firmware` ships only `ctefx.bin` and `ctspeq.bin`
  (WHENCE); `ctefx-desktop.bin` and `ctefx-r3di.bin` come from `alsa-firmware`
  (Arch 1.2.4-4; installed on this host). verzic/Kira extracted the DSP image
  Windows actually uses from `CtxHda.sys` (655,436 B, 187,457 program bytes differ
  from `ctefx.bin`); AffSeda got working audio with stock `ctefx.bin`, so the
  image is not needed for probe/basic playback
  [WHENCE](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/WHENCE)
  [Arch files](https://archlinux.org/packages/extra/any/alsa-firmware/files/).
- Hardware alternatives: AE-5 / AE-5 Plus (`1102:0012`, no bridge) work on
  Linux (217510 c20, SteamOS issue). USB Audio Class 2 DACs need no driver; one
  ex-AE-9 owner moved to a FiiO K7 Pro (219552 / 217510 c49, anecdotal).
- Safe-boot knobs used by others: `pci-stub.ids=1102:0010` (keeps the device
  enumerated but unbound; Kaiba, verzic, AffSeda), `options snd_hda_intel
  enable=1,0,1` (index order is trial and error), `module_blacklist=snd_hda_intel`.

## 3. Concrete things to try (ranked)

| # | Experiment | Kind | Expectation / why |
|---|---|---|---|
| 1 | Apply verzic `0001` to `sound/hda/core/controller.c` (+`stream.c`): `snd_hdac_chip_readl(bus, INTSTS)` at the end of `azx_int_clear()`, `snd_hdac_chip_readl(bus, GCTL)` at the end of `snd_hdac_bus_init_cmd_io()`, `SD_BDLPU`/`SD_CTL` read-backs in stream setup/reset. Rebuild `snd-hda-core.ko`. Boot with `pci-stub.ids=1102:0010 snd_hda_intel.enable_msi=0`, then `driver_override`+bind at runtime (AffSeda "Reproducing" step 4). | guest/host kernel module | `probe_codec` returns `0x11020011`, DSP loads. Validated from cold boot by verzic and on warm reboots by AffSeda. Keep our probe-serialising mutex. |
| 2 | If (1) still wedges, switch to AffSeda's blanket patch: read-back in `snd_hdac_reg_write{b,w,l}` (`include/sound/hdaudio.h`, rebuild snd-hda-core, snd-hda-codec, snd-hda-intel, snd-hda-codec-ca0132) and a `readw(bus->remap_addr)` after every `spec->mem_base` write in `ca0132.c`. | guest/host kernel module | Covers the BAR2 bursts in the AE-7 codec path (8x `+0x304`, `ae5_register_set`, `ca0113_mmio_command_set*`). |
| 3 | Port verzic's `ae9recover` idea: on wedge, remove `13:00.0`/`14:00.x`, SBR the chipset downstream port above `13:00.0`, pulse the bridge's secondary reset, rescan. | host tool | Iterate without reboots; also tells whether a bus reset revives the bridge (relevant for VFIO device release). |
| 4 | Move the card to PCI_E3 (CPU Gen4 x4) if it is free; else keep it out of the chipset tree that hosts the RAID AHCI (`lspci -tv`). | host hardware | Does not cure the wedge (fails on CPU-less paths too) but removes the AHCI/xHCI collateral that drops us into emergency mode. |
| 5 | Drop the `single_cmd=1` experiment; keep `enable_msi=0` (device has no MSI cap anyway) and `iommu=pt`. Re-examine the "MSI alloc hang" and the `14:00.1` function (`lspci -xxx -s 14:00.0` vs `14:00.1`). | host cmdline / diagnosis | If `.1` is a phantom function, blacklist it via `snd_hda_intel.enable=` index or a quirk; the concurrent-probe mutex may then be unnecessary. |
| 6 | After the codec probes: expect `AMD-Vi IO_PAGE_FAULT` at the PCM ring end if the IOMMU translates (guest case). Mitigation per Kira: persistent 1 MiB coherent PCM allocation; per verzic: `iommu=pt`. | guest kernel / cmdline | Audio crackle/stall otherwise. |
| 7 | For a Windows VM capture: `-device vfio-pci,host=0000:14:00.0,x-no-mmap=on`, `-trace enable=vfio_region_*,file=...`, optional verzic QEMU CORB-mirror patch; reboot the host before bringing the card up under Linux again. | QEMU option | Reproduces s3boun3t/verzic captures; AE-7 BAR2 relay/DAC sequences are already documented in Kira's notes, so this is only needed for mic/other features. |
| 8 | Codec-side extras once probing works: `model=ae7` is already auto-picked by SSID; optionally drop the `CtxHda.sys` DSP image in as `ctefx.bin` (Kira/verzic) if DSP features misbehave. | guest module / firmware | Not needed for probe. |
| 9 | Report upstream: nobody has. A minimal patch (item 1) with a CTHDA/ASMedia-upstream-bridge condition in `azx_first_init()` (AffSeda's "suggested upstream shape") to linux-sound, CC Takashi Iwai, referencing bugs 217510/221614/219552 c56-c61. | process | Takashi asked for maintainer-list reports; he attributed the AE-9 X870E case to "the PCI core side". |

## 4. Sources

Bugzilla (REST API): [217510](https://bugzilla.kernel.org/show_bug.cgi?id=217510),
[221614](https://bugzilla.kernel.org/show_bug.cgi?id=221614) (+ [att. 310852](https://bugzilla.kernel.org/attachment.cgi?id=310852), [att. 310262](https://bugzilla.kernel.org/attachment.cgi?id=310262)),
[219552](https://bugzilla.kernel.org/show_bug.cgi?id=219552),
[218344](https://bugzilla.kernel.org/show_bug.cgi?id=218344),
[208667](https://bugzilla.kernel.org/show_bug.cgi?id=208667),
[44881](https://bugzilla.kernel.org/show_bug.cgi?id=44881).
Repos: [AffSeda/Creative_AE7_Linux](https://github.com/AffSeda/Creative_AE7_Linux),
[verzic/sb-ae9](https://github.com/verzic/sb-ae9), [s3boun3t/ae9_build](https://github.com/s3boun3t/ae9_build),
[SteamOS#1763](https://github.com/ValveSoftware/SteamOS/issues/1763).
Lists: [Debian #1115581](https://bugs.debian.org/1115581),
[linux-sound 2026-04](https://ratatoskr.run/linux-sound/2026/04/11364619),
[linux-sound 2026-06](https://ratatoskr.run/linux-sound/2026/06/17098469/t),
[linux-sound 2024-01](https://lore.kernel.org/linux-sound/18cd5be2bc7.e19fbd7b17331.5233193232348276602@zoho.com/T/#u),
[Takashi stable NAK 2020](https://lkml.iu.edu/hypermail/linux/kernel/2010.3/09705.html),
[AE-7 series cover](https://lkml.iu.edu/hypermail/linux/kernel/2008.3/03249.html),
[ASPM quirk](https://lkml.iu.edu/hypermail/linux/kernel/2007.2/09173.html),
[ASM1083 IRQ 2012](https://lkml.iu.edu/hypermail/linux/kernel/1201.3/03042.html),
[AMD E-450 IRQ](https://lkml.iu.edu/hypermail/linux/kernel/1204.3/02015.html).
Kernel source: [quirks.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/pci/quirks.c),
[probe.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/pci/probe.c),
[core/controller.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/sound/hda/core/controller.c),
[ca0132.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/sound/hda/codecs/ca0132.c),
commits `30579eebba6a`, `696b0a9bd2e4`, `ed4da361bf94`, `cb9b6f9d2be6`, `ebdb51eb7806`, `b361663c5a40`,
[linux-firmware WHENCE](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/WHENCE),
[FreeBSD hdac.c](https://cgit.freebsd.org/src/tree/sys/dev/sound/pci/hda/hdac.c).
Forums: [EndeavourOS](https://forum.endeavouros.com/t/unable-to-boot-after-installing-new-sound-card-ae-7/40457),
[Linux Mint AE-7](https://forums.linuxmint.com/viewtopic.php?t=432162),
[Linux Mint AE-9](https://forums.linuxmint.com/viewtopic.php?t=435701),
[Fedora 42](https://discussion.fedoraproject.org/t/sound-blaster-ae-7-build-42-fedora-kde-plasma-desktop/169201),
[Fedora 38](https://discussion.fedoraproject.org/t/no-sound-on-creative-ae-7-on-fedora-38/76751),
[computerbase](https://www.computerbase.de/forum/threads/manjaro-creative-ae7-kein-sound.2037062/),
[CachyOS](https://discuss.cachyos.org/t/creative-ae-7-and-cachyos-need-assistance/21800),
[Arch AE-9](https://bbs.archlinux.org/viewtopic.php?id=300652),
[Arch ASM1083 IO_PAGE_FAULT](https://bbs.archlinux.org/viewtopic.php?id=275425),
[L1T AE-5 VFIO](https://forum.level1techs.com/t/sound-blaster-ae-5-reset-bug-sound-card-passthrough/167025),
[L1T X-Fi VFIO](https://forum.level1techs.com/t/unsolved-sound-card-passthrough-doesnt-work-properly-inside-windows-vm/235718),
[L1T AM5 IOMMU](https://forum.level1techs.com/t/am5-iommu-vfio-best-motherboard/189720?page=4),
[Proxmox Tomahawk groups](https://forum.proxmox.com/threads/proxmox-vm-setup-issue-usb-crashes-and-gpu-output-failure-on-pci-ports.146947/),
[Proxmox bridge passthrough](https://forum.proxmox.com/threads/cant-passgtrough-pcie-to-pci-brigde-of-sound-card.93582/),
[libvirt pci-bridge](https://lists.libvirt.org/archives/list/devel@lists.libvirt.org/thread/MFGEQWHX4J4NY5T7ZLNQJGKEM754GTFJ),
[Qubes single_cmd](https://groups.google.com/g/qubes-users/c/79Xu02alass/m/PHmBoIE6BgAJ),
[Haiku 16921](https://dev.haiku-os.org/ticket/16921).
Vendor: [MSI manual PDF](https://download.msi.com/archive/mnu_exe/mb/MAGX670ETOMAHAWKWIFI.pdf),
[MSI datasheet](https://storage-asset.msi.com/datasheet/mb/global/MAG-X670E-TOMAHAWK-WIFI.pdf),
[ASMedia ASM1085](https://www.asmedia.com.tw/products-list/aDcYq0BxZfuH9Nz5/2f2yq89xz7URBZqD),
[Phoronix / Creative statement](https://www.phoronix.com/news/SoundBlaster-AE-7-Linux),
[2019 AE-7 review (IDT bridge photo)](https://thepcenthusiast.com/creative-sound-blaster-ae-7-pcie-sound-card-review/).
Not fetchable: Osmocom bridge wiki (Anubis), linux-hardware.org probes (429),
Reddit (blocked), web.archive.org (blocked).

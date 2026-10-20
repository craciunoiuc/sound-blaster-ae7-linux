# Iteration log — project memory

Every run gets an entry here (append-only). This file survives across sessions
and agents — it's how we avoid re-learning the same dead ends.

Format (VM rig, from 2026-10-20):
```
## run-NNN[-label]  YYYY-MM-DD
- kernel: v7.2.10 + vm/patches (list) [+ uncommitted change]
- cmd: vm/run.sh --passthrough --test ... [--append/--modparams ...]
- result: verdict; key lines (res=, register values, errors)
- host: AMD-Vi / AER / vfio lines from host dmesg, or "clean"
- next: what to change next
```

Findings: `reference/findings.md`. Entries before "restructure 2026-10-20" are
bare-metal 7.1.3 runs, and several of their conclusions turned out wrong.

---

## project bootstrap  2026-07-15
- v7.1.3 cloned; patch 0001 (ca0132 AE7DBG) applies clean.
- Built minimal defconfig bzImage, booted card-absent in QEMU → SUCCESS.
- Confirms patch→build→boot→capture pipeline.

## MAJOR PIVOT  2026-07-16  (blacklist test)
- Blacklisting BOTH ca0132 AND snd_hda_intel → boot STILL hangs.
- Disproved "hang is in the audio driver" → it's earlier (PCI enumeration / boot).
- Led to the PCI-param investigation (nommconf, aspm, etc.) — see archive/.

## Plymouth found  2026-07-16
- Removing `splash` + adding debug-visibility params → **boots to login**.
- Plymouth (`splash`) was conflicting with the bridge during early KMS.
- FIX #1: drop `splash` permanently.

## snd_hda_intel isolation  2026-07-16
- Blacklist ca0132 only, allow snd_hda_intel → HANGS.
- The HDA **controller** driver hangs, not the codec.
- Module params tested blind (enable_msi, single_cmd, polling_mode, probe_mask).
  All failed — but blind (no instrumentation).

## Instrumented kernel built + booted  2026-07-16
- Built full CachyOS-config kernel `7.1.3-dirty` with patches 0001-0003
  (HDACTRLDBG prints across intel.c, controller.c, core/controller.c).
- Booted via limine `linux-ae7dbg` entry.
- Hang definitively at `pci_alloc_irq_vectors(PCI_IRQ_MSI)`.
- FIX #2: `snd_hda_intel.enable_msi=0` → past MSI, IRQ acquired.

## Concurrent-probe lockup found  2026-07-16
- AE-7 has TWO PCI functions (14:00.0 + 14:00.1), probed concurrently via async
  workqueue → hard CPU lockup (`clocksource: Watchdog remote CPU read timed out`).
- FIX #3: serialize `azx_probe_continue` with `azx_probe_serialize_mutex`.
- After fix: no more lockup; both functions probe sequentially.

## res=0x0 (UNSOLVED)  2026-07-16
- With MSI + serialization fixed, controller probes, but `probe_codec(addr=1)`
  returns `res=0x0` — codec never responds to vendor-ID query via CORB/RIRB.
- Tried: 32-bit DMA override, snoop-off (uncached buffers). `res=0x0` persists.
- AE-7's active probing destabilizes the PCIe bus (AHCI 16:00.0 dies → emergency
  mode because RAID root can't mount).
- Card works in Windows → hardware capable; Linux bridge init differs.

## NOT YET RUN: single_cmd=1  (the key remaining experiment)
- `snd_hda_intel.single_cmd=1` bypasses CORB/RIRB DMA, uses PIO immediate
  registers (controller MMIO — which the bridge DOES forward).
- Never tested WITH serialization + enable_msi=0 (the three blockers that foiled
  the early blind test are now fixed).
- If `res` becomes non-zero → PIO works, path to host audio.
- If `res=0x0` again → bridge can't forward HDA verbs at all → VFIO to Windows.

## current working state
- kernel/ tree has: patches 0001-0004 applied + serialization mutex + DMA/snoop
  bridge override + bulletproof bridge-detection logging.
- Host cmdline: `quiet nowatchdog rw root=UUID=... amd_iommu=on iommu=pt
  loglevel=8 ignore_loglevel snd_hda_intel.enable_msi=0` (no splash)
- snd_hda_intel currently BLACKLISTED on the host (bootable, safe state).
- linux-ae7dbg limine entry exists for instrumented-kernel testing.

## restructure  2026-10-20
- Moved to a VM rig. QEMU direct-boots a linux-stable v7.2.10 guest (vm/linux,
  series in vm/patches) with the card on vfio-pci. Guest root = host / read-only
  over virtio-9p. Output goes to logs/run-NNN[-label]/. No host reboot per change.
- Host: vfio-pci claims 1102:0010 at boot (host/setup.sh), replacing the global
  snd_hda_intel blacklist. pcie_acs_override=downstream,multifunction planned,
  to split IOMMU group 23 (all of chipset 2).
- Corrections (details in reference/findings.md):
  - The "PCI-ID collision" root cause was false. 1102:0010 under CTHDA is the
    correct upstream CA0132 entry. The CTHDA->GENERIC override (patch 0004 and
    the runtime override) removed caps the card needs.
  - So fix #2 (MSI hang) was self-inflicted: the stock driver never uses MSI.
    Fix #3 (concurrent-probe mutex) is unverified: no 14:00.1 ever showed in
    lspci.
  - Root is NVMe RAID0 (nvme0 on CPU lanes + nvme2 behind chipset 1), not SATA.
    The cause of the emergency-mode boot is unknown.
  - err=0 res=0x0 does not prove that RIRB DMA was lost. It also results when
    azx_send_cmd() fails and nothing is queued (probe_codec ignores the error).
  - host/isolate-card.sh searched a subsystem ID with lspci -d.
- Deleted (still in git history at 80f4339): PLAN.md,
  reference/complete-findings.md, reference/ae7-code-anchors.md,
  reference/archive/, patches/ (0001-0004, for 7.1.3), host/isolate-card.sh,
  host/blacklist-ca0132.conf, host/enable-iommu.md. kernel/ and build/ were
  already gone.
- The host may still have /lib/modules/7.1.3-dirty, /boot/*linux-ae7dbg* and the
  linux-ae7dbg limine entry. Unused; the user can remove them.
- next: user runs host/setup.sh + reboot; host/capture.sh; then
  vm/experiments.md from the top (emulated rig check first).

## research + flush patches  2026-10-20
- reference/research.md: three independent 2026 AE-7/AE-9 efforts (AffSeda,
  verzic/sb-ae9, bug 221614) find the ASM1083 rev 03 wedges after ~18 posted
  MMIO writes with no read between them; one read-back cures it.
- vm/patches/0002 (hdac bus flag flush_writes, auto-on for CTHDA,
  snd_hda_intel.flush_writes=0/1) and 0003 (ca0132 region 2 writes flushed).
  Emulated probe/play PASS with flush_writes=1 (run-026, run-027).
- run.sh --passthrough now traps BAR access by default (x-no-mmap=on);
  --mmap opts into real timing. hda-mmio.py reads back after each write.
- next: card in, host/setup.sh + ACS override, then the fast path in
  vm/experiments.md (w0-w4).

## card seated + w0-pio  2026-10-20
- host: setup.sh applied, pcie_acs_override active. bind.sh --check OK:
  14:00.0 on vfio-pci, IOMMU group 38 = bridge 13:00.0 + card only.
  Upstream port 0d:0a.0 (chipset 2). Link 2.5GT/s x1, ASPM off.
- capture-20261020-211211: only function 0 (no 14:00.1). Controller
  subsystem 1102:0081. Card caps: PM only (D2), no MSI. reset_method
  "pm bus". Bridge DevSta NonFatalErr+ already at boot.
- run-030-w0-pio (passthrough, trapped BARs, no driver): PASS.
  STATESTS 0x0002; IC verb codec 1 vendor 0x11020011 rev 0x00100918;
  AFG nid 0x01 subsystem 0x11020081, 23 widgets, power D0.
  Host dmesg: vfio enable/reset only. No AER, no IO_PAGE_FAULT.
- next: w1 (driver + flush patch, trapped BARs).

## w1-flush-trapped  2026-10-20
- run-031 (passthrough, trapped BARs, patches 0001-0003, ae7_debug=1):
  PASS. "Flush each register write" on; GCAP 0x6401 (64OK, ISS 4,
  OSS 6), driver_type 15 (CTHDA), caps 0x0085120f, msi 0, snoop 0.
- CORB/RIRB DMA works: CORB WP/RP 1/1, RIRB WP 1,
  RIRB[1] = 11020011:00000001. INTx irq 20.
- ca0132: "picked fixup Sound Blaster AE-7 for PCI SSID 1102:0081",
  "ca0132 DSP downloaded and running" (ctefx.bin). PCMs: CA0132 Analog,
  Digital, What U Hear.
- Host dmesg: vfio reset lines only.
- next: w3 (--mmap, flush on) = real timing. w2 (stock, trapped) held
  back: if the wedge is count-based it reproduces the bare-metal crash.

## w3-flush-mmap + w4-play  2026-10-20
- run-032 (--mmap = direct BAR access, real timing, flush on): PASS.
  AE-7 fixup picked, "ca0132 DSP downloaded and running".
- run-033 (--mmap, play): PASS. speaker-test plughw:0,0, 48 kHz S16 2ch,
  440 Hz sine, Front Left + Front Right. No IO_PAGE_FAULT, no xrun.
- Host dmesg for both: vfio reset lines only.
- Conclusion: patches 0002/0003 fix the probe at real timing in the VM.
  Audible output not yet confirmed by the user.

## w5-sweep + w6-headphone  2026-10-20
- New test vm/guest/tests/sweep.sh (TEST_ARGS "SECONDS [all|speakers|
  headphone]"): sets Output Select, Surround Channel Config, auto
  detect off, Master 60%, plays speaker-test -t wav.
- run-035 (--mmap, 30s Speakers 5.1 + 30s Headphone): PASS.
- run-037 (--mmap, 60s Headphone): PASS, 21 L/R cycles, no errors.
  Host dmesg: vfio resets only for both.
- Audible output: waiting for user report.

## no audible output: diagnosis  2026-10-20
- User hears nothing from any jack (headphones) in run-035/run-037.
- run-039 outdiag (new test: play + record What U Hear, dyndbg ca0132):
  loopback peak 25202 rms 13390 -> HDA stream reaches the DSP mix.
  PCM RUNNING, hw_ptr advances, converter 0x02 stream=5. Mixer puts all
  rc 0. select_out speaker -> hp path runs with no error.
- Codec pins (hp mode): 0x0b/0x0f/0x10 Pin-ctls 0x00, 0x11 0x40 OUT.
  AE-7 out_pins: 0x0b line out, 0x11 rear headphone, 0x10 C/LFE, 0x0f
  rear surround.
- run-040 with patch 0004 (log ca0113 reads): every ca0113 command gets
  handshake 0x210=0xaa, 0x860=1, 0x840=1. HP preset 30/2e=3f 30/30=3f
  48/0d=00 48/19=02 30/32=00; gain 48/11..14 = ff 2c f5 32.
- So: stream, DSP, pins, ca0113 commands all look right. Break is after
  the DSP (DAC/amp/relay) or in the jack used. Researching jack map.

## first audible output  2026-10-20
- run-043 w9-gpio-vol90 (--mmap, sweep "30 all 90", patch: AE-7 headphone
  mode also sets ca0113 GPIO 7 and 4): user HEARS Front Left/Right (no
  Center) on the 2nd-to-last rear jack (left to right), until the end.
- BAR2 GPIO: speakers 0x300=0x03 0x320=0x100; headphone 0x300=0x93
  0x320=0x104 (matches Kira's working end state). 0x100=0x600, 0x304=0xff.
- Open: which phase was audible (speakers/upstream vs headphone/GPIO).

## both outputs audible  2026-10-20
- run-045 w10-voice-vs-tone (sweep "30 all 90"): Speakers phase (voice,
  5.1) heard "Front Left / Front Right" on the 3rd-to-last rear jack
  (left to right) = Front out. Headphone phase (440 Hz tone) heard L/R on
  the 2nd-to-last rear jack = Headphone out.
- Kept the GPIO change as vm/patches/0005 (AE-7 headphone preset sets
  ca0113 GPIO 0, 7, 4). Not yet shown which of GPIO patch / Master 90
  made the headphone jack work; Front out worked on the upstream path
  once Master was 90 (earlier runs used 59-60 = about -40 dB twice).
- Rear and Center/Sub jacks not checked.

## microphone  2026-10-20
- New test vm/guest/tests/mictest.sh: beep, record rear mic N s, double
  beep, play the take back on Headphone. TEST_ARGS "SECS MASTER BOOST".
- run-047 w11-mic (mic in the rightmost rear jack, boost 0 dB, capture
  0 dB): user heard own voice on playback. Level low: peak 409, rms
  36-70 per second (speech about 2x floor). Rightmost jack = Mic/Line in.
- run-048 w12-mic-boost20 (Mic Boost 20 dB): PASS. peak 5423 (about
  -16 dBFS), speech rms up to 925, floor 240. Boost 20 dB is a sane
  default for this mic.

## patch 0005 not needed  2026-10-20
- run-049 w13-hp-no-0005 (series 0001-0004 only, sweep "20 headphone
  90"): user hears the L/R tone on the Headphone jack. BAR2 GPIO
  0x300=0x03 (GPIO 4 and 7 low), 0x320=0x100.
- So the earlier silence was the volume (Master 59-60 applied to both
  DAC amp and DSP). Dropped 0005 (AE-7 headphone preset GPIO {0,7,4})
  from vm/patches; recreate from this note if ever needed.
- Fix for the host = 0002 + 0003 only (0001/0004 are debug, inert).

## host DKMS package  2026-10-20
- Series reordered so the fix (0002, 0003) applies without the debug
  patches (flush_writes param moved after ctl_dev_id). Guest unchanged.
- host/dkms/mkdkms.sh: linux-stable v<base> + 0002 + 0003 ->
  vm/build/dkms/ae7-hda-<base>/ (core, common, controllers/intel,
  codecs/ca0132 + patched include/sound/hdaudio.h via NOSTDINC_FLAGS).
  Test build vs 7.2.10-1-cachyos headers (LLVM=1): OK, vermagic match.
- host/dkms/install.sh (root): dkms add/build/install to updates/dkms,
  guarded /etc/modprobe.d/ae7-vfio.conf (vfio-pci claims the card only
  when no DKMS snd-hda-intel exists for the running kernel), initramfs
  check. --uninstall restores the plain claim via host/setup.sh.

## host boot with DKMS  2026-10-20
- Boot OK; 14:00.0 on snd_hda_intel (card 2 "Creative"), "Flush each
  register write", "ca0132 DSP downloaded and running". No AER, no
  ahci/nvme/xhci errors. ("picked fixup  for PCI SSID" name is empty on
  the host only because SND_DEBUG_VERBOSE is off.)
- 43 x AMD-Vi IO_PAGE_FAULT, 14:00.0, address 0xfff40000, read, in
  ~6 s bursts, one per 0.683 s = 32768 frames at 48 kHz: the controller
  reads past the PCM ring end at each wrap; host IOMMU is in translated
  mode (no iommu=pt). VM never faulted (all guest RAM mapped).
- 70.2 s: azx_get_response timeout -> polling -> single_cmd (last cmd
  0x1161c0c0, DSP node 0x16), during a fault burst.
- power_save=0, runtime PM on: not PM.
- Proposed: host cmdline iommu=pt; driver-side ring padding = fallback.

## WORKING ON THE HOST  2026-10-20
- Host cmdline + iommu=pt (IOMMU default domain: Passthrough). DKMS
  ae7-hda 7.2.10 (0002 + 0003). User has sound (headphones) and mic.
- After ~220 s of use: 0 IO_PAGE_FAULT, no azx_get_response timeout, no
  single_cmd fallback, no AER/ahci/nvme/xhci errors.
- Host needs: DKMS modules, iommu=pt (the controller reads past the PCM
  ring end; translated IOMMU faults on it), mixer Master >= 90, Output
  Select per jack, Mic Boost 20 dB. pcie_acs_override is only for VFIO.

## final cleanup  2026-10-20
- ACS override not needed in host mode; user removes it from
  /etc/default/limine (only VM mode needs it).
- host/setup.sh keeps the guarded claim of host/dkms/install.sh;
  host/bind.sh --bind loads vfio-pci with --ignore-install; install.sh
  --uninstall removes the guarded file before restoring the plain one.
- Docs rewritten to the final state: README, AGENTS.md (host mode / VM
  mode), reference/findings.md (result, evidence), experiments.md
  (results table), ae7-outputs.md (outcome on this card).

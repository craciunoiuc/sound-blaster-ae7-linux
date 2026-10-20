# AE-7 findings

Final summary as of 2026-10-20. Run-by-run evidence is in
[`logs/STATUS.md`](../logs/STATUS.md). The old bare-metal notes (July 2026, Linux
7.1.3) are in git history at `80f4339`; most of their conclusions were wrong (see
"Old conclusions").

## Result

The AE-7 works on this host: playback (headphone and front out) and the mic.

**Root cause.** The ASMedia ASM1083/1085 rev 03 bridge on the card (or the CA0132
behind it) wedges after a burst of about 14-18 back-to-back posted MMIO writes
with no read between them. The stock init does such a burst once:
`azx_int_clear()` (one write per stream plus STATESTS, RIRBSTS, INTSTS) and then
`snd_hdac_bus_init_cmd_io()` (CORB/RIRB setup), before its first read. After the
wedge every read returns all-ones after a ~220 ms completion timeout, the CORBRP
poll takes minutes with interrupts off, and devices on the same chipset switch
fail. Three independent 2026 efforts found the same (see
[`research.md`](research.md)); our VM runs confirmed the fix on this card.

**Fix.** Read back after each register write:

- `vm/patches/0002` (ALSA: hda: flush posted writes on CTHDA): `struct hdac_bus`
  gets `flush_writes`; `snd_hdac_reg_write{b,w,l}()` read the register back when
  it is set. snd-hda-intel sets it for `AZX_DRIVER_CTHDA`
  (`snd_hda_intel.flush_writes=-1/0/1`, auto/off/on).
- `vm/patches/0003` (ALSA: hda/ca0132: flush region 2 writes): all BAR2 (ca0113)
  writes go through helpers that read BAR0 back when `flush_writes` is set.

**Host requirements.**

| What | Why |
|---|---|
| DKMS `ae7-hda` (0002 + 0003), `host/dkms/` | the fix; stock modules wedge the bridge |
| cmdline `iommu=pt` | the controller reads past the end of the PCM ring at each wrap; a translated IOMMU faults on it (`IO_PAGE_FAULT` at the ring end) and the codec then stops answering |
| guarded vfio-pci claim (`/etc/modprobe.d/ae7-vfio.conf`) | keeps the stock driver off the card on kernels without the DKMS modules |
| no `splash` | boot stopped with Plymouth and the card installed (mechanism unknown) |

**Mixer.** `Master Playback Volume` 90 or more: Master scales both the DAC amp and
the DSP volume, so 59-60 (about -40 dB twice) is inaudible. `Output Select` =
Headphone or Speakers. `Mic Boost Capture Switch` 2 (20 dB). No GPIO, relay or
ca0113 changes were needed.

**Jacks** (rear bracket, counted from the right):

| Position | Use | State |
|---|---|---|
| 1 (rightmost) | Mic/Line in | works (`Input Source` = Microphone) |
| 2 | Headphone/Headset out | works (`Output Select` = Headphone) |
| 3 | Front out | works (`Output Select` = Speakers) |
| others | Rear out, Center/Sub out, optical | not tested |

## Evidence (VM, then host)

- **w0, MMIO only, no driver** (run-030): the codec answers the immediate command
  with vendor `0x11020011`, rev `0x00100918`, AFG subsystem `0x11020081`. The
  codec link was never broken.
- **w1, driver + fix, BAR access trapped by QEMU** (run-031): CORB/RIRB DMA works
  (`RIRB[1] = 11020011:00000001`), INTx works, ca0132 picks QUIRK_AE7 and loads
  the DSP (`ctefx.bin`).
- **w3/w4, same with direct BAR access (real timing)** (run-032/033): probe and
  playback pass, host log clean.
- **Loopback** (run-039): "What U Hear" records the playback at full level, so the
  DSP gets the stream. Silence at the jacks was the volume, not the DSP path.
- **ca0113** (run-040, debug patch 0004): every serial command gets handshake
  `0xaa` and status 1.
- **GPIO 4/7 not needed** (run-049): headphones play with GPIO 4 and 7 low.
- **Host, DKMS without `iommu=pt`**: 43 `IO_PAGE_FAULT` at `0xfff40000`, one per
  0.683 s (32768 frames at 48 kHz = one ring wrap), then `azx_get_response
  timeout`, single_cmd fallback. **With `iommu=pt`**: 0 faults, no timeouts, sound
  and mic work.
- The unpatched driver (`flush_writes=0`) was never run on the card again; the
  external reports and the bare-metal history cover that case.

## Hardware

| | |
|---|---|
| Board | MSI MAG X670E Tomahawk WiFi, BIOS `1.L1` (2026-06-08) |
| CPU / RAM | Ryzen 7 7800X3D, 64 GB |
| OS | CachyOS, kernel 7.2.10-1-cachyos, limine (`/etc/default/limine`) |
| Slot | behind chipset 2 (downstream port `0d:0a.0`, link 2.5 GT/s x1); slot name unverified |
| Bridge on card | ASMedia ASM1083/1085 PCIe-to-PCI, `1b21:1080` rev 03, ASPM off |
| HDA controller | Creative CA0132, `1102:0010` rev 01, function 0 only |
| Controller subsystem | `1102:0081` "Sound Blaster AE-7" (matches `QUIRK_AE7`) |
| Controller caps | PM only (D2), no MSI; `reset_method` = pm, bus; INTx pin B |
| Codec | address 1 (`STATESTS` = `0x0002`) |
| Root filesystem | `md0` = RAID0 of nvme0 (CPU lanes) + nvme2 (chipset 1) |

PCIe path with the card installed: `00:02.1` → chipset 1 (`06:08.0`) → chipset 2
(`0d:0a.0`) → bridge `13:00.0` → controller `14:00.0`. Chipset 2 also has nvme1
(`/home/cez/Downloads`, `nofail`), a USB 3.2 xHCI and a SATA AHCI; without ACS
override they share one IOMMU group with the card. With
`pcie_acs_override=downstream,multifunction` the card's group holds only the
bridge and the controller. The override is only needed for VFIO passthrough.

Bus numbers shift by 2 when the card is installed. Find devices by ID, never by
BDF (`ae7_bdfs` in `vm/config.sh`).

At boot the bridge shows `DevSta: NonFatalErr+` before any driver touches the
card. It had no visible effect.

## Old conclusions that were wrong

- **"PCI-ID collision: the CA0132 is matched as the X-Fi CA0110."** False.
  Upstream lists `1102:0010`/`0012` under `/* CTHDA chips */` with
  `AZX_DCAPS_PRESET_CTHDA` (NO_MSI, POSFIX_LPIB, NO_64BIT, 4K_BDLE_BOUNDARY,
  SNOOP_OFF). That is the CA0132 entry; the X-Fi is `AZX_DRIVER_CTX`. Overriding it
  to GENERIC removed caps the card needs.
- **"MSI allocation hang."** Self-inflicted by that override, and the card has no
  MSI capability at all; the stop was most likely the write-burst wedge.
- **"Concurrent probe of 14:00.0 and 14:00.1."** There is no function 1.
- **"The bridge cannot forward CORB/RIRB DMA."** It can (w1).
- **"The hang is in PCI enumeration."** That was the `splash` hang.
- **"AHCI holds the RAID root."** Root is NVMe RAID0.
- **"Codec at address 1 because of the bridge."** The address comes from the SDI
  line on the card; address 1 is normal.
- **"0x0081 is only the codec's subsystem ID."** The controller reports it too.
- **"The AE-7 headphone needs GPIO 4/7."** Not on this card (run-049).
- **`host/isolate-card.sh` matched `lspci -d 1102:0081`.** `-d` takes
  vendor:device, so it never matched.

## How `err=0 res=0x0` happened

`probe_codec()` ignores the return value of `azx_send_cmd()`. After the wedge,
`CORBWP` reads `0xffff`, so `snd_hdac_bus_send_cmd_corb()` returns -EIO before it
counts the command, and the response read returns the stale `rirb.res[1]` (0).
`single_cmd=1` has the same trap: an all-ones `IRS` makes the send give up without
touching `res`. So `res=0x0` never meant "the codec answered 0".

## Not tested / open

- Rear out, Center/Sub out, optical out, line in, the ACM puck.
- Whether every write needs a read-back, or only the init and stream-setup bursts
  (the minimal upstream patch).
- Why the controller reads past the PCM ring end. A driver fix (padding the ring
  buffer) would make `iommu=pt` unnecessary.
- `ca0132_mmio_init()` still has no `case QUIRK_AE7`, so the AE-7 branches in
  `ca0132_mmio_init_ae5()` never run. Audio works without them.
- Upstream submission of 0002 + 0003 (linux-sound, bugs 217510, 221614).

## Code notes

`sound/hda/codecs/ca0132.c` (it was `sound/pci/hda/patch_ca0132.c` up to 6.x):

- `SND_PCI_QUIRK(0x1102, 0x0081, "Sound Blaster AE-7", QUIRK_AE7)`; force with
  `model=ae7`. The host kernel logs `picked fixup  for PCI SSID 1102:0081` with an
  empty name because `CONFIG_SND_DEBUG_VERBOSE` is off.
- BAR2 is mapped with `pci_iomap(pci, 2, 0xC20)`. The ca0113 companion chip takes
  serial commands through `ca0113_mmio_command_set()` (groups 0x30 relay, 0x48 DAC).
- Output select for the AE series: `ae5_mmio_select_out()` with
  `ae7_ca0113_output_presets`, then DSP params, then `ae5_headphone_gain_set()`.
- DSP firmware: `ctefx.bin` (the desktop image is only for SBZ/R3D/AE5).

ASMedia `1b21:1080` quirks in `drivers/pci/`: `pci_ext_cfg_is_aliased()`
(extended config space aliasing), `quirk_disable_aspm_l0s_l1`, and
`quirk_use_pcie_bridge_dma_alias` (bug 44881). None of them covers the posted-write
wedge.

## References

- [`research.md`](research.md): external reports, links, sources.
- [`ae7-outputs.md`](ae7-outputs.md): jack map and output hardware research.
- [`vm/experiments.md`](../vm/experiments.md): the VM experiment plan and results.

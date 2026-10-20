# AE-7 VFIO experiment plan

## Results (2026-10-20)

Hypothesis (W) was right. The fast path below settled it; the E-series was not
needed. Runs are in `logs/STATUS.md`.

| Run | Command (short) | Result |
|---|---|---|
| w0 run-030 | `--test pio` | PASS: codec 1 vendor `0x11020011` over MMIO only |
| w1 run-031 | `--test probe --modparams ae7_debug=1` | PASS: CORB/RIRB, INTx, QUIRK_AE7, DSP loaded |
| w2 | `flush_writes=0` | not run (would reproduce the bare-metal wedge) |
| w3 run-032 | `--mmap --test probe` | PASS at real timing |
| w4 run-033 | `--mmap --test play` | PASS, but silent: Master 59 is about -40 dB twice |
| run-039/040 | `--test outdiag`, debug 0004 | DSP loopback has signal; ca0113 accepts commands |
| run-043/045 | `--mmap --test sweep --test-args "30 all 90"` | heard: front out (3rd jack from right), headphone (2nd) |
| run-047/048 | `--mmap --test mictest --test-args "8 80 2"` | mic on the rightmost jack; 20 dB boost gives peak about -16 dBFS |
| run-049 | headphone without GPIO 4/7 change | still heard: no GPIO patch needed |

Then the host: DKMS `ae7-hda` (0002 + 0003) plus `iommu=pt`. See
`reference/findings.md`.

## Plan

Ordered runs for when the card is seated. Each step says what it isolates and
how to read the result. Run them in order: a later step only makes sense if
the earlier steps are understood. Record each run (dir + one line) in
`logs/STATUS.md`.

Leading hypothesis (W), from three independent 2026 reports on the same
bridge (see `reference/research.md`): a burst of about 14-18 posted MMIO
writes with no read between them wedges the ASM1083 rev 03. After that every
read returns all-ones (~220 ms each). The stock init does such a burst in
`azx_int_clear()` + `snd_hdac_bus_init_cmd_io()`; a read between the writes
cures it. Patches 0002/0003 do this (`snd_hda_intel.flush_writes`, auto-on
for CTHDA). Fallback hypotheses if (W) is wrong:

- **(a) DMA path broken, MMIO fine** (IOMMU alias, bridge, snoop).
- **(b) Codec link not functional.** Only the STATESTS bit is alive.
- **(c) Missing init.** Windows does something first (GPIO, BAR2, codec power).

`--passthrough` traps every BAR access by default (`x-no-mmap=on`), which
spaces the guest's writes by a VM exit each and should keep the bridge safe.
`--mmap` gives the guest direct BAR access at real timing. **Never combine
`--mmap` with `flush_writes=0`**: that is the known wedge and it can take
down host devices on the same chipset.

Tools: `vm/guest/tools/hda-mmio.py` (userspace BAR0 access, IC verbs) and the
kernel patch `vm/patches/0001-ALSA-hda-add-ae7_debug-register-dump.patch`
(`snd_hda_intel.ae7_debug=1`: GCAP/caps at init, register + CORB/RIRB ring
dumps before/after the codec probe and on every response timeout, max 16
dumps per controller).

## Reference runs (emulated, no card needed)

Run these first so you know what good output looks like:

```
vm/run.sh --emulated --test regs
vm/run.sh --emulated --test pio      # QEMU codec: vendor_id 0x1af40022
vm/run.sh --emulated --test probe --modparams "ae7_debug=1"
```

In the good `ae7_debug` dump after the probe: `CORB WP 0x0001 RP 0x0001`,
`RIRB WP 0x0001`, `CORB[0..3] 00000000 000f0000 ...` and
`RIRB[0..1] 00000000:00000000 1af40022:00000000` (response:extended, low
nibble of the extended word = codec address).

## Host preparation (one time, then per boot)

1. `sudo host/setup.sh` once. Apply the cmdline change that it prints
   (`pcie_acs_override=downstream,multifunction`, keep `splash` out,
   `amd_iommu=on iommu=pt`), rebuild the initramfs if it says so, reboot with
   the card seated.
2. `host/bind.sh --check` must exit 0 (all AE-7 functions on vfio-pci, IOMMU
   group usable). `host/bind.sh --status` shows the group, the reset method and
   the link state. `run.sh --passthrough` refuses to start if the check fails.
3. `host/capture.sh` for a baseline snapshot (lspci of bridge + card, IOMMU
   groups, dmesg) before any VM run.
4. The stock CTHDA caps already set NO_MSI, so the runs below need no
   `enable_msi=0`. Add it only if a patch changes the driver caps.

## After every passthrough run

- `RESULT:` line of run.sh: it counts IOMMU/AER/vfio lines in the host log.
- `/usr/bin/grep -i -E 'IO_PAGE_FAULT|AER|vfio|iommu' logs/run-NNN*/host-dmesg.txt`
  - `<dev>: AMD-Vi: Event logged [IO_PAGE_FAULT domain=D address=A flags=F]`
    (older kernels print `device=BB:DD.F` inside the brackets): the device is
    the requester ID that the IOMMU saw. `address` is the IOVA,
    which is the guest physical address: compare it with the `sw: CORB ...
    RIRB ...` line of the `ae7_debug` dump. `flags` with bit 0x20 set = write
    (RIRB, position buffer), without = read (CORB, BDL, stream data).
  - Requester = the card (`14:00.0`) and address = RIRB/CORB: the DMA is
    tagged correctly but goes to a bad address (check UBASE/LBASE, NO_64BIT).
  - Requester = the bridge (`13:00.0`), another function, or a BDF that is not
    in the AE-7 group: **DMA alias problem** (hypothesis a). This probably is
    also the bare-metal bug; the fix is a DMA-alias quirk or IVRS override.
  - AER on the root port above the bridge: the bridge saw a bad transaction.
- `serial.log` / `dmesg.txt`: guest side; `lspci-ae7.txt`: guest config space.

## If the host chipset glitches

On bare metal the AE-7 probe killed sibling devices (AHCI with the RAID root,
xHCI). If you see `ahci ... link reset`, `xhci ... HC died`, md degraded or
NVMe timeouts on the host:

1. Stop the run (Ctrl-C; QEMU exits with run.sh). Save `sudo dmesg` and run
   `host/capture.sh` immediately.
2. Reboot the host before the next run. Check `cat /proc/mdstat`; let a
   degraded array resync before more tests.
3. If it happens at QEMU start (no test output in `serial.log` yet), suspect
   the vfio device reset (`host/bind.sh --status` shows the reset method), not
   the guest driver.
4. Use short timeouts (`--timeout 60`) and prefer the low-traffic steps (E1,
   E2, E4) until the cause is known. Keep no unsaved work open: a hard lockup
   needs a power cycle.

## Fast path for hypothesis (W) (run first)

```
vm/run.sh --passthrough --test pio --name w0-pio
vm/run.sh --passthrough --test probe --modparams "ae7_debug=1" --name w1-flush-trapped
vm/run.sh --passthrough --test probe --modparams "flush_writes=0 ae7_debug=1" --name w2-stock-trapped
vm/run.sh --passthrough --mmap --test probe --modparams "ae7_debug=1" --name w3-flush-mmap
vm/run.sh --passthrough --mmap --test play --timeout 180 --name w4-play
```

| Result | Meaning / next |
|---|---|
| w1 PASS, codec `0x1102xxxx` | Codec answers with flushed writes. Go on to w2/w3. |
| w2 PASS too | Trapping alone spaces the writes enough: the wedge needs real timing. w3 is the real test. |
| w2 FAIL (`CORBWP 0xffff`, all-ones in dumps) | Wedge happens even with trapped writes: count-based. Confirms (W) strongly. |
| w3 PASS | Fix works at real timing. Run w4, then port 0002/0003 to the host. |
| w3 FAIL/TIMEOUT | Some burst is still unflushed (check which dump first shows all-ones), or (W) is wrong. Check `host-dmesg.txt`, then the E-series below. |
| w1 FAIL | (W) is not enough here. Use E1-E9 below. |

The E-series below is the full matrix for when the fast path does not settle
it. Patches 0002/0003 are in every run unless `flush_writes=0` is given.

## Experiments

### E1 — registers, no driver

```
vm/run.sh --passthrough --test regs --name e1-regs
```

Isolates: config space and BAR0 MMIO through bridge + VFIO, with no driver.

- PASS, sane GCAP (OSS/ISS 1..15): MMIO works. Note GCAP.64OK (never logged
  on bare metal), GCTL.CRST (state left by firmware) and STATESTS (bit 1 =
  codec at address 1).
- FAIL, GCAP 0xffff: no MMIO. Check the `COMMAND` line (MEM off: rerun with
  `--test-args "--enable-mem"`), the power state (D3hot: check vfio
  `disable_idle_d3`), and `lspci-*.txt` for the BAR. Stop here until fixed.

### E2 — Immediate Command verbs (THE key test)

```
vm/run.sh --passthrough --test pio --name e2-pio
```

Isolates: the codec link with MMIO only (no DMA, no interrupt). The tool
resets the controller, reads STATESTS, then sends GET_PARAMETER vendor-id /
revision / node count, and per function group the subsystem id, GPIO caps and
power state, through IC/IR/ICS.

- `FOUND: codec 1 vendor_id 0x1102....` (PASS, "Creative"): the link and the
  codec work. If E3 then fails, **the DMA path is the problem (a)**. Go to E4
  and E7. The `nid 0x01 AFG subsystem=0x11020081` line confirms the AE-7.
- `no response: ICB stays 1, IRV stays 0`: the codec does not answer even
  without DMA: (b) or (c). Run the variants below, then E6, then the Windows
  trace option at the end.
- `ICB goes to 0 but IRV stays 0`: the controller sent the command but the
  response was lost. Compare `from addr N` (IRRADD) in other runs.
- `STATESTS=0x0000` after reset: no codec signals at all (link/power, b or c).
  A `NOTE: codec(s) ... appear late` line means the kernel (1 ms) misses it.
- ICS/vendor id `0xffff`/`0xffffffff`: the BAR died during the test. Check the
  host log for AER.

Variants: `--test-args "--no-reset"` (use the state that firmware and the vfio
reset left), `--test-args "--all --settle-ms 500 --timeout-ms 500"` (all
addresses, long waits). For manual work: `vm/run.sh --passthrough --test shell
--interactive`, then `python3 -I $REPO/vm/guest/tools/hda-mmio.py BDF verb 1 1
GET_POWER_STATE 0` etc. (`--bar 2 read|write OFF` reaches the ca0113 BAR2).

### E3 — stock driver probe (CTHDA preset)

```
vm/run.sh --passthrough --test probe --modparams "flush_writes=0" --name e3-stock
```

`flush_writes=0` turns off patch 0002, so this is the upstream driver. Keep
the BARs trapped (no `--mmap`) for this run.

Isolates: the full kernel path (CORB/RIRB DMA + INTx) with the correct
upstream preset (`AZX_DCAPS_PRESET_CTHDA`: NO_MSI, POSFIX_LPIB, NO_64BIT,
4K_BDLE_BOUNDARY, SNOOP_OFF).

- PASS, Creative codec: the card works in a VM. The bare-metal failure is then
  host-specific (IOMMU/alias setup); compare host IOMMU config.
- `azx_get_response timeout, switching to polling mode` then `single_cmd
  mode`, or the probe takes minutes: commands get no response through
  CORB/RIRB. Note that `probe_codec` takes `res=0x0` as success (only -1 is a
  failure), which explains the long bare-metal fallbacks. With E2 PASS this is
  (a); go to E4 and E7.

### E4 — single_cmd=1

Low value under (W): the write burst comes before any verb, and an external
report saw `single_cmd=1` hang the same way. Run it only if (W) is ruled out.

```
vm/run.sh --passthrough --test probe --modparams "single_cmd=1" --name e4-single
```

Isolates: the driver with IC/IR for every verb (no CORB/RIRB).

- Codec found: confirms (a) in the real driver. Next: `--test verbs` with the
  same modparams. The ca0132 DSP load (E10) still uses stream DMA reads, so it
  tests the DMA read direction separately.
- Fails while E2 passed: compare the two with `--trace` (E9); the driver does
  something that the tool does not (order, timing, CORB setup before IC).

### E5 — polling (no module parameter)

snd-hda-intel in 7.2 has no `polling_mode` parameter. The driver switches to
polling by itself after the first RIRB timeout (`switching to polling mode` in
E3). Read it with the E7 dump: if the RIRB entry is valid in memory and
`INTSTS`/`RIRBSTS.RINTFL` are set but the driver timed out in IRQ mode and
then succeeded in polling, the INTx path through the bridge (IRQ 255 on the
bridge) is broken, not DMA.

### E6 — probe_mask (codec at address 1)

```
vm/run.sh --passthrough --test probe --modparams "probe_mask=0x102" --name e6-mask-1
vm/run.sh --passthrough --test probe --modparams "probe_mask=0x101" --name e6-mask-0
```

`0x100` forces `codec_mask` to the low bits, whatever STATESTS says. Isolates
an address mismatch (STATESTS bit 1, but the codec answers elsewhere). Use the
E2 `--all` result to pick the address. Add `single_cmd=1` if E4 was needed.

### E7 — ae7_debug dumps (raw CORB/RIRB)

Needs the patch in the guest kernel: `vm/kernel/fetch.sh && vm/kernel/build.sh`
(check: `modinfo -F parm vm/build/modroot/lib/modules/*/kernel/sound/hda/controllers/snd-hda-intel.ko`
lists `ae7_debug`).

```
vm/run.sh --passthrough --test probe --modparams "ae7_debug=1" --name e7-debug
```

Compare the `probe: before command` dump with `RIRB response timeout` /
`probe: response` (`/usr/bin/grep ae7_debug logs/run-NNN*/dmesg.txt`):

| Observation | Meaning |
|---|---|
| `CORB WP 0x0001`, `RP 0x0000` stays | Controller did not fetch the command: CORB DMA read failed or CORB not running (`CTL` without 0x02). `CORB STS 0x01` = memory error. |
| `RP 0x0001`, `RIRB WP 0x0000` stays | Command fetched, no response: codec/link (compare E2). |
| `RIRB WP 0x0001`, `RIRB STS` RINTFL set, `RIRB[1]` = `00000000:00000000` | Controller wrote the response, it did not land in RAM: **DMA write lost (a)**. Look for IO_PAGE_FAULT with the RIRB address. |
| `RIRB[1]` stale (same as before, or the previous response) | Write landed late or cache coherency: try E8 `snoop`. |
| `RIRB[1]` valid (`xxxxxxxx:00000001`), driver timed out | Response is in RAM but not seen: interrupt (INTx) problem, see E5. |
| PCI `STS` has 0x1000/0x2000 (target/master abort) | DMA was aborted at the bridge or IOMMU. |
| All registers `0xffffffff` | Device fell off the bus: check host AER. |

Add `single_cmd=1` to see the `single_cmd response timeout` dumps (IC/IR/ICS).

### E8 — snoop and position_fix

```
vm/run.sh --passthrough --test probe --modparams "ae7_debug=1 snoop=1" --name e8-snoop1
vm/run.sh --passthrough --test probe --modparams "ae7_debug=1 snoop=0" --name e8-snoop0
```

CTHDA sets SNOOP_OFF (write-combined CORB/RIRB and stream buffers). `snoop=1`
uses normal cached buffers. Only useful if E7 shows stale RIRB data. `position_fix` (CTHDA
default 1 = LPIB; 2 = position buffer, which is another DMA write) only
matters for playback (E10): try `position_fix=1` vs `2` if playback stalls.

### E9 — MMIO trace

```
vm/run.sh --passthrough --test pio --trace --timeout 300 --name e9-trace-pio
vm/run.sh --passthrough --test probe --trace --timeout 300 --name e9-trace-probe
```

`--trace` adds `x-no-mmap=on`, so every BAR access goes through QEMU and
`qemu-trace.log` has each `vfio_region_read/write` (BAR, offset, size, value)
plus config and INTx events. Compare the IC sequence of the tool with the
driver's, and with an emulated `--trace` run. Note: the trace makes MMIO slow
and changes timing.

### E10 — if a codec answers: DSP load and playback

External reports: the controller prefetches past the end of the PCM ring. Under
IOMMU translation (always the case with VFIO) that gives host `AMD-Vi
IO_PAGE_FAULT` lines and crackle. Expect it here; it is a separate fix.

```
vm/run.sh --passthrough --test play --timeout 180 --name e10-play
```

(add `single_cmd=1` if E4 was needed). QUIRK_AE7 maps BAR2
(`pci_iomap(pci, 2, 0xC20)`, ca0113 GPIO/commands) and loads `ctefx.bin`
(the host has `/usr/lib/firmware/ctefx.bin.zst`; the guest kernel reads zstd
firmware). The DSP image goes over a stream DMA (read direction): a `DSP load
image failed` with working verbs points at DMA reads. AE-7 mixer notes: check
`amixer -c N contents` for `Output Select` (speaker vs headphone; the AE-7
switches outputs through BAR2 commands, not only pins), the
`AE-5: Headphone Gain` / `AE-5: Sound Filter` controls that QUIRK_AE7 shares,
and unmute `Master`/`Front`. `asound.txt` has the codec widgets.

## Deferred: Windows VM MMIO trace

If E2 also fails (the codec does not answer IC verbs), Windows does something
that Linux does not (hypothesis c). Pass the same functions to a Windows VM
with `vfio-pci,...,x-no-mmap=on` and `-trace enable=vfio_region_write,enable=vfio_pci_write_config`
(run.sh has no Windows mode; it needs its own QEMU line with OVMF and a disk).
Capture the BAR0/BAR2 and config writes of the Creative driver before its
first verb. Replay them in the Linux guest (`hda-mmio.py --bar 2 write ...`,
`setpci` for config) and run `hda-mmio.py BDF probe --no-reset` again.

## Decision summary

| E2 (IC) | E3 (CORB/RIRB) | E7 shows | Conclusion / next |
|---|---|---|---|
| codec answers | PASS | — | Works in VM; bare-metal issue is host IOMMU/alias setup |
| codec answers | fails | RIRB WP moves, RAM zeros / IO_PAGE_FAULT | (a) DMA write lost: alias quirk; meanwhile `single_cmd=1` |
| codec answers | fails | CORB RP does not move | (a) DMA read lost |
| codec answers | fails | RIRB valid, timeout in IRQ mode | INTx broken (E5) |
| no answer | fails | RP moves, no response | (b)/(c): E6, then Windows trace |
| STATESTS 0 | fails | — | Link/power (c): Windows trace |

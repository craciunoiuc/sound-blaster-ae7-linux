# AE-7 Code Anchors — `sound/hda/codecs/ca0132.c` (Linux v7.1.3)

> **Path change in v7.1:** the ca0132 codec moved from
> `sound/pci/hda/patch_ca0132.c` (≤ 6.x) to **`sound/hda/codecs/ca0132.c`** (7.1+)
> as part of the HDA codec split. The `patch_` prefix was dropped. The module name
> is unchanged: `snd-hda-codec-ca0132`. **Edit this file for all patches.**
>
> Line numbers below are verified against the cloned v7.1.3 tree in `kernel/`.
> Re-grep after any `git pull` — they drift across releases.

The card is matched by **PCI subsystem ID `1102:0081` → `QUIRK_AE7`**. The prime
suspect for the boot hang is the **BAR2 MMIO mapping** (`pci_iomap(..., 2, 0xC20)`)
followed by unchecked `writel`/`readl` to that region from the AE-7 init path.

---

## Anchor #1 — PCI ID → quirk mapping (entry point)
```
sound/hda/codecs/ca0132.c:1176   QUIRK_AE7,                  (enum value)
sound/hda/codecs/ca0132.c:1295   static const struct hda_quirk ca0132_quirks[]
sound/hda/codecs/ca0132.c:1314   SND_PCI_QUIRK(0x1102, 0x0081, "Sound Blaster AE-7", QUIRK_AE7),
sound/hda/codecs/ca0132.c:1327   { .id = QUIRK_AE7, .name = "ae7" }   (model= override)
```
**Why it matters:** This is where subsystem `1102:0081` is matched. If your card
revision reports a different subsystem ID, the quirk never matches and the driver
silently falls to `QUIRK_NONE` (no MMIO, no DSP, no sound, no hang — but also no
audio). Verify with: `lspci -nn -d 1102:0081`.

---

## Anchor #2 — Probe / `patch_ca0132()` (~line 9925)
The codec patch entry (`snd_hda_pick_fixup` at 9925 resolves the quirk). Key for
AE-7: it falls into the `use_pci_mmio = true` switch case (alongside
SBZ/R3D/AE5/ZXR), then calls `ca0132_init_chip()` and `ca0132_config()`.

**Instrument here first** to confirm the quirk is actually selected:
```c
codec_info(codec, "AE7DBG: quirk=%d\n", ca0132_quirk(spec));
```

---

## Anchor #3 — BAR2 MMIO mapping (BOOT-CRITICAL) (~line 9994)
```c
if (spec->use_pci_mmio) {
    spec->mem_base = pci_iomap(codec->bus->pci, 2, 0xC20);   /* maps PCI BAR 2 */
    if (spec->mem_base == NULL) {
        codec_warn(codec, "pci_iomap failed! Setting quirk to QUIRK_NONE.");
        codec->fixup_id = QUIRK_NONE;   /* ← silently downgrades! */
    }
}
```
**THE #1 SUSPECT.** If `pci_iomap` succeeds but BAR2 is mis-allocated (resource
not assigned by BIOS / not enabled), every later `writel`/`readl` to
`mem_base + offset` touches an invalid address → hang/fault. Note the *silent*
downgrade to `QUIRK_NONE` on NULL — check whether that fires, or whether a
non-NULL-but-invalid mapping is returned instead. This is why `pci=nommconf` and
`pci=realloc` are the top workarounds.

---

## Anchor #4 — `ca0132_mmio_init()` dispatcher (~line 9295)
```c
static void ca0132_mmio_init(struct hda_codec *codec)   /* line 9295 */
{
    switch (ca0132_quirk(spec)) {
    case QUIRK_R3D: case QUIRK_SBZ: case QUIRK_ZXR:  ca0132_mmio_init_sbz(codec); break;
    case QUIRK_AE5:                                   ca0132_mmio_init_ae5(codec); break;
    default: break;   /* ← AE-7 lands here: NO mmio_init performed */
    }
}
```
**Notable:** the AE-7 maps BAR2 (anchor #3) but does **none** of the
`ca0113_mmio_init_*` register sequences that SBZ/AE5 do. Its BAR2 setup happens
later, lazily, in `ae5_register_set()` and `ae7_setup_defaults()`. If the BAR
isn't ready by then, those writes fault. **Investigate whether AE-7 needs an
explicit `mmio_init` step like AE-5.**

---

## Anchor #5 — DSP firmware download (~line 8511 + 8567)
- `ca0132_download_dsp_images()` (8511): **AE-7 is NOT in the desktop-firmware
  switch** (`QUIRK_SBZ/R3D/AE5` → `ctefx-desktop.bin`). It falls to `default` and
  loads generic **`ctefx.bin`** (defined line 73: `#define EFX_FILE "ctefx.bin"`).
- `dspload_wait_loaded()`: busy-waits up to **2000 ms** polling `chipio_read(0x40004)`.
- `dspio_send()` (~2042): each DSP command retries up to **1000 ms** with `msleep(20)`.

If `ctefx.bin` is missing in the guest, download fails → `DSP_DOWNLOAD_FAILED` →
all `ae7_post_dsp_*` steps are skipped. The guest **needs the `alsa-firmware`
package** (provides `/lib/firmware/ctefx.bin`). Check:
`ls /lib/firmware/ | /usr/bin/grep ctefx`.

---

## Anchor #6 — `ca0132_init()` main runtime init (line 9444)
Call order for AE-7 (read top-to-bottom — the hang happens at one of these):
```c
if (ca0132_use_pci_mmio(spec))
    ca0132_mmio_init(codec);              /* no-op for AE-7 (anchor #4) */

if (QUIRK_AE5 || QUIRK_AE7)
    ae5_register_set(codec);              /* ← FIRST BAR2 writes; AE-7 branch */

ca0132_init_params(codec);
ca0132_init_flags(codec);
snd_hda_sequence_write(codec, spec->base_init_verbs);

if (ca0132_use_alt_functions(spec))
    ca0132_alt_init(codec);

ca0132_download_dsp(codec);               /* anchor #5 */

case QUIRK_AE7:
    ae7_setup_defaults(codec);            /* anchor #7 — heavy BAR2 use */
```
**`ae5_register_set()` (line 9328) is the first place a bad BAR2 mapping will
fault.** Add `codec_info("AE7DBG: before/after ae5_register_set")` to bracket it.

---

## Anchor #7 — AE-7 specific functions (audit set)
```
ca0132.c:1281   ae7_pincfgs[]                     pin configuration
ca0132.c:746    ae7_ca0113_output_presets         output routing
ca0132.c:1487   { .quirk_id = QUIRK_AE7, ... }     output-selection metadata
ca0132.c:8365   ae7_setup_defaults()              post-DSP setup (heavy BAR2 use)
ca0132.c:~8050  ae7_post_dsp_setup_ports()
ca0132.c:~8071  ae7_post_dsp_asi_stream_setup()
ca0132.c:~8094  ae7_post_dsp_pll_setup()
ca0132.c:~8108  ae7_post_dsp_asi_setup_ports()
ca0132.c:~8190  ae7_post_dsp_asi_setup()
```
All `ae7_post_dsp_*` run **only after a successful DSP download**; if download
fails they're skipped — useful when reading a partial boot log to know how far
init got.

---

## Anchor #8 — Helper writers (every BAR2 access funnels here)
```
ca0132.c:3630   ca0113_mmio_gpio_set()
ca0132.c:3650   ca0113_mmio_command_set()
ca0132.c:3689   ca0113_mmio_command_set_type2()
```
All dereference `spec->mem_base + offset` with **no NULL check** — they assume
anchor #3 succeeded. A fault in any of these = BAR2 problem.

---

## Debugging instrumentation (iteration zero)

The first patch to apply (`patches/0001-ae7-debug-instrumentation.patch`) adds
`AE7DBG:` lines at each step above. The hang point (last `AE7DBG` line before
silence) tells you exactly which anchor to patch next:

| Last AE7DBG line seen | Meaning | Next thing to try |
|---|---|---|
| `before mmio_init` | hangs in dispatcher or BAR2 setup | `pci=nommconf` / `pci=realloc` in guest `-append` |
| `after pci_iomap, mem_base=0x0` | BAR2 map failed → silent QUIRK_NONE | BIOS/PCI resource issue; check `lspci -vvv` for the BAR |
| `before ae5_register_set` | first BAR2 write faults | BAR2 not ready; add explicit `mmio_init_ae7()` |
| `before download_dsp` | DSP handshake wedged | check `ctefx.bin` present in guest |
| `DSP_DOWNLOAD_FAILED` | firmware missing or rejected | install `alsa-firmware` in guest |
| `before ae7_setup_defaults` | post-DSP BAR2 write faults | same as ae5_register_set; BAR2 region issue |
| reaches login prompt | **boot hang fixed** → now debug audio output | mute IEC958 in alsamixer; set analog default |

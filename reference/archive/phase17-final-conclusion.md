# Final conclusion — the bridge cannot forward HDA verbs

**Date:** 2026-07-16

## Summary

After extensive instrumentation and multiple fix attempts, the AE-7's core
problem is definitively identified: **the ASMedia ASM1083/1085 PCIe-to-PCI
bridge cannot forward HDA CORB/RIRB command traffic to the CA0132 codec under
Linux.** The codec is physically detected during bus reset (passive STATESTS),
but active command/response always returns `res=0x0`.

This was tested across 5+ builds with every software-side variable changed:
- Generic vs CTHDA driver caps
- MSI vs INTX interrupts
- Serialized vs concurrent probe
- 32-bit vs 64-bit DMA
- Snoop-on vs snoop-off (cached vs uncached DMA buffers)

`res=0x0` in every case. The card works in Windows, meaning the hardware is
capable — but Windows' driver handles the bridge differently (likely programs
the bridge's translation windows or uses a different codec discovery path).

## What WAS fixed (real, upstreamable bugs)

1. **MSI allocation hang** (`pci_alloc_irq_vectors` with `PCI_IRQ_MSI` never
   returns through the bridge). Fix: `snd_hda_intel.enable_msi=0`, or add the
   device to the `msi_deny_list`.
2. **Concurrent-probe hard lockup** (two PCI functions probing simultaneously
   through the bridge cause a CPU wedge). Fix: serialize `azx_probe_continue`
   with a mutex.
3. **Plymouth (`splash`) conflicts** with the bridge during early KMS init.

These are documented in the patch files and worth submitting upstream.

## Why it can't be fixed in software

The CORB (command outbox) → codec → RIRB (response inbox) path requires the
bridge to translate HDA bus cycles. The codec pulls STATESTS during reset
(hardware line, works), but the bridge doesn't forward the memory-mapped
CORB/RIRB DMA traffic. This is a bridge firmware/silicon limitation.

Windows works because its HDA stack either:
- Programs the bridge's base/limit registers differently before probing
- Uses immediate commands (PIO/single-cmd) instead of CORB/RIRB
- Initializes the codec via a vendor-specific path

Without capturing Windows' bridge register writes, replicating it in Linux
would require reverse-engineering Creative's driver.

## Path forward: VFIO passthrough to Windows

The card works in Windows. Pass it through:
1. Host: keep `snd_hda_intel` blacklisted, bind AE-7 to `vfio-pci`
2. Guest: Windows VM with the AE-7 passed through
3. The `enable_msi=0` + serialization findings may still be relevant for
   host-side VFIO setup (the bridge still needs to be enumerated)

See the original project plan (PLAN.md) and host/ scripts.

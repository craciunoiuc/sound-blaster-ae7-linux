# Patches

This directory holds the iteration patches against `kernel/sound/hda/codecs/ca0132.c`.

## Naming convention

```
NNNN-short-description.patch
```

- `NNNN` — four-digit sequence number, zero-padded. Monotonic; never reuse.
- `0001` is always the debug instrumentation scaffold (applied first, kept applied).
- `0002+` are fix attempts. Each should be independently revertible.

## Applying

```bash
# Apply a single patch on top of the clean v7.1.3 tree:
git -C kernel/ apply patches/0001-ae7-debug-instrumentation.patch

# Check it will apply before running it (no changes made):
git -C kernel/ apply --check patches/NNNN-foo.patch

# Revert:
git -C kernel/ apply -R patches/NNNN-foo.patch
```

> The patches are generated against the **v7.1.3** tag with `git diff`, so they
> are real unified diffs (no fake blob hashes). They apply with `git apply` (no
> need for `patch -p1`). If a patch stops applying after a `git pull`, regenerate
> it from a fresh edit + `git diff`.

## Generating a new patch

1. Start from a clean tree: `git -C kernel/ checkout -- sound/hda/codecs/ca0132.c`
   (keep `0001` applied — re-apply it if you reset).
2. Edit `kernel/sound/hda/codecs/ca0132.c`.
3. `git -C kernel/ diff -- sound/hda/codecs/ca0132.c > patches/NNNN-desc.patch`
4. Prepend a header (From/Subject/description) — see `0001` for the format.
5. Verify: `git -C kernel/ apply --check patches/NNNN-desc.patch`

## Iteration log format

Every run gets an entry in `logs/STATUS.md` (created on first run):

```
## run-NNN  <date>
- patches applied: 0001, 0002-...
- guest cmdline: root=/dev/vda1 ... [extra APPEND]
- outcome: boot-to-login | hang | panic
- hang point: <last AE7DBG line or stack trace>
- next hypothesis: <what to change in the next patch>
```

This is the project's memory across agents and sessions. Always append after a
run, even if nothing changed — a null result still narrows the search.

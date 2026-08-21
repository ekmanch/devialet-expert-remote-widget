# Source index-to-name mapping: real-device finding (2026-08-21)

Real-device testing during the Rust daemon/CLI's Phase 1 verification (see
CLAUDE.md) surfaced a divergence between what `protocol.md` and the
original Kotlin app's `SOURCE_COMMAND_VALUE` comments assumed about source
*names*, and what a real amp actually broadcasts. This doc records the
test, the result, and what it does/doesn't mean for the protocol.

## What was assumed

`docs/protocol.md`'s "Source selection encoding" table, and the comments in
`DevialetController.kt`'s `SOURCE_COMMAND_VALUE` map it was transcribed
from, associate each status-broadcast index with a specific source name:

| Status index | Assumed name (protocol.md / Kotlin comments) |
|---|---|
| 0 | Optical 1 |
| 1 | Phono *(hardcoded-byte special case, not in the map)* |
| 2 | UPnP |
| 3 | Roon Ready |
| 4 | AirPlay |
| 5 | Spotify |
| 14 | Air (Bluetooth) |

These names were never independently verified against a live broadcast -
they're comments the original developer wrote describing their own amp's
configuration at the time `SOURCE_COMMAND_VALUE` was written.

## What this amp actually transmits

A real status broadcast captured from a Devialet Expert Pro 140 ("My
Devialet-ETH", 192.168.0.22) during this testing session:

| Status index | Enabled | Name actually broadcast |
|---|---|---|
| 0 | yes | Optical 1 |
| 1 | yes | **UPnP** |
| 2 | yes | **Roon Ready** |
| 3 | yes | **AirPlay** |
| 4 | yes | **Spotify** |
| 5 | no | *(disabled)* |
| 6-13 | no | *(disabled)* |
| 14 | yes | Air |
| 15-29 | no | *(disabled)* |

Every enabled name is shifted down by one slot relative to the assumed
table, and **"Phono" does not appear anywhere in this amp's 30 slots**,
enabled or disabled.

Everything else in `protocol.md`'s status packet layout (device name at
offset 19/31 bytes, source table stride `52 + i*17`, power/mute bits at
562/563, volume formula at 565) matched this real amp's broadcast exactly,
byte-for-byte, across 84 consecutive real packets with zero parse
failures - only the source *name* labels diverged.

## The test that resolved which case this is

Two explanations were possible going in:

1. **Fixed hardware slot, stale label**: the index->command-value mapping
   is a firmware-level association with a physical/logical input slot,
   correct and portable across amps; only the *name* documented for each
   slot is specific to one reference configuration.
2. **Genuinely per-unit/configurable**: the index->command-value
   association itself doesn't generalize, and no static table should be
   trusted at all.

To distinguish them: sent `devialet-ctl --ip 192.168.0.22 source 1` - the
hardcoded Phono-labeled bytes (`0x3F 0x80`) - to this amp, and read back
its own status broadcast afterward.

**Baseline** (before): `ActiveSourceIndex=2`, `ActiveSourceName="Roon Ready"`

**After sending `source 1`**: `ActiveSourceIndex=1`, `ActiveSourceName="UPnP"`,
`VolumeDb=-40` (confirming the forced post-switch volume also fired)

The command correctly, deterministically selected status index 1 on this
amp - not some unrelated index, not a no-op. That's case 1: the mapping
(index -> wire bytes) is confirmed correct and portable; the name "Phono"
attached to index 1 in the documentation was simply the name on the
original reference amp's own configuration, and is not universal.

## Conclusion

- **Do not correct the index->command-value mapping** - it's confirmed
  working as-is, including the index-1 hardcoded-byte special case.
- **Do not hardcode corrected source names anywhere** - per-slot names are
  confirmed per-unit/configuration-dependent, not a protocol constant. The
  live status broadcast (`Status.sources`, from every status packet) is
  the only authoritative source of names, and was already the only source
  of truth used for display anywhere in this repo's Rust code (confirmed
  by inspection - no crate in this repo hardcodes a source name keyed by
  index).
- The original Kotlin app has the same underlying characteristic: its UI
  always displays the live broadcast name (never a hardcoded label), but
  `DevialetController.selectSource()`'s dispatch is keyed purely by
  tapped-row index, with no cross-check against the name shown. On an amp
  configured like this one, tapping the row labeled "UPnP" would send the
  same hardcoded Phono-labeled bytes that were just confirmed here - not a
  bug introduced by this port, a pre-existing characteristic of the
  original index-keyed design that this testing happened to surface.
- `docs/protocol.md`'s source-index table is corrected below to describe
  this properly rather than asserting fixed names.

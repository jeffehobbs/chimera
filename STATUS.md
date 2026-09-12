# Status — 2026-09-12

Paused here deliberately. Everything below is verified by opening the file in Logic Pro 12.3.1,
not by the test suite, because the suite cannot see this class of bug (see *The gap in testing*).

## Where it stands

**All thirteen strategies produce a project Logic opens.** Verified one strategy at a time
against `contra.logicx` as host and `air.logicx` as donor, with the untouched host opened first
to establish the baseline.

Three real bugs were found and fixed getting here, each with its own fingerprint in Logic's
wording:

| Bug | What Logic said | Fixed in |
|---|---|---|
| Region windows drifting past the end of their source file | "Project may be damaged" **plus** "One or multiple audio files changed in length!" | `6e41ba9` |
| `renumber()` rebuilding the `+8` header field, which is a reference and not a counter | bare "Project may be damaged", on **every** output including a zero-strategy copy | `20a6151` |
| Added track units colliding with existing tracks on `+8` | bare "Project may be damaged", only when a strategy *adds* tracks | `ed3e05a` |

The middle one is why nothing worked at all: `renumber()` ran on every write and rewrote ~78% of
a project's records, so even a copy with no strategies applied was refused.

## What is not done

**Grafted and zipped tracks arrive with no instrument.** A `TrackUnit` is `MSeq` + `Trak` +
`EvSq` and carries no mixer records, so donor tracks reference channel strips the host does not
have. The arrangement is right; the sound is missing.

The lead, not yet followed: `Trak` records come in two payload sizes, 0 and 57 bytes. The 57-byte
ones carry a u32 at **payload+8** whose values are 72, 80, 88, 92, 96, 100, 104 — all multiples
of 4 — while `id2` acts as that track's sub-index. That is very likely the channel reference,
against 70 `AuCU` and 289 `AuCO` records in `contra`. Fixing it means carrying the donor's
`AuCU`/`AuCO` chain across and rewriting the reference to its new home. That is a reverse
engineering session of the same shape as the `+8` work, and it belongs in `logic-discovery`
before it lands here.

**Region Drift is bounded more tightly than it should be.** A region may only roam the span it
already referenced, because that is the only part of its source file we can prove exists.
Decoding the `AuRg`-to-`AuFl` link would let it use the file's real length. Note that `AuRg`
carries no u32 that is constant per source file and unique across files — the obvious probe
comes up empty, so this needs a different approach.

**`unexpectedConstants(at: 24)`** — several projects in the iCloud corpus fail to parse, and the
CLI dies with a Swift fatal error rather than a usable message. Both worth fixing; the crash
especially.

## The gap in testing

Neither harness can catch any of the three bugs above.

* `roundtrip` proves the payload writers do not move bytes they should not. It never calls
  anything the write path calls.
* `selftest`'s "parses back" proves our own reader accepts our own writer's output. A project
  with every reference field wrecked passes this without complaint.

Two cheap assertions would have caught two of the three in seconds, and both are still unwritten:

1. A zero-strategy copy must be **byte-identical** to its input. This catches `renumber()`
   immediately.
2. No two track units may share a `+8` value beyond the multiplicity the host already had. This
   catches the collision bug.

Opening in Logic remains the only real test and no script can do it.

## How to test

```bash
./build.sh cli
./build/chimera-cli roundtrip <corpus>    # byte-identical rewrite of every name
./build/chimera-cli selftest  <corpus>    # every strategy x every project
```

Then open the result in Logic, which is the part that counts.

* Clean corpus: `~/Library/Mobile Documents/com~apple~CloudDocs/Logic` — 59 projects. Some are
  iCloud placeholders sitting at 0B, and a few hit the parse error above.
* **Open the untouched host in Logic first.** `Trump 1.logicx` in the OneDrive corpus is itself
  damaged and cost hours before anyone checked it.
* Logic's "last selected audio interface" and "missing Sound Library file" dialogs are unrelated
  noise. "Project may be damaged" is not — never wave that one off.

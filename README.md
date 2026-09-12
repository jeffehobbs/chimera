# Chimera

A Mac app that folds Logic Pro projects into each other. Give it a host project, some donors,
and a chain of strategies, and it writes out a new `.logicx` bundle that is part one song and
part another — a different tempo derived from both, tracks interleaved, regions convolved,
plug-in state dealt to the wrong channels, or the raw bytes of two projects braided together.

It works by reading and rewriting `ProjectData`, Logic's undocumented project stream. The format
is documented in [`~/Scripts/logic-discovery`](../logic-discovery/FORMAT.md); this app is what
that reverse engineering was for.

**All thirteen strategies produce a project that opens in Logic Pro 12.3.1**, each verified by
hand, one strategy at a time, against a host opened untouched first. That last part matters: for
a while this claim rested on the output parsing back through its own reader, which a wrecked
project passes happily. Only opening it in Logic counts.

Two known limits. Tracks brought in by **Track Graft** and **Track Zipper** arrive without their
instruments — a track unit carries no mixer records, so donor tracks point at channel strips the
host doesn't have. And **Byte Weave** will make Logic complain about plug-in state, which is the
strategy doing exactly what it says.

## The strategies

Grouped by how far they travel from being a project.

**Gentle** — field values only; the record stream keeps its shape.

| | |
|---|---|
| **Tempo Fold** | One tempo derived from all the projects: their mean, their geometric mean, the *beat frequency* between them, their ratio, the donor's outright, or the host times φ. |
| **Signature Warp** | Re-bars the project — the donor's meter, an odd one (5, 7, 11, 13), or a halved bar. |
| **Region Drift** | Slides every audio region's window along its own source file. The arrangement holds its shape; every region plays something else. |
| **Region Convolution** | Treats both projects' region durations as signals and convolves them, so each region's length carries a trace of the entire donor. Rescales to hold the total span. |
| **Name Transplant** | Donor names, shuffled names, or halves of both projects' names spliced together. |

**Rough** — tracks reordered, repeated or thrown away.

| | |
|---|---|
| **Track Palindrome** | Reverses the track list. Optionally mirrors it, so it reads the same both ways. |
| **Track Stutter** | Repeats tracks in place — a channel-strip echo rather than a delay. |
| **Dropout** | Deletes a share of one kind of record: plug-in state, mixer objects, metadata, regions, or whole tracks. The project keeps its shape and loses its memory. |
| **Plug-in Scramble** | Deals every channel's plug-in state out to a different channel. Same-size-only by default, which keeps it sane; cross-project if you want it not to be. |
| **Media Transplant** | Repoints the host's audio references at the donors' audio and copies those files in. Same arrangement, different sound entirely. |

**Feral** — records and raw bytes cross between projects.

| | |
|---|---|
| **Track Graft** | Lifts whole tracks out of the donors and appends them. The most literal hybrid. |
| **Track Zipper** | Interleaves host and donor tracks one for one, at a stride you choose. |
| **Byte Weave** | Every Nth byte of a record comes from the other project's record of the same kind. Lengths are preserved, so the stream still parses; what it means is anyone's guess. |

Strategies compose — the app runs them as an ordered chain against one project, so "graft their
tracks, fold the tempos, then scatter every region" is three steps and not a special case.

## Using it

```bash
./build.sh run      # build and launch
```

Drop `.logicx` bundles into the left column. The first becomes the **host** — the project
everything else is folded into — and the rest are donors; double-click any other to promote it.
Build a chain in the middle column, set a seed, press **Make** (⌘↩). Results land in
`~/Desktop/Chimera` and show up on the right with what happened to them and a link straight into
Logic.

The seed makes it reproducible: the same pool, chain and seed always give the same hybrid. The
`1×` stepper runs a batch, walking the seed forward, so one press gives you a family.

The **Gentle / Rough / Feral** control is a ceiling, not a mode — steps above it are skipped and
struck through, so you can build one big chain and dial how far it goes.

## The command line

Same engine, no window, which is how the strategies are actually tested.

```bash
./build.sh cli
./build/chimera-cli list                       # every strategy and its parameters
./build/chimera-cli info      A.logicx
./build/chimera-cli run       --host A.logicx --donor B.logicx \
                              --strategy track-zipper,tempo-fold --seed 12 --out ./out
./build/chimera-cli roundtrip <corpus-dir>     # rewriting every name to itself must be byte-identical
./build/chimera-cli selftest  <corpus-dir>     # every strategy × every project, re-parsed
```

`./build.sh check` runs the selftest against `$CORPUS`.

## Safety

* Inputs are opened **read-only**. Every output is a fresh bundle; nothing is ever written back
  into a source project.
* Nothing reaches the disk until the mutated stream has been **parsed back** by the same reader
  that produced it, and the finished bundle is re-read off disk afterwards. The results list says
  so per hybrid.
* Logic's own `Project File Backups/` are dropped from the copy — they would still hold the
  unmutated project and only confuse a hybrid.
* Your source projects live in OneDrive. Chimera does not touch them, but a hybrid you like is
  worth moving somewhere you control.

## Testing without clicking

A window cannot be driven from a script, so two things are in the launch environment:

```bash
CHIMERA_CORPUS=~/path/to/songs CHIMERA_CHAIN=tempo-fold,track-zipper open build/dd/.../Chimera.app
```

`CHIMERA_CORPUS` fills the pool from a folder; `CHIMERA_CHAIN` preloads a chain by strategy id.

## Layout

```
Sources/Core/     the engine — LogicFormat, LogicBundle, Strategy, Strategies, Chimerizer
Sources/Mac/      SwiftUI, ~600 lines
Sources/CLI/      the headless driver
Tools/make_icon.py  draws the icon: two waveforms braided, which is what Byte Weave does
```

`Sources/Core` knows nothing about AppKit and is compiled into both targets verbatim.

## One thing worth knowing

The bug that cost the most: name fields are **UTF-8 with a byte count**, and the field is padded
to an **even** width. Rewriting a name to a different length without the pad shifts every field
after it by one byte, and Logic reports that as *"The song you are trying to open is corrupted"* —
not as a bad name. `chimera-cli roundtrip` exists to catch exactly that: rewrite every name to the
name it already has, and the file must come out byte-identical.

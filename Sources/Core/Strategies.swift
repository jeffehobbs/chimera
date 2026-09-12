//  Strategies.swift
//
//  Thirteen ways to fold Logic projects into each other, ordered here the way
//  they are in the picker: the ones that leave a working project first, the ones
//  that treat the file as raw material last.

import Foundation

// MARK: - Tempo Fold  (gentle)

/// Two songs have two tempos and there is no reason to prefer either. This takes
/// a third number from both of them — including the one nobody asks for, the
/// *beat frequency*, which is what you get when two close tempos are heard at
/// once and is almost always far slower than either.
enum TempoFold: MutationStrategy {
    static let id = "tempo-fold"
    static let title = "Tempo Fold"
    static let blurb = "Derives one tempo from the host and the donors — their mean, their geometric mean, the beat frequency between them, their ratio, or the donor's outright."
    static let fidelity = Fidelity.gentle
    static let needsDonor = false
    static let parameters: [StrategyParameter] = [
        .init(id: "mode", label: "Fold", help: "How the tempos combine.",
              kind: .choice(options: ["Mean", "Geometric", "Beat frequency", "Ratio", "Donor", "Golden"], start: 0)),
        .init(id: "blend", label: "Blend", help: "0 keeps the host's tempo, 1 takes the folded value outright.",
              kind: .amount(min: 0, max: 1, start: 1)),
    ]

    static func apply(_ ctx: inout MutationContext, _ p: ParameterValues) {
        let host = ctx.project.tempo
        guard host > 0 else { return }
        let others = ctx.donors.map(\.tempo).filter { $0 > 0 }
        let donor = others.isEmpty ? host : others.reduce(0, +) / Double(others.count)

        let folded: Double
        switch p.choice("mode") {
        case 1: folded = (host * donor).squareRoot()
        // The tempos beat against each other; the difference is the pulse you
        // actually hear. Doubled twice so it lands somewhere playable.
        case 2: folded = { let d = abs(host - donor); return d < 1 ? host / 2 : d * 4 }()
        case 3: folded = host * (donor / host).squareRoot()
        case 4: folded = donor
        case 5: folded = host * 1.6180339887
        default: folded = (host + donor) / 2
        }
        let blend = p.number("blend", 1)
        let final = host + (folded - host) * blend
        ctx.project.setTempo(final)
        ctx.note(String(format: "Tempo %.3f → %.3f BPM", host, ctx.project.tempo))
    }
}

// MARK: - Signature Warp  (gentle)

/// The denominator is stored as an exponent, so only powers of two exist here —
/// which is the format's opinion, not ours.
enum SignatureWarp: MutationStrategy {
    static let id = "signature-warp"
    static let title = "Signature Warp"
    static let blurb = "Re-bars the project. Takes the donor's time signature, or an odd meter chosen by the seed."
    static let fidelity = Fidelity.gentle
    static let parameters: [StrategyParameter] = [
        .init(id: "mode", label: "Meter", help: "Where the new bar length comes from.",
              kind: .choice(options: ["Donor's", "Odd (5, 7, 11, 13)", "Host numerator, halved bar", "Random"], start: 0)),
    ]

    static func apply(_ ctx: inout MutationContext, _ p: ParameterValues) {
        let (hn, hd) = ctx.project.timeSignature
        var num = hn, den = hd
        switch p.choice("mode") {
        case 1: num = [5, 7, 11, 13][ctx.rng.int(0..<4)]; den = hd
        case 2: num = hn; den = min(hd * 2, 64)
        case 3: num = ctx.rng.int(2..<14); den = [2, 4, 8, 16][ctx.rng.int(0..<4)]
        default:
            if let d = ctx.donors.first { (num, den) = d.timeSignature }
        }
        ctx.project.setTimeSignature(numerator: num, denominator: den)
        let now = ctx.project.timeSignature
        ctx.note("Signature \(hn)/\(hd) → \(now.numerator)/\(now.denominator)")
    }
}

// MARK: - Region Drift  (gentle)

/// Regions point into their audio file by start and length. Move those and every
/// region plays a different part of the same sound — the arrangement is untouched,
/// the content is not.
enum RegionDrift: MutationStrategy {
    static let id = "region-drift"
    static let title = "Region Drift"
    static let blurb = "Slides each audio region's window along its own source file, so the arrangement holds its shape but every region plays something else."
    static let fidelity = Fidelity.gentle
    static let parameters: [StrategyParameter] = [
        .init(id: "amount", label: "Reach", help: "How far a region may slide, as a multiple of its own length.",
              kind: .amount(min: 0, max: 8, start: 1.5)),
        .init(id: "odds", label: "Odds", help: "The chance any given region moves at all.",
              kind: .amount(min: 0, max: 1, start: 0.75)),
        .init(id: "squeeze", label: "Squeeze", help: "Scales every region's length. 1 leaves it alone.",
              kind: .amount(min: 0.05, max: 4, start: 1)),
        .init(id: "swap", label: "Trade windows", help: "Instead of sliding, deal the existing start/length pairs out to different regions.",
              kind: .flag(start: false)),
    ]

    static func apply(_ ctx: inout MutationContext, _ p: ParameterValues) {
        let idx = ctx.project.indices(ofTag: "AuRg")
        guard !idx.isEmpty else { ctx.note("No audio regions to drift."); return }
        let reach = p.number("amount", 1.5), odds = p.number("odds", 0.75), squeeze = p.number("squeeze", 1)
        var moved = 0

        if p.flag("swap") {
            let extents = idx.compactMap { ctx.project.records[$0].regionExtent }
            guard extents.count == idx.count else { return }
            let dealt = ctx.rng.shuffled(extents)
            for (n, i) in idx.enumerated() where ctx.rng.chance(odds) {
                ctx.project.records[i].setRegionExtentClamped(start: dealt[n].start, length: max(1, dealt[n].length * squeeze))
                moved += 1
            }
        } else {
            for i in idx {
                guard let e = ctx.project.records[i].regionExtent, ctx.rng.chance(odds) else { continue }
                let drift = (ctx.rng.unit() * 2 - 1) * reach * e.length
                ctx.project.records[i].setRegionExtentClamped(start: e.start + drift,
                                                              length: max(1, e.length * squeeze))
                moved += 1
            }
        }
        ctx.note("Drifted \(moved) of \(idx.count) regions.")
    }
}

// MARK: - Region Convolution  (gentle)

/// The one that earns the word. Region lengths are a sequence; so are the
/// donor's. Convolve them and every region's duration carries a trace of the
/// whole other project, then rescale so the piece keeps its total span.
enum RegionConvolution: MutationStrategy {
    static let id = "region-convolution"
    static let title = "Region Convolution"
    static let blurb = "Treats both projects' region durations as signals and convolves them, so each region's length carries a trace of the entire donor."
    static let fidelity = Fidelity.gentle
    static let needsDonor = true
    static let parameters: [StrategyParameter] = [
        .init(id: "wet", label: "Wet", help: "0 keeps the host's durations, 1 is the convolution outright.",
              kind: .amount(min: 0, max: 1, start: 0.8)),
        .init(id: "preserve", label: "Hold total length", help: "Rescale afterwards so the sum of all durations is unchanged.",
              kind: .flag(start: true)),
    ]

    static func apply(_ ctx: inout MutationContext, _ p: ParameterValues) {
        let idx = ctx.project.indices(ofTag: "AuRg")
        let kernel = ctx.donors.flatMap { d in d.indices(ofTag: "AuRg").compactMap { d.records[$0].regionExtent?.length } }
        guard !idx.isEmpty, !kernel.isEmpty else { ctx.note("Convolution needs regions on both sides."); return }

        let host = idx.compactMap { ctx.project.records[$0].regionExtent?.length }
        guard host.count == idx.count else { return }
        // Normalized so the kernel contributes shape, not scale.
        let kSum = kernel.reduce(0, +)
        let k = kernel.map { $0 / kSum }

        var convolved = [Double](repeating: 0, count: host.count)
        for n in host.indices {
            for (m, kv) in k.enumerated() {
                convolved[n] += host[(n - m + host.count * (m / host.count + 1)) % host.count] * kv
            }
        }
        if p.flag("preserve", true) {
            let a = host.reduce(0, +), b = convolved.reduce(0, +)
            if b > 0 { convolved = convolved.map { $0 * a / b } }
        }
        let wet = p.number("wet", 0.8)
        for (n, i) in idx.enumerated() {
            guard let e = ctx.project.records[i].regionExtent else { continue }
            let length = e.length + (convolved[n] - e.length) * wet
            ctx.project.records[i].setRegionExtentClamped(start: e.start, length: max(1, length))
        }
        ctx.note("Convolved \(host.count) regions against a \(k.count)-tap kernel.")
    }
}

// MARK: - Name Transplant  (gentle)

enum NameTransplant: MutationStrategy {
    static let id = "name-transplant"
    static let title = "Name Transplant"
    static let blurb = "Moves track and region names across from the donors, shuffles them, or splices halves of both projects' names together."
    static let fidelity = Fidelity.gentle
    static let parameters: [StrategyParameter] = [
        .init(id: "mode", label: "Source", help: "Where the new names come from.",
              kind: .choice(options: ["Donor's names", "Shuffle the host's", "Splice both halves"], start: 0)),
        .init(id: "regions", label: "Rename regions too", help: "Otherwise only tracks, folders and lanes are renamed.",
              kind: .flag(start: true)),
    ]

    static func apply(_ ctx: inout MutationContext, _ p: ParameterValues) {
        func pool(_ projects: [LogicProject], tag: String, read: (LogicRecord) -> String?) -> [String] {
            projects.flatMap { pr in pr.indices(ofTag: tag).compactMap { read(pr.records[$0]) } }
                .filter { !$0.isEmpty }
        }
        let mode = p.choice("mode")
        var renamed = 0

        func rewrite(tag: String, read: @escaping (LogicRecord) -> String?, write: @escaping (inout LogicRecord, String) -> Void) {
            let idx = ctx.project.indices(ofTag: tag)
            guard !idx.isEmpty else { return }
            let mine = pool([ctx.project], tag: tag, read: read)
            let theirs = pool(ctx.donors, tag: tag, read: read)
            let source: [String]
            switch mode {
            case 1: source = ctx.rng.shuffled(mine)
            case 2:
                let a = ctx.rng.shuffled(mine), b = ctx.rng.shuffled(theirs.isEmpty ? mine : theirs)
                source = a.indices.map { i -> String in
                    let x = a[i], y = b[i % b.count]
                    // Half of one name grafted onto half of another.
                    return String(x.prefix(max(1, x.count / 2))) + String(y.suffix(max(1, y.count / 2)))
                }
            default: source = theirs.isEmpty ? ctx.rng.shuffled(mine) : theirs
            }
            guard !source.isEmpty else { return }
            for (n, i) in idx.enumerated() where read(ctx.project.records[i]) != nil {
                write(&ctx.project.records[i], source[n % source.count])
                renamed += 1
            }
        }

        rewrite(tag: "MSeq", read: { $0.sequenceName }, write: { $0.setSequenceName($1) })
        if p.flag("regions", true) {
            rewrite(tag: "AuRg", read: { $0.regionName }, write: { $0.setRegionName($1) })
        }
        ctx.note("Renamed \(renamed) sequences and regions.")
    }
}

// MARK: - Track Palindrome  (rough)

enum TrackPalindrome: MutationStrategy {
    static let id = "track-palindrome"
    static let title = "Track Palindrome"
    static let blurb = "Reverses the order of every track, folder and automation lane in the arrangement — the same project read from the bottom up."
    static let fidelity = Fidelity.rough
    static let parameters: [StrategyParameter] = [
        .init(id: "mirror", label: "Mirror", help: "Append the reversal to the original instead of replacing it, so the track list reads the same both ways.",
              kind: .flag(start: false)),
    ]

    static func apply(_ ctx: inout MutationContext, _ p: ParameterValues) {
        let units = ctx.project.trackUnits()
        guard units.count > 1 else { return }
        let out = p.flag("mirror") ? units + units.reversed() : units.reversed()
        ctx.project.replaceTrackUnits(with: Array(out))
        ctx.note("Reversed \(units.count) track units\(p.flag("mirror") ? " and mirrored them" : "").")
    }
}

// MARK: - Track Stutter  (rough)

enum TrackStutter: MutationStrategy {
    static let id = "track-stutter"
    static let title = "Track Stutter"
    static let blurb = "Repeats each track in place, so one track becomes a stack of identical ones — a channel strip echo rather than a delay."
    static let fidelity = Fidelity.rough
    static let parameters: [StrategyParameter] = [
        .init(id: "times", label: "Repeats", help: "How many copies of each track to leave behind.",
              kind: .count(min: 2, max: 8, start: 2)),
        .init(id: "odds", label: "Odds", help: "The chance any given track stutters.",
              kind: .amount(min: 0, max: 1, start: 0.5)),
    ]

    static func apply(_ ctx: inout MutationContext, _ p: ParameterValues) {
        let units = ctx.project.trackUnits()
        guard !units.isEmpty else { return }
        let times = max(2, p.count("times", 2)), odds = p.number("odds", 0.5)
        var out: [TrackUnit] = []
        var stuttered = 0
        for u in units {
            if ctx.rng.chance(odds) {
                out.append(contentsOf: Array(repeating: u, count: times)); stuttered += 1
            } else {
                out.append(u)
            }
        }
        ctx.project.replaceTrackUnits(with: out)
        ctx.note("Stuttered \(stuttered) of \(units.count) tracks ×\(times) — now \(out.count) units.")
    }
}

// MARK: - Dropout  (rough)

/// Controlled subtraction. Removing mixer and metadata records rather than
/// tracks tends to leave a project that still plays but has forgotten how it
/// was supposed to sound.
enum Dropout: MutationStrategy {
    static let id = "dropout"
    static let title = "Dropout"
    static let blurb = "Deletes a share of the records of one kind — mixer objects, plug-in state, metadata — so the project keeps its shape and loses its memory."
    static let fidelity = Fidelity.rough
    static let parameters: [StrategyParameter] = [
        .init(id: "target", label: "Lose", help: "Which kind of record to thin out.",
              kind: .choice(options: ["Plug-in state (AuCU)", "Mixer objects (AuCO)", "Metadata (GenM)", "Audio regions (AuRg)", "Tracks (MSeq run)"], start: 0)),
        .init(id: "share", label: "Share", help: "The fraction of those records to remove.",
              kind: .amount(min: 0, max: 0.9, start: 0.3)),
    ]

    static func apply(_ ctx: inout MutationContext, _ p: ParameterValues) {
        let tags = ["AuCU", "AuCO", "GenM", "AuRg", "MSeq"]
        let tag = tags[min(p.choice("target"), tags.count - 1)]
        let share = p.number("share", 0.3)

        if tag == "MSeq" {
            let units = ctx.project.trackUnits()
            let kept = units.filter { _ in !ctx.rng.chance(share) }
            ctx.project.replaceTrackUnits(with: kept.isEmpty ? Array(units.prefix(1)) : kept)
            ctx.note("Dropped \(units.count - max(kept.count, 1)) of \(units.count) tracks.")
            return
        }
        let before = ctx.project.records.count
        var dropped = 0
        ctx.project.records = ctx.project.records.filter { r in
            guard r.tag == tag, ctx.rng.chance(share) else { return true }
            dropped += 1; return false
        }
        ctx.note("Dropped \(dropped) \(tag) records (\(before) → \(ctx.project.records.count)).")
    }
}

// MARK: - Plug-in Scramble  (rough)

/// Channel-strip state is a blob per record. Deal them to different channels and
/// the reverb lands on the kick and the amp sim on the vocal.
enum PluginScramble: MutationStrategy {
    static let id = "plugin-scramble"
    static let title = "Plug-in Scramble"
    static let blurb = "Deals every channel's plug-in state out to a different channel, so each instrument inherits somebody else's processing."
    static let fidelity = Fidelity.rough
    static let parameters: [StrategyParameter] = [
        .init(id: "safe", label: "Same size only", help: "Only trade blobs of identical length. Much more likely to still open.",
              kind: .flag(start: true)),
        .init(id: "cross", label: "Pull from donors", help: "Take the replacement blobs out of the donor projects instead of this one.",
              kind: .flag(start: false)),
    ]

    static func apply(_ ctx: inout MutationContext, _ p: ParameterValues) {
        let idx = ctx.project.indices(ofTag: "AuCU")
        guard idx.count > 1 else { ctx.note("Nothing to scramble."); return }
        let pool: [Data] = p.flag("cross")
            ? ctx.donors.flatMap { d in d.indices(ofTag: "AuCU").map { d.records[$0].payload } }
            : idx.map { ctx.project.records[$0].payload }
        guard !pool.isEmpty else { return }
        var swapped = 0

        if p.flag("safe", true) {
            // Group by payload length and permute inside each group: same bytes
            // count in, same bytes count out, so the record stays the right size.
            var buckets: [Int: [Int]] = [:]
            for i in idx { buckets[ctx.project.records[i].payload.count, default: []].append(i) }
            for (_, members) in buckets where members.count > 1 {
                let dealt = ctx.rng.shuffled(members.map { ctx.project.records[$0].payload })
                for (n, i) in members.enumerated() where dealt[n] != ctx.project.records[i].payload {
                    ctx.project.records[i].payload = dealt[n]; swapped += 1
                }
            }
        } else {
            let dealt = ctx.rng.shuffled(pool)
            for (n, i) in idx.enumerated() {
                ctx.project.records[i].payload = dealt[n % dealt.count]; swapped += 1
            }
        }
        ctx.note("Scrambled \(swapped) plug-in blobs.")
    }
}

// MARK: - Media Transplant  (rough)

/// Repoint the host's audio-file references at the donor's audio and copy the
/// files in. The arrangement stays; every sound in it is replaced.
enum MediaTransplant: MutationStrategy {
    static let id = "media-transplant"
    static let title = "Media Transplant"
    static let blurb = "Repoints the host's audio-file references at the donors' audio and copies those files in — same arrangement, different sound entirely."
    static let fidelity = Fidelity.rough
    static let needsDonor = true
    static let parameters: [StrategyParameter] = [
        .init(id: "order", label: "Pairing", help: "How host files are matched to donor files.",
              kind: .choice(options: ["In order", "Shuffled", "All to one"], start: 0)),
    ]

    static func apply(_ ctx: inout MutationContext, _ p: ParameterValues) {
        let idx = ctx.project.indices(ofTag: "AuFl")
        var donorNames = ctx.donors.flatMap { d in d.indices(ofTag: "AuFl").compactMap { d.records[$0].audioFileName } }
        donorNames = donorNames.filter { !$0.isEmpty }
        guard !idx.isEmpty, !donorNames.isEmpty else { ctx.note("No audio files to transplant."); return }

        switch p.choice("order") {
        case 1: donorNames = ctx.rng.shuffled(donorNames)
        case 2: donorNames = [donorNames[ctx.rng.int(0..<donorNames.count)]]
        default: break
        }
        for (n, i) in idx.enumerated() {
            ctx.project.records[i].setAudioFileName(donorNames[n % donorNames.count])
        }
        ctx.needsDonorMedia = true
        ctx.note("Repointed \(idx.count) audio references at \(donorNames.count) donor file(s).")
    }
}

// MARK: - Track Graft  (feral)

/// The blunt hybrid: the donor's tracks, bodily, into the host's project.
enum TrackGraft: MutationStrategy {
    static let id = "track-graft"
    static let title = "Track Graft"
    static let blurb = "Lifts whole tracks out of the donors and appends them to the host's arrangement. The most literal way to make one project out of several."
    static let fidelity = Fidelity.feral
    static let needsDonor = true
    static let parameters: [StrategyParameter] = [
        .init(id: "take", label: "Take", help: "Tracks to lift from each donor. 0 takes all of them.",
              kind: .count(min: 0, max: 40, start: 0)),
        .init(id: "named", label: "Named tracks only", help: "Skip Logic's internal lanes and keep the tracks a person actually made.",
              kind: .flag(start: true)),
        .init(id: "media", label: "Bring their audio", help: "Copy the donors' Media folders in alongside the grafted tracks.",
              kind: .flag(start: true)),
    ]

    /// Logic's own scaffolding shows up as sequences too. Grafting these across
    /// projects is what turns a hybrid into a file Logic will not open.
    static let internalNames: Set<String> = [
        "TRASH", "Track Automation Root Folder", "Track Alternatives", "*Automation",
        "Default Clip (MIDI)", "Default Clip (Audio)", "Default Clip (GenInst, deprecated)",
        "RBA Sequence",
    ]

    static func harvest(_ p: LogicProject, namedOnly: Bool) -> [TrackUnit] {
        p.trackUnits().filter { u in
            guard namedOnly else { return true }
            guard let n = u.name, !n.isEmpty, n != "Untitled", !internalNames.contains(n) else { return false }
            return !n.hasPrefix("*")
        }
    }

    static func apply(_ ctx: inout MutationContext, _ p: ParameterValues) {
        let take = p.count("take", 0), namedOnly = p.flag("named", true)
        var grafted: [TrackUnit] = []
        for d in ctx.donors {
            let found = harvest(d, namedOnly: namedOnly)
            grafted.append(contentsOf: take > 0 ? Array(found.prefix(take)) : found)
        }
        guard !grafted.isEmpty else { ctx.note("No donor tracks matched."); return }
        ctx.project.replaceTrackUnits(with: ctx.project.trackUnits() + grafted)
        if p.flag("media", true) { ctx.needsDonorMedia = true }
        ctx.note("Grafted \(grafted.count) donor tracks in.")
    }
}

// MARK: - Track Zipper  (feral)

enum TrackZipper: MutationStrategy {
    static let id = "track-zipper"
    static let title = "Track Zipper"
    static let blurb = "Interleaves the host's tracks with the donors' one for one, so the arrangement alternates between projects all the way down."
    static let fidelity = Fidelity.feral
    static let needsDonor = true
    static let parameters: [StrategyParameter] = [
        .init(id: "stride", label: "Stride", help: "How many host tracks pass before a donor track is dealt in.",
              kind: .count(min: 1, max: 8, start: 1)),
        .init(id: "named", label: "Named tracks only", help: "Skip Logic's internal lanes when taking from the donors.",
              kind: .flag(start: true)),
        .init(id: "media", label: "Bring their audio", help: "Copy the donors' Media folders in as well.",
              kind: .flag(start: true)),
    ]

    static func apply(_ ctx: inout MutationContext, _ p: ParameterValues) {
        let mine = ctx.project.trackUnits()
        let theirs = ctx.donors.flatMap { TrackGraft.harvest($0, namedOnly: p.flag("named", true)) }
        guard !mine.isEmpty, !theirs.isEmpty else { ctx.note("Zipper needs tracks on both sides."); return }
        let stride = max(1, p.count("stride", 1))

        var out: [TrackUnit] = []
        var t = 0
        for (n, u) in mine.enumerated() {
            out.append(u)
            if (n + 1) % stride == 0, t < theirs.count { out.append(theirs[t]); t += 1 }
        }
        // Anything the host was too short to interleave still goes on the end.
        out.append(contentsOf: theirs[min(t, theirs.count)...])
        ctx.project.replaceTrackUnits(with: out)
        if p.flag("media", true) { ctx.needsDonorMedia = true }
        ctx.note("Zipped \(mine.count) host tracks with \(theirs.count) donor tracks.")
    }
}

// MARK: - Byte Weave  (feral)

/// The bottom of the barrel, and the most interesting place to be. Two records
/// of the same kind, from two different projects, interleaved byte by byte.
/// Lengths are preserved so the stream still parses; nothing else is promised.
enum ByteWeave: MutationStrategy {
    static let id = "byte-weave"
    static let title = "Byte Weave"
    static let blurb = "Interleaves the raw bytes of the host's records with the donors' — every Nth byte comes from the other project. The stream still parses; what it means is anyone's guess."
    static let fidelity = Fidelity.feral
    static let needsDonor = true
    static let parameters: [StrategyParameter] = [
        .init(id: "target", label: "Weave", help: "Which records to interleave.",
              kind: .choice(options: ["Plug-in state (AuCU)", "Mixer objects (AuCO)", "Metadata (GenM)", "Environment (Envi)", "Audio regions (AuRg)"], start: 0)),
        .init(id: "period", label: "Every", help: "Take one byte from the donor every N bytes. 2 is a hard braid, 16 is a haze.",
              kind: .count(min: 2, max: 64, start: 8)),
        .init(id: "skipHead", label: "Spare the first 16 bytes", help: "The head of a payload is usually structure. Leaving it alone keeps far more projects openable.",
              kind: .flag(start: true)),
    ]

    static func apply(_ ctx: inout MutationContext, _ p: ParameterValues) {
        let tags = ["AuCU", "AuCO", "GenM", "Envi", "AuRg"]
        let tag = tags[min(p.choice("target"), tags.count - 1)]
        let period = max(2, p.count("period", 8))
        let head = p.flag("skipHead", true) ? 16 : 0

        let mine = ctx.project.indices(ofTag: tag)
        let theirs = ctx.donors.flatMap { d in d.indices(ofTag: tag).map { d.records[$0].payload } }
        guard !mine.isEmpty, !theirs.isEmpty else { ctx.note("Byte Weave needs \(tag) records on both sides."); return }

        var woven = 0
        for (n, i) in mine.enumerated() {
            let other = theirs[n % theirs.count]
            var p0 = ctx.project.records[i].payload
            guard p0.count > head, other.count > head else { continue }
            var k = head
            while k < p0.count {
                if k < other.count { p0[byte: k] = other[byte: k] }
                k += period
            }
            ctx.project.records[i].payload = p0
            woven += 1
        }
        ctx.note("Wove \(woven) \(tag) payloads at a period of \(period).")
    }
}

//  Strategy.swift
//
//  A strategy is one way of folding several Logic projects into one. They are
//  deliberately small and composable: the app runs a chain of them in order
//  against a single mutable context, so "graft the donor's tracks, then fold the
//  tempos, then scatter every region" is three strategies and not a special case.

import Foundation

// MARK: - Reproducibility

/// SplitMix64. Same seed, same hybrid — which matters, because the interesting
/// results are the ones you want to hear twice.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
    mutating func int(_ range: Range<Int>) -> Int {
        range.isEmpty ? range.lowerBound : range.lowerBound + Int(next() % UInt64(range.count))
    }
    mutating func chance(_ p: Double) -> Bool { unit() < p }

    /// Fisher-Yates, so a permutation is reproducible from the seed alone.
    mutating func shuffled<T>(_ xs: [T]) -> [T] {
        var a = xs
        guard a.count > 1 else { return a }
        for i in stride(from: a.count - 1, to: 0, by: -1) { a.swapAt(i, int(0..<(i + 1))) }
        return a
    }
}

// MARK: - How far from a working project we are willing to travel

enum Fidelity: Int, CaseIterable, Comparable, Codable {
    /// Field values only. The record stream keeps its shape.
    case gentle = 0
    /// Records reordered, repeated or dropped.
    case rough = 1
    /// Records and raw bytes cross between projects.
    case feral = 2

    var label: String { ["Gentle", "Rough", "Feral"][rawValue] }
    var blurb: String {
        // Measured, not guessed: all thirteen strategies, and all thirteen
        // chained at once, were opened in Logic Pro 12.3.1. The ladder is about
        // how far the result travels from being a project, not about risk of
        // failure — though the further up you go the less Logic has to work with.
        [ "Tempo, meter, names, region windows. The stream keeps its shape.",
          "Tracks reordered, repeated or thrown away. Still a project, with holes in its memory.",
          "Records and raw bytes cross between projects. It still opens; it stops being about one song."
        ][rawValue]
    }
    static func < (a: Fidelity, b: Fidelity) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - Parameters, described so the UI can draw itself

struct StrategyParameter: Identifiable, Hashable {
    enum Kind: Hashable {
        case amount(min: Double, max: Double, start: Double)
        case count(min: Int, max: Int, start: Int)
        case choice(options: [String], start: Int)
        case flag(start: Bool)
    }
    let id: String
    let label: String
    let help: String
    let kind: Kind
}

struct ParameterValues: Codable, Hashable {
    var numbers: [String: Double] = [:]
    var choices: [String: Int] = [:]
    var flags: [String: Bool] = [:]

    init(defaults: [StrategyParameter]) {
        for p in defaults {
            switch p.kind {
            case .amount(_, _, let s): numbers[p.id] = s
            case .count(_, _, let s): numbers[p.id] = Double(s)
            case .choice(_, let s): choices[p.id] = s
            case .flag(let s): flags[p.id] = s
            }
        }
    }

    func number(_ id: String, _ fallback: Double = 0) -> Double { numbers[id] ?? fallback }
    func count(_ id: String, _ fallback: Int = 0) -> Int { Int((numbers[id] ?? Double(fallback)).rounded()) }
    func choice(_ id: String, _ fallback: Int = 0) -> Int { choices[id] ?? fallback }
    func flag(_ id: String, _ fallback: Bool = false) -> Bool { flags[id] ?? fallback }
}

// MARK: - The thing being mutated

struct MutationContext {
    /// The project every strategy writes into. Starts as a copy of the host.
    var project: LogicProject
    /// Parsed donors, in the order the user listed them. May be empty.
    var donors: [LogicProject]
    /// Their bundles, for strategies that need the files and not just the stream.
    var donorBundles: [LogicBundle]
    var rng: SeededRandom
    private(set) var log: [String] = []
    /// Set by any strategy that pulls a donor's audio in, so the runner copies it.
    var needsDonorMedia = false

    mutating func note(_ s: String) { log.append(s) }

    /// Round-robin donor pick, so a chain of strategies spreads across the pool
    /// instead of all reaching for the first one.
    func donor(_ i: Int) -> LogicProject? {
        donors.isEmpty ? nil : donors[((i % donors.count) + donors.count) % donors.count]
    }
}

// MARK: - Strategy

protocol MutationStrategy {
    static var id: String { get }
    static var title: String { get }
    static var blurb: String { get }
    static var fidelity: Fidelity { get }
    static var needsDonor: Bool { get }
    static var parameters: [StrategyParameter] { get }
    static func apply(_ ctx: inout MutationContext, _ p: ParameterValues)
}

extension MutationStrategy {
    static var needsDonor: Bool { false }
    static var parameters: [StrategyParameter] { [] }
}

/// Type-erased face of a strategy, so the UI and the runner can hold a list.
struct AnyStrategy: Identifiable, Hashable {
    let id: String
    let title: String
    let blurb: String
    let fidelity: Fidelity
    let needsDonor: Bool
    let parameters: [StrategyParameter]
    let run: (inout MutationContext, ParameterValues) -> Void

    init<S: MutationStrategy>(_ type: S.Type) {
        id = S.id; title = S.title; blurb = S.blurb
        fidelity = S.fidelity; needsDonor = S.needsDonor; parameters = S.parameters
        run = S.apply
    }

    static func == (a: AnyStrategy, b: AnyStrategy) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
    func defaultValues() -> ParameterValues { ParameterValues(defaults: parameters) }
}

enum StrategyCatalog {
    /// Ordered roughly gentle → feral, which is also roughly the order in which
    /// you would reach for them.
    static let all: [AnyStrategy] = [
        AnyStrategy(TempoFold.self),
        AnyStrategy(SignatureWarp.self),
        AnyStrategy(RegionDrift.self),
        AnyStrategy(RegionConvolution.self),
        AnyStrategy(NameTransplant.self),
        AnyStrategy(TrackPalindrome.self),
        AnyStrategy(TrackStutter.self),
        AnyStrategy(Dropout.self),
        AnyStrategy(PluginScramble.self),
        AnyStrategy(MediaTransplant.self),
        AnyStrategy(TrackGraft.self),
        AnyStrategy(TrackZipper.self),
        AnyStrategy(ByteWeave.self),
    ]

    static func strategy(id: String) -> AnyStrategy? { all.first { $0.id == id } }
}

// MARK: - Track units
//
// A track in the stream is a contiguous run: MSeq (the sequence, which carries
// the name), then Trak (36 bytes, no payload), then EvSq (its event list). They
// always appear in that order and adjacent, so a unit can be lifted whole.

struct TrackUnit {
    var records: [LogicRecord]
    var name: String? { records.first?.sequenceName }
    var subtype: UInt16 { records.first?.subtype ?? 0 }
}

extension LogicProject {
    func trackUnits() -> [TrackUnit] {
        var out: [TrackUnit] = []
        var i = 0
        while i < records.count {
            guard records[i].tag == "MSeq" else { i += 1; continue }
            var run = [records[i]]
            var j = i + 1
            while j < records.count, records[j].tag == "Trak" || records[j].tag == "EvSq" {
                run.append(records[j]); j += 1
            }
            out.append(TrackUnit(records: run))
            i = j
        }
        return out
    }

    /// Replaces every track unit with a new list, leaving all other records — the
    /// Song header, styles, environment, mixer — exactly where they were.
    mutating func replaceTrackUnits(with units: [TrackUnit]) {
        guard records.contains(where: { $0.tag == "MSeq" }) else { return }
        var kept: [LogicRecord] = []
        var inserted = false
        var i = 0
        while i < records.count {
            guard records[i].tag == "MSeq" else { kept.append(records[i]); i += 1; continue }
            // The whole run of units goes in where the first one used to be, so
            // the records that bracket the track list keep their relative order.
            if !inserted { kept.append(contentsOf: units.flatMap(\.records)); inserted = true }
            var j = i + 1
            while j < records.count, records[j].tag == "Trak" || records[j].tag == "EvSq" { j += 1 }
            i = j
        }
        records = kept
        renumber()
    }
}

//  Chimerizer.swift
//
//  The runner. Takes a host, some donors, an ordered chain of strategies and a
//  seed, and leaves a new bundle on disk. Two rules it never breaks: the inputs
//  are opened read-only, and nothing is written until the mutated stream has been
//  parsed back successfully by the same reader that produced it.

import Foundation

struct RecipeStep: Identifiable, Hashable, Codable {
    var id = UUID()
    var strategyID: String
    var values: ParameterValues
    var enabled: Bool = true

    var strategy: AnyStrategy? { StrategyCatalog.strategy(id: strategyID) }

    init(strategy: AnyStrategy) {
        strategyID = strategy.id
        values = strategy.defaultValues()
    }
}

struct Recipe {
    var host: URL
    var donors: [URL] = []
    var steps: [RecipeStep] = []
    var seed: UInt64 = 1
    var outputDirectory: URL
    /// Highest fidelity the user is willing to accept; steps beyond it are skipped.
    var fidelityCeiling: Fidelity = .feral

    var activeSteps: [RecipeStep] {
        steps.filter { $0.enabled && ($0.strategy.map { $0.fidelity <= fidelityCeiling } ?? false) }
    }
}

struct ChimeraResult {
    var outputURL: URL
    var log: [String]
    var warnings: [String]
    var parsesBack: Bool
    var recordsBefore: Int
    var recordsAfter: Int
    var tracksBefore: Int
    var tracksAfter: Int
    var tempoBefore: Double
    var tempoAfter: Double
    var bytesAfter: Int
    var mediaAdded: Int

    var headline: String {
        let d = recordsAfter - recordsBefore
        let delta = d == 0 ? "same record count" : (d > 0 ? "+\(d) records" : "\(d) records")
        return "\(tracksAfter) tracks, \(delta), \(String(format: "%.2f", tempoAfter)) BPM"
    }
}

enum ChimeraError: LocalizedError {
    case hostUnreadable(String)
    case outputInvalid(String)

    var errorDescription: String? {
        switch self {
        case .hostUnreadable(let s): return "Could not read the host project: \(s)"
        case .outputInvalid(let s): return "The mutated project would not parse back: \(s)"
        }
    }
}

enum Chimerizer {

    /// Names the result after what made it, because six months later the only
    /// thing that tells you how to get back here is the filename.
    static func outputName(for recipe: Recipe) -> String {
        let host = LogicBundle(url: recipe.host).name
        let donors = recipe.donors.map { LogicBundle(url: $0).name }
        let lineage = ([host] + donors.prefix(2)).joined(separator: " x ")
            + (donors.count > 2 ? " +\(donors.count - 2)" : "")
        let how = recipe.activeSteps.compactMap { $0.strategy?.title }.joined(separator: ", ")
        let base = "\(lineage) — \(how.isEmpty ? "unchanged" : how) (seed \(recipe.seed))"
        return base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .prefix(180) + ".logicx"
    }

    static func run(_ recipe: Recipe) throws -> ChimeraResult {
        let hostBundle = LogicBundle(url: recipe.host)
        let hostProject: LogicProject
        do { hostProject = try hostBundle.project() }
        catch { throw ChimeraError.hostUnreadable(error.localizedDescription) }

        var warnings: [String] = []
        var donorBundles: [LogicBundle] = []
        var donorProjects: [LogicProject] = []
        for url in recipe.donors {
            let b = LogicBundle(url: url)
            do { donorProjects.append(try b.project()); donorBundles.append(b) }
            catch { warnings.append("Skipped donor \(b.name): \(error.localizedDescription)") }
        }

        var ctx = MutationContext(project: hostProject,
                                  donors: donorProjects,
                                  donorBundles: donorBundles,
                                  rng: SeededRandom(seed: recipe.seed))

        let recordsBefore = hostProject.records.count
        let tracksBefore = hostProject.trackUnits().count
        let tempoBefore = hostProject.tempo

        for step in recipe.activeSteps {
            guard let s = step.strategy else { continue }
            if s.needsDonor && donorProjects.isEmpty {
                warnings.append("\(s.title) needs at least one donor — skipped.")
                continue
            }
            ctx.note("· \(s.title)")
            s.run(&ctx, step.values)
        }
        // The gate: if our own reader cannot walk what we just built, nothing
        // reaches the disk. Logic may still refuse it, but this is the floor.
        let data = ctx.project.serialized()
        do { _ = try LogicProject(data: data) }
        catch { throw ChimeraError.outputInvalid(error.localizedDescription) }

        let out = recipe.outputDirectory.appending(path: outputName(for: recipe))
        let made = try hostBundle.copy(to: out)
        try made.write(ctx.project)
        made.updateMetadata(from: ctx.project, trackCount: ctx.project.trackUnits().count)

        var mediaAdded = 0
        if ctx.needsDonorMedia {
            for d in donorBundles { mediaAdded += made.absorbMedia(from: d).count }
            if mediaAdded > 0 { ctx.note("Copied \(mediaAdded) donor media file(s) in.") }
        }

        // Read it back off disk, the way Logic would.
        let parsesBack = (try? made.project()) != nil

        return ChimeraResult(
            outputURL: out, log: ctx.log, warnings: warnings, parsesBack: parsesBack,
            recordsBefore: recordsBefore, recordsAfter: ctx.project.records.count,
            tracksBefore: tracksBefore, tracksAfter: ctx.project.trackUnits().count,
            tempoBefore: tempoBefore, tempoAfter: ctx.project.tempo,
            bytesAfter: data.count, mediaAdded: mediaAdded)
    }
}

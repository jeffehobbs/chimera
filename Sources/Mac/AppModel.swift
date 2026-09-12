//  AppModel.swift

import Foundation
import Observation
import AppKit

@MainActor
@Observable
final class AppModel {

    // MARK: Pool

    struct Source: Identifiable, Hashable {
        let id = UUID()
        let url: URL
        var name: String
        var tempo: Double
        var tracks: Int
        var records: Int
        var readable: Bool
        var trouble: String?

        init(url: URL) {
            self.url = url
            let b = LogicBundle(url: url)
            name = b.name
            do {
                let p = try b.project()
                tempo = p.tempo; tracks = p.trackUnits().count; records = p.records.count
                readable = true; trouble = nil
            } catch {
                tempo = 0; tracks = 0; records = 0
                readable = false; trouble = error.localizedDescription
            }
        }

        var subtitle: String {
            readable ? String(format: "%.4g BPM · %d tracks · %d records", tempo, tracks, records)
                     : (trouble ?? "unreadable")
        }
    }

    var sources: [Source] = []
    var hostID: Source.ID?

    var host: Source? { sources.first { $0.id == hostID } ?? sources.first }
    var donors: [Source] { sources.filter { $0.id != host?.id && $0.readable } }

    // MARK: Recipe

    var steps: [RecipeStep] = []
    var selectedStepID: RecipeStep.ID?
    var seed: UInt64 = 4711
    var fidelityCeiling: Fidelity = .feral
    var outputDirectory: URL = FileManager.default
        .urls(for: .desktopDirectory, in: .userDomainMask).first?
        .appending(path: "Chimera") ?? URL(fileURLWithPath: NSTemporaryDirectory())
    var batchCount: Int = 1

    // MARK: Results

    struct Outcome: Identifiable {
        let id = UUID()
        var result: ChimeraResult?
        var failure: String?
        var name: String
    }
    var outcomes: [Outcome] = []
    var working = false

    // MARK: Launch state
    //
    // A window cannot be clicked from a script, so the two things you would
    // otherwise have to reach for are in the launch environment:
    // CHIMERA_CORPUS=<dir> fills the pool from a folder of .logicx bundles, and
    // CHIMERA_CHAIN=id,id  preloads a chain of strategies by id.

    init() {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["CHIMERA_CORPUS"] {
            let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
            let found = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            add(found.filter { $0.pathExtension == "logicx" }.sorted { $0.path < $1.path })
        }
        if let chain = env["CHIMERA_CHAIN"] {
            for id in chain.split(separator: ",").map(String.init) {
                if let s = StrategyCatalog.strategy(id: id) { append(s) }
            }
        }
    }

    var canRun: Bool {
        host?.readable == true && !steps.filter(\.enabled).isEmpty && !working
    }

    // MARK: Pool editing

    func add(_ urls: [URL]) {
        for u in urls where u.pathExtension == "logicx" {
            guard !sources.contains(where: { $0.url == u }) else { continue }
            sources.append(Source(url: u))
        }
        if hostID == nil { hostID = sources.first(where: \.readable)?.id }
    }

    func remove(_ ids: Set<Source.ID>) {
        sources.removeAll { ids.contains($0.id) }
        if let h = hostID, !sources.contains(where: { $0.id == h }) {
            hostID = sources.first(where: \.readable)?.id
        }
    }

    // MARK: Chain editing

    func append(_ strategy: AnyStrategy) {
        let step = RecipeStep(strategy: strategy)
        steps.append(step)
        selectedStepID = step.id
    }

    func removeStep(_ id: RecipeStep.ID) {
        steps.removeAll { $0.id == id }
        if selectedStepID == id { selectedStepID = steps.last?.id }
    }

    func move(from: IndexSet, to: Int) { steps.move(fromOffsets: from, toOffset: to) }

    var selectedStep: RecipeStep? {
        get { steps.first { $0.id == selectedStepID } }
        set {
            guard let v = newValue, let i = steps.firstIndex(where: { $0.id == v.id }) else { return }
            steps[i] = v
        }
    }

    func binding(for id: RecipeStep.ID) -> RecipeStep? { steps.first { $0.id == id } }

    func update(_ step: RecipeStep) {
        guard let i = steps.firstIndex(where: { $0.id == step.id }) else { return }
        steps[i] = step
    }

    /// How many steps the fidelity ceiling is currently muting.
    var mutedByFidelity: Int {
        steps.filter { $0.enabled && ($0.strategy.map { $0.fidelity > fidelityCeiling } ?? false) }.count
    }

    // MARK: Run

    func run() {
        guard let host, host.readable else { return }
        working = true
        outcomes.removeAll()

        let recipeBase = Recipe(host: host.url,
                                donors: donors.map(\.url),
                                steps: steps,
                                seed: seed,
                                outputDirectory: outputDirectory,
                                fidelityCeiling: fidelityCeiling)
        let count = max(1, batchCount)
        let startSeed = seed

        Task.detached(priority: .userInitiated) { [recipeBase, count, startSeed] in
            var made: [Outcome] = []
            for i in 0..<count {
                var r = recipeBase
                // A batch walks the seed forward, so one press gives a family
                // rather than the same hybrid several times.
                r.seed = startSeed &+ UInt64(i)
                let name = Chimerizer.outputName(for: r)
                do {
                    let out = try Chimerizer.run(r)
                    made.append(Outcome(result: out, failure: nil, name: name))
                } catch {
                    made.append(Outcome(result: nil, failure: error.localizedDescription, name: name))
                }
            }
            let finished = made
            await MainActor.run {
                self.outcomes = finished
                self.working = false
            }
        }
    }

    func rollSeed() { seed = UInt64.random(in: 1...999_999) }

    func revealOutput() {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([outputDirectory])
    }
}

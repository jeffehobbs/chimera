//  chimera-cli
//
//  The same engine as the app, without the window — so every strategy can be run
//  against a whole corpus and checked, which is not something you can do by
//  clicking.
//
//    chimera-cli list
//    chimera-cli info      <bundle.logicx>
//    chimera-cli run       --host A.logicx --donor B.logicx --strategy id[,id…] --seed N --out DIR
//    chimera-cli selftest  <corpus-dir> [--out DIR]

import Foundation

func die(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }

func flag(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: "--" + name),
          i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}
func flags(_ name: String) -> [String] {
    var out: [String] = []
    for (i, a) in CommandLine.arguments.enumerated() where a == "--" + name {
        if i + 1 < CommandLine.arguments.count { out.append(CommandLine.arguments[i + 1]) }
    }
    return out
}
func url(_ p: String) -> URL { URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }

let args = CommandLine.arguments
guard args.count > 1 else { die("usage: chimera-cli list | info | run | selftest") }

switch args[1] {

case "list":
    for f in Fidelity.allCases {
        print("\n\(f.label.uppercased())  — \(f.blurb)")
        for s in StrategyCatalog.all where s.fidelity == f {
            print("  \(s.id.padding(toLength: 20, withPad: " ", startingAt: 0)) \(s.title)\(s.needsDonor ? "  [needs donor]" : "")")
            print("  \(String(repeating: " ", count: 20)) \(s.blurb)")
            for p in s.parameters { print("  \(String(repeating: " ", count: 22))· \(p.id): \(p.label)") }
        }
    }

case "info":
    guard args.count > 2 else { die("info needs a bundle") }
    let b = LogicBundle(url: url(args[2]))
    let p = try LogicProject(contentsOf: b.projectDataURL)
    let sig = p.timeSignature
    print("\(b.name): \(p.records.count) records, \(p.trackUnits().count) track units, "
          + "\(p.tempo) BPM, \(sig.numerator)/\(sig.denominator), format v\(p.dataVersion)/\(p.appVersion)")
    var counts: [String: Int] = [:]
    for r in p.records { counts[r.tag, default: 0] += 1 }
    print("  " + counts.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: " "))
    let named = TrackGraft.harvest(p, namedOnly: true).compactMap(\.name)
    print("  named tracks (\(named.count)): \(named.prefix(12).joined(separator: ", "))")

case "run":
    guard let host = flag("host") else { die("run needs --host") }
    let ids = (flag("strategy") ?? "").split(separator: ",").map(String.init)
    var recipe = Recipe(host: url(host),
                        donors: flags("donor").map(url),
                        seed: UInt64(flag("seed") ?? "1") ?? 1,
                        outputDirectory: url(flag("out") ?? "./out"))
    recipe.steps = ids.compactMap { StrategyCatalog.strategy(id: $0).map(RecipeStep.init) }
    guard !recipe.steps.isEmpty else { die("no known strategies in --strategy") }
    let r = try Chimerizer.run(recipe)
    print("→ \(r.outputURL.lastPathComponent)")
    for line in r.log { print("   \(line)") }
    for w in r.warnings { print("   ! \(w)") }
    print("   \(r.headline); parses back: \(r.parsesBack ? "yes" : "NO")")

case "roundtrip":
    // The sharpest test of the payload writers there is: rewrite every name to
    // exactly the name it already has. If any field width is computed wrong,
    // the bytes move and this fails. Nothing else about the file is touched.
    guard args.count > 2 else { die("roundtrip needs a corpus directory") }
    var rtFail = 0
    for b in ((try? FileManager.default.contentsOfDirectory(at: url(args[2]), includingPropertiesForKeys: nil)) ?? [])
        .filter({ $0.pathExtension == "logicx" }).sorted(by: { $0.path < $1.path }) {
        let bundle = LogicBundle(url: b)
        guard let original = try? Data(contentsOf: bundle.projectDataURL),
              var proj = try? LogicProject(data: original) else { continue }
        let plain = proj.serialized() == original
        for i in proj.records.indices {
            switch proj.records[i].tag {
            case "MSeq": if let n = proj.records[i].sequenceName { proj.records[i].setSequenceName(n) }
            case "AuRg": if let n = proj.records[i].regionName { proj.records[i].setRegionName(n) }
            case "AuFl": if let n = proj.records[i].audioFileName { proj.records[i].setAudioFileName(n) }
            default: break
            }
        }
        let identity = proj.serialized() == original
        if !plain || !identity { rtFail += 1 }
        print("\(plain ? "  parse" : "  PARSE") \(identity ? "  rename" : "  RENAME")  \(bundle.name)")
    }
    print(rtFail == 0 ? "\nbyte-identical on every project" : "\n\(rtFail) project(s) changed bytes they should not have")
    exit(rtFail == 0 ? 0 : 1)

case "selftest":
    // Every strategy, against every host in the corpus, with the next bundle as
    // the donor. The check is that the result parses back off disk.
    guard args.count > 2 else { die("selftest needs a corpus directory") }
    let dir = url(args[2])
    let bundles = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "logicx" }.sorted { $0.path < $1.path }
    guard bundles.count > 1 else { die("need at least two .logicx bundles in \(dir.path)") }
    let outDir = url(flag("out") ?? NSTemporaryDirectory() + "chimera-selftest")
    try? FileManager.default.removeItem(at: outDir)

    var pass = 0, fail = 0, skipped = 0
    for s in StrategyCatalog.all {
        var line = "\(s.title.padding(toLength: 22, withPad: " ", startingAt: 0)) "
        for (i, host) in bundles.enumerated() {
            let donor = bundles[(i + 1) % bundles.count]
            var recipe = Recipe(host: host, donors: [donor], seed: UInt64(i + 7),
                                outputDirectory: outDir.appending(path: s.id))
            recipe.steps = [RecipeStep(strategy: s)]
            do {
                let r = try Chimerizer.run(recipe)
                if r.parsesBack { pass += 1; line += "." } else { fail += 1; line += "X" }
            } catch {
                fail += 1; line += "E"
            }
        }
        print(line)
    }
    // And one long chain, to prove the strategies compose.
    var chained = Recipe(host: bundles[0], donors: Array(bundles.dropFirst().prefix(3)), seed: 4711,
                         outputDirectory: outDir.appending(path: "_chain"))
    chained.steps = StrategyCatalog.all.map(RecipeStep.init)
    do {
        let r = try Chimerizer.run(chained)
        print("\nall thirteen chained: \(r.headline); parses back: \(r.parsesBack ? "yes" : "NO")")
        for l in r.log { print("   \(l)") }
        r.parsesBack ? (pass += 1) : (fail += 1)
    } catch { print("\nchain failed: \(error.localizedDescription)"); fail += 1 }

    print("\n\(pass) passed, \(fail) failed, \(skipped) skipped — output in \(outDir.path)")
    exit(fail == 0 ? 0 : 1)

default:
    die("unknown command \(args[1])")
}

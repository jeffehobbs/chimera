//  ContentView.swift
//
//  One window, three columns: what goes in, what happens to it, what came out.

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var importing = false

    var body: some View {
        HSplitView {
            SourcePane(model: model, importing: $importing)
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
            ChainPane(model: model)
                .frame(minWidth: 340, idealWidth: 420)
            OutcomePane(model: model)
                .frame(minWidth: 300, idealWidth: 380)
        }
        .frame(minWidth: 960, minHeight: 560)
        .toolbar { Toolbar(model: model, importing: $importing) }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: Self.logicTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
    }

    static var logicTypes: [UTType] {
        [UTType(filenameExtension: "logicx"), .package, .folder].compactMap { $0 }
    }
}

// MARK: - Toolbar

private struct Toolbar: ToolbarContent {
    @Bindable var model: AppModel
    @Binding var importing: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { importing = true } label: { Label("Add", systemImage: "plus") }
                .help("Add Logic projects to the pool. You can also drag them onto the list.")
        }
        ToolbarItem {
            Picker("", selection: $model.fidelityCeiling) {
                ForEach(Fidelity.allCases, id: \.self) { f in Text(f.label).tag(f) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help(model.fidelityCeiling.blurb)
        }
        ToolbarItem {
            HStack(spacing: 4) {
                TextField("", value: $model.seed, format: .number)
                    .frame(width: 78).textFieldStyle(.roundedBorder)
                    .help("The seed. The same seed, pool and chain always produce the same hybrid.")
                Button { model.rollSeed() } label: { Image(systemName: "dice") }
                    .help("Roll a new seed.")
            }
        }
        ToolbarItem {
            Button(action: model.run) {
                Label(model.working ? "Working…" : "Make", systemImage: "wand.and.stars")
            }
            .disabled(!model.canRun)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Build the hybrid into the output folder.")
        }
    }
}

// MARK: - Sources

private struct SourcePane: View {
    @Bindable var model: AppModel
    @Binding var importing: Bool
    @State private var selection = Set<AppModel.Source.ID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chimera")
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .kerning(1.5)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)

            List(selection: $selection) {
                ForEach(model.sources) { s in
                    SourceRow(source: s, isHost: s.id == model.host?.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { if s.readable { model.hostID = s.id } }
                        .contextMenu {
                            Button("Use as host") { model.hostID = s.id }.disabled(!s.readable)
                            Button("Remove") { model.remove([s.id]) }
                            Divider()
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([s.url]) }
                        }
                        .tag(s.id)
                }
            }
            .listStyle(.inset)
            .onDeleteCommand { model.remove(selection); selection.removeAll() }
            .dropDestination(for: URL.self) { urls, _ in
                model.add(urls); return true
            }
            .overlay {
                if model.sources.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.down.right")
                            .font(.system(size: 34)).foregroundStyle(.tertiary)
                        Text("Drop .logicx projects here")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .allowsHitTesting(false)
                }
            }

            Divider()
            HStack(spacing: 6) {
                Image(systemName: "largecircle.fill.circle").foregroundStyle(.tint)
                Text(model.host?.name ?? "no host")
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(model.donors.count) donor\(model.donors.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .help("The host supplies the project that everything else is folded into. Double-click another to promote it.")
        }
    }
}

private struct SourceRow: View {
    let source: AppModel.Source
    let isHost: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isHost ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isHost ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                .font(.system(size: 11))
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name).lineLimit(1).truncationMode(.middle)
                Text(source.subtitle)
                    .font(.caption2)
                    .foregroundStyle(source.readable ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Chain

private struct ChainPane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    if model.steps.isEmpty {
                        Text("Add a strategy below.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(model.steps) { step in
                        StepRow(model: model, step: step)
                    }
                    .onMove { model.move(from: $0, to: $1) }
                }
                Section {
                    ForEach(Fidelity.allCases, id: \.self) { f in
                        DisclosureGroup(f.label) {
                            ForEach(StrategyCatalog.all.filter { $0.fidelity == f }) { s in
                                Button { model.append(s) } label: {
                                    HStack {
                                        Text(s.title)
                                        if s.needsDonor {
                                            Image(systemName: "arrow.triangle.merge")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "plus.circle").foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .help(s.blurb)
                            }
                        }
                        .help(f.blurb)
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            HStack(spacing: 10) {
                Stepper(value: $model.batchCount, in: 1...24) {
                    Text("\(model.batchCount)×").monospacedDigit()
                }
                .help("Make this many hybrids in one pass, walking the seed forward each time.")
                Spacer()
                Button { model.revealOutput() } label: {
                    Label(model.outputDirectory.lastPathComponent, systemImage: "folder")
                        .lineLimit(1)
                }
                .buttonStyle(.link)
                .help("Where finished hybrids land: \(model.outputDirectory.path)")
            }
            .font(.caption)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

private struct StepRow: View {
    @Bindable var model: AppModel
    let step: RecipeStep

    private var muted: Bool { (step.strategy?.fidelity ?? .gentle) > model.fidelityCeiling }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { step.enabled },
                    set: { var s = step; s.enabled = $0; model.update(s) }))
                    .labelsHidden()
                Text(step.strategy?.title ?? step.strategyID)
                    .strikethrough(muted)
                    .foregroundStyle(step.enabled && !muted ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                if muted {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                        .help("Above the current fidelity — this step will be skipped.")
                }
                Spacer()
                Button { model.removeStep(step.id) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
            .help(step.strategy?.blurb ?? "")

            if let s = step.strategy, !s.parameters.isEmpty, step.enabled, !muted {
                ParameterControls(strategy: s, step: step, model: model)
                    .padding(.leading, 22)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ParameterControls: View {
    let strategy: AnyStrategy
    let step: RecipeStep
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(strategy.parameters) { p in
                switch p.kind {
                case .amount(let lo, let hi, _):
                    HStack(spacing: 8) {
                        Text(p.label).font(.caption).frame(width: 74, alignment: .leading)
                        Slider(value: number(p.id, fallback: lo), in: lo...hi)
                        Text(String(format: "%.2f", step.values.number(p.id, lo)))
                            .font(.caption).monospacedDigit().frame(width: 38, alignment: .trailing)
                    }
                    .help(p.help)
                case .count(let lo, let hi, _):
                    HStack(spacing: 8) {
                        Text(p.label).font(.caption).frame(width: 74, alignment: .leading)
                        Slider(value: number(p.id, fallback: Double(lo)),
                               in: Double(lo)...Double(hi), step: 1)
                        Text("\(step.values.count(p.id, lo))")
                            .font(.caption).monospacedDigit().frame(width: 38, alignment: .trailing)
                    }
                    .help(p.help)
                case .choice(let options, _):
                    HStack(spacing: 8) {
                        Text(p.label).font(.caption).frame(width: 74, alignment: .leading)
                        Picker("", selection: choice(p.id)) {
                            ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
                        }
                        .labelsHidden()
                    }
                    .help(p.help)
                case .flag:
                    Toggle(isOn: flagValue(p.id)) { Text(p.label).font(.caption) }
                        .toggleStyle(.checkbox)
                        .help(p.help)
                }
            }
        }
    }

    private func number(_ id: String, fallback: Double) -> Binding<Double> {
        Binding(get: { step.values.number(id, fallback) },
                set: { var s = step; s.values.numbers[id] = $0; model.update(s) })
    }
    private func choice(_ id: String) -> Binding<Int> {
        Binding(get: { step.values.choice(id) },
                set: { var s = step; s.values.choices[id] = $0; model.update(s) })
    }
    private func flagValue(_ id: String) -> Binding<Bool> {
        Binding(get: { step.values.flag(id) },
                set: { var s = step; s.values.flags[id] = $0; model.update(s) })
    }
}

// MARK: - Outcomes

private struct OutcomePane: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.working {
                VStack(spacing: 10) { ProgressView(); Text("Folding…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.outcomes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("Nothing made yet").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.outcomes) { OutcomeRow(outcome: $0) }
                    .listStyle(.inset)
            }
        }
    }
}

private struct OutcomeRow: View {
    let outcome: AppModel.Outcome

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(outcome.result?.outputURL.deletingPathExtension().lastPathComponent ?? outcome.name)
                    .font(.callout).lineLimit(2)
            }
            if let r = outcome.result {
                Text(r.headline).font(.caption).foregroundStyle(.secondary)
                if !r.parsesBack {
                    Text("Written, but it no longer reads back cleanly.")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(r.warnings, id: \.self) { Text($0).font(.caption2).foregroundStyle(.orange) }
                DisclosureGroup("What happened") {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(r.log, id: \.self) {
                            Text($0).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)
                HStack(spacing: 12) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([r.outputURL])
                    }
                    Button("Open in Logic") { NSWorkspace.shared.open(r.outputURL) }
                }
                .font(.caption).buttonStyle(.link)
            } else if let f = outcome.failure {
                Text(f).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        guard let r = outcome.result else { return "xmark.octagon" }
        return r.parsesBack ? "checkmark.seal" : "exclamationmark.triangle"
    }
    private var tint: Color {
        guard let r = outcome.result else { return .red }
        return r.parsesBack ? .green : .orange
    }
}

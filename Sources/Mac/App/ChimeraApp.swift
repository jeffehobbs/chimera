//  ChimeraApp.swift

import SwiftUI

@main
struct ChimeraApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Chimera", id: "main") {
            ContentView(model: model)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Make") {
                Button("Make Hybrid") { model.run() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canRun)
                Button("Roll Seed") { model.rollSeed() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Show Output Folder") { model.revealOutput() }
            }
        }
    }
}

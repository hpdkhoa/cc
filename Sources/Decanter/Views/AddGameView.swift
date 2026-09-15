import SwiftUI
import AppKit
import DecanterCore

/// "Add local .exe" wizard: runner, prefix (new or existing), executable.
@MainActor struct AddGameView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var onAdded: (Game) -> Void

    @State private var name = ""
    @State private var runnerID = ""
    @State private var useExistingPrefix = false
    @State private var newPrefixName = ""
    @State private var existingPrefixName = ""
    @State private var windowsVersion: WindowsVersion = .win7
    @State private var exePath = ""
    @State private var argsText = ""
    @State private var working = false
    @State private var status = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Game").font(.title2).bold().padding()
            Form {
                TextField("Name", text: $name)

                Picker("Runner", selection: $runnerID) {
                    ForEach(state.runners) { r in Text(r.displayName).tag(r.id) }
                }

                Section("Prefix") {
                    Picker("Prefix", selection: $useExistingPrefix) {
                        Text("Create new").tag(false)
                        Text("Use existing").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(state.prefixes.isEmpty)

                    if useExistingPrefix {
                        Picker("Existing prefix", selection: $existingPrefixName) {
                            ForEach(state.prefixes) { p in Text(p.name).tag(p.name) }
                        }
                    } else {
                        TextField("New prefix name", text: $newPrefixName, prompt: Text("e.g. browser-game"))
                        Picker("Windows version", selection: $windowsVersion) {
                            ForEach(WindowsVersion.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                }

                Section("Executable") {
                    HStack {
                        TextField("Path to .exe", text: $exePath, prompt: Text("/path/to/game.exe or drive_c/… inside the prefix"))
                        Button("Choose…") { chooseExe() }
                    }
                    TextField("Arguments", text: $argsText, prompt: Text("space separated"))
                    Text("Executables outside the prefix are kept at their absolute path. If you plan to install the game into the prefix, create the prefix first, run the installer via Tools, then add the installed .exe.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.callout).padding(.horizontal)
            }
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button(useExistingPrefix ? "Add" : "Create Prefix & Add") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || working)
            }
            .padding()
        }
        .frame(width: 560, height: 520)
        .onAppear {
            if runnerID.isEmpty { runnerID = state.defaultRunner?.id ?? state.runners.first?.id ?? "" }
            if existingPrefixName.isEmpty { existingPrefixName = state.prefixes.first?.name ?? "" }
        }
        .onChange(of: name) { old, new in
            // Keep the suggested prefix name in sync until the user edits it by hand.
            if !useExistingPrefix && (newPrefixName.isEmpty || newPrefixName == Self.slug(from: old)) {
                newPrefixName = Self.slug(from: new)
            }
        }
    }

    private var canSubmit: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !runnerID.isEmpty, !exePath.isEmpty else { return false }
        return useExistingPrefix ? !existingPrefixName.isEmpty : PrefixManager.isValidName(newPrefixName)
    }

    static func slug(from name: String) -> String {
        let lowered = name.lowercased().map { ch -> Character in (ch.isLetter || ch.isNumber) ? ch : "-" }
        var s = String(lowered)
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func chooseExe() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose a Windows executable"
        if useExistingPrefix, let p = state.prefixes.first(where: { $0.name == existingPrefixName }) {
            panel.directoryURL = p.driveC
        }
        if panel.runModal() == .OK, let url = panel.url {
            exePath = url.path
            if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
        }
    }

    private func submit() async {
        errorText = nil
        working = true
        defer { working = false }
        guard let runner = state.runner(id: runnerID) else { errorText = "Pick a runner."; return }

        let prefix: WinePrefix
        if useExistingPrefix {
            guard let p = state.prefixes.first(where: { $0.name == existingPrefixName }) else { errorText = "Pick a prefix."; return }
            prefix = p
        } else {
            status = "Creating prefix \(newPrefixName) (wineboot)…"
            do {
                prefix = try await state.prefixManager.create(name: newPrefixName, runner: runner, windowsVersion: windowsVersion)
                state.prefixes = await state.prefixManager.list()
            } catch {
                errorText = error.localizedDescription
                return
            }
        }

        let exeURL = URL(fileURLWithPath: exePath)
        let args = argsText.split(separator: " ").map(String.init)
        let game = Game(name: name.trimmingCharacters(in: .whitespaces), prefixName: prefix.name, runnerID: runner.id,
                        exePath: Game.storedExePath(for: exeURL, in: prefix), args: args)
        onAdded(game)
        dismiss()
    }
}

import SwiftUI
import AppKit
import DecanterCore

struct RunnersView: View {
    @Environment(AppState.self) private var state

    @State private var bundled: [BundledRunner] = []
    @State private var releases: [RunnerRelease] = []
    @State private var loadingReleases = false
    @State private var releasesError: String?
    @State private var progress: InstallProgress?
    @State private var confirmDelete: Runner?

    var body: some View {
        List {
            Section("Installed") {
                if state.runners.isEmpty {
                    Text("No runners installed. Install the bundled one below (no internet needed) or download one.")
                        .foregroundStyle(.secondary)
                }
                ForEach(state.runners) { runner in
                    HStack {
                        VStack(alignment: .leading) {
                            HStack(spacing: 6) {
                                Text(runner.displayName).font(.headline)
                                if runner.id == state.defaultRunnerID {
                                    Text("DEFAULT").font(.caption2).bold().padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(.blue.opacity(0.2), in: Capsule())
                                }
                            }
                            Text("\(runner.source.rawValue) · \(runner.appPath.path)").font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("Set Default") { Task { await setDefault(runner) } }.disabled(runner.id == state.defaultRunnerID)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([runner.appPath]) }
                        Button("Delete", role: .destructive) { confirmDelete = runner }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                if bundled.isEmpty {
                    Text(Paths.vendorDir == nil
                         ? "Vendor/runners/manifest.json not found. Run Decanter from the source checkout (swift run) or set DECANTER_VENDOR_DIR."
                         : "No bundled runners in the manifest.")
                        .foregroundStyle(.secondary)
                }
                ForEach(bundled) { b in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(b.kind.displayName) \(b.version)").font(.headline)
                            Text("\(b.asset) · \(ByteCountFormatter.string(fromByteCount: b.size, countStyle: .file)) · \(b.parts.count) parts")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if state.runners.contains(where: { $0.id == b.id }) {
                            Text("Installed").foregroundStyle(.secondary)
                        } else {
                            Button("Install (offline)") { Task { await installBundled(b) } }.disabled(progress != nil)
                        }
                    }
                }
                Button("Import .tar.xz…") { importArchive() }.disabled(progress != nil)
            } header: {
                Text("Bundled (offline)")
            } footer: {
                Text("Vendored in the repo: reassembled from parts, SHA-256 checked, unpacked into \(Paths.runners.path), quarantine removed.")
            }

            Section {
                HStack {
                    Button {
                        Task { await loadReleases() }
                    } label: {
                        Label("Refresh from GitHub", systemImage: "arrow.clockwise")
                    }
                    .disabled(loadingReleases)
                    if loadingReleases { ProgressView().controlSize(.small) }
                    if let releasesError { Text(releasesError).foregroundStyle(.red).font(.caption) }
                }
                ForEach(releases) { rel in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(rel.kind.displayName) \(rel.version)").font(.headline)
                            Text("\(rel.assetName) · \(ByteCountFormatter.string(fromByteCount: rel.size, countStyle: .file))"
                                 + (rel.publishedAt.map { " · \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if state.runners.contains(where: { $0.id == rel.id }) {
                            Text("Installed").foregroundStyle(.secondary)
                        } else {
                            Button("Download & Install") { Task { await install(rel) } }.disabled(progress != nil)
                        }
                    }
                }
            } header: {
                Text("Available online (Gcenx/macOS_Wine_builds)")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let progress {
                HStack {
                    if let f = progress.fraction { ProgressView(value: f) } else { ProgressView() }
                    Text(progress.phase).font(.callout).lineLimit(1)
                }
                .padding(10)
                .background(.bar)
            }
        }
        .navigationTitle("Runners")
        .task { bundled = await state.runnerManager.bundledRunners() }
        .confirmationDialog("Delete \(confirmDelete?.displayName ?? "")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { r in
            Button("Delete", role: .destructive) { Task { await delete(r) } }
        } message: { r in
            Text("Removes \(r.directory.path). Games using this runner will fall back to the default runner.")
        }
    }

    private func setDefault(_ r: Runner) async {
        do { try await state.runnerManager.setDefault(r); state.defaultRunnerID = r.id }
        catch { state.report(error, title: "Cannot set default runner") }
    }

    private func delete(_ r: Runner) async {
        do { try await state.runnerManager.delete(r); await state.refresh() }
        catch { state.report(error, title: "Cannot delete runner") }
    }

    private func loadReleases() async {
        loadingReleases = true
        releasesError = nil
        defer { loadingReleases = false }
        do { releases = try await state.runnerManager.fetchReleases() }
        catch { releasesError = error.localizedDescription }
    }

    private func installBundled(_ b: BundledRunner) async {
        progress = InstallProgress("Starting…")
        defer { progress = nil }
        do {
            _ = try await state.runnerManager.installBundled(b) { p in Task { @MainActor in progress = p } }
            await state.refresh()
        } catch {
            state.report(error, title: "Offline install failed")
        }
    }

    private func install(_ rel: RunnerRelease) async {
        progress = InstallProgress("Starting…")
        defer { progress = nil }
        do {
            _ = try await state.runnerManager.install(release: rel) { p in Task { @MainActor in progress = p } }
            await state.refresh()
        } catch {
            state.report(error, title: "Download failed")
        }
    }

    private func importArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a wine-<kind>-<version>-osx64.tar.xz"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            progress = InstallProgress("Starting…")
            defer { progress = nil }
            do {
                _ = try await state.runnerManager.install(archive: url) { p in Task { @MainActor in progress = p } }
                await state.refresh()
            } catch {
                state.report(error, title: "Import failed")
            }
        }
    }
}

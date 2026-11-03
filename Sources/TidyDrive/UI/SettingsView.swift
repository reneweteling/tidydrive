import SwiftUI
import AppKit
import TidyDriveCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            projects.tabItem { Label("Projects", systemImage: "folder") }
            categories.tabItem { Label("Categories", systemImage: "square.grid.2x2") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 400)
    }

    private var general: some View {
        Form {
            Section {
                LabeledContent("Warn when the disk is") {
                    HStack {
                        Slider(value: Binding(get: { Double(settings.thresholdPercent) },
                                              set: { settings.thresholdPercent = Int($0) }), in: 70...98, step: 1)
                        Text("\(settings.thresholdPercent)% full").monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                }
                Text("One notification when the disk passes this point. It warns again only after usage drops 5 points below it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Open TidyDrive at login", isOn: Binding(get: { settings.launchAtLogin },
                                                                  set: { settings.launchAtLogin = $0 }))
                Toggle("Send crash reports", isOn: $settings.crashReports)
                Text("Crash reports go to Sentry with the app version only. No file names or paths are sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.crashReports) { _, _ in Telemetry.startIfEnabled() }
    }

    private var projects: some View {
        Form {
            Section("Project folders") {
                ForEach(settings.projectRoots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder")
                        Text(root).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            settings.projectRoots.removeAll { $0 == root }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .help("Stop scanning this folder")
                    }
                }
                Button("Add Folder…", action: addFolder)
            }
            Section {
                Stepper("Stale after \(settings.staleDays) days without a commit", value: $settings.staleDays, in: 7...365, step: 7)
                Picker("Large files from", selection: $settings.largeFileMB) {
                    ForEach([100, 250, 500, 1000, 2000], id: \.self) { mb in
                        Text(mb >= 1000 ? "\(mb / 1000) GB" : "\(mb) MB").tag(mb)
                    }
                }
                Text("Dependencies and build output of stale projects are selected by default. A project with uncommitted changes never counts as stale.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var categories: some View {
        Form {
            Section("Scan for") {
                ForEach(Category.allCases) { category in
                    Toggle(isOn: Binding(get: { settings.isEnabled(category) }, set: { settings.setEnabled(category, $0) })) {
                        Label(category.title, systemImage: category.symbol)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var about: some View {
        VStack(spacing: 12) {
            AppGlyph(size: 72).padding(.top, 18)
            Text("TidyDrive").font(.system(size: 22, weight: .bold))
            Text("Version \(updates.currentVersion)").foregroundStyle(.secondary)
            if updates.isUpdateAvailable, let latest = updates.latestVersion {
                Button("Download \(latest)") { updates.openReleasesPage() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            } else {
                Button(updates.isChecking ? "Checking…" : "Check for Updates") { Task { await updates.forceCheck() } }
                    .disabled(updates.isChecking)
            }
            if let error = updates.lastCheckError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Link("Website", destination: URL(string: "https://reneweteling.github.io/tidydrive/")!)
                Link("Source", destination: URL(string: "https://github.com/reneweteling/tidydrive")!)
                Link("Report a bug", destination: URL(string: "https://github.com/reneweteling/tidydrive/issues/new?template=bug.yml&version=\(updates.currentVersion)")!)
            }
            .font(.system(size: 12))
            Spacer()
            Text("© 2026 Felobo B.V. · PolyForm Noncommercial 1.0.0").font(.caption).foregroundStyle(.secondary)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose the folders that hold your projects."
        guard panel.runModal() == .OK else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for url in panel.urls {
            let path = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
            if !settings.projectRoots.contains(path) { settings.projectRoots.append(path) }
        }
    }
}

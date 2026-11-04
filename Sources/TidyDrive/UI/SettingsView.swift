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
        .frame(width: 540, height: 480)
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
                if settings.keptProjects.isEmpty {
                    Text("None yet. Pin a project in the review window, or add one here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.keptProjects, id: \.self) { project in
                    HStack {
                        Image(systemName: "pin.fill").foregroundStyle(Theme.accent)
                        Text(project).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button { settings.release(project) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .help("Offer this project's files for cleaning again")
                    }
                }
                Button("Keep a Project…", action: keepFolder)
            } header: {
                Text("Kept projects")
            } footer: {
                Text("Projects you are working on. TidyDrive never offers their dependencies, build output or large files.")
                    .font(.caption).foregroundStyle(.secondary)
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
        AboutView(updates: updates)
    }

    private func keepFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Keep"
        panel.message = "Choose the projects TidyDrive should leave alone."
        if let first = settings.projectRoots.first {
            panel.directoryURL = URL(fileURLWithPath: (first as NSString).expandingTildeInPath)
        }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { settings.keep(url.path) }
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

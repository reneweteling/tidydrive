import AppKit
import SwiftUI
import Combine
import TidyDriveCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var reviewWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    private let model = AppModel.shared
    private let settings = AppSettings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Telemetry.startIfEnabled()
        Telemetry.breadcrumb("app.launched")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(rootView: PopoverView(
            model: model, settings: settings,
            openReview: { [weak self] category in self?.showReview(category) },
            openSettings: { [weak self] in self?.showSettings() },
            quit: { NSApp.terminate(nil) }
        ))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        // The menu bar shows the percentage once the disk is over the threshold.
        model.$disk.combineLatest(settings.$thresholdPercent)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        model.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        NotificationManager.shared.setUp()
        NotificationManager.shared.onCleanUp = { [weak self] in self?.showReview(nil) }
        model.onThresholdCrossed = { status, result in
            let selected = AppModel.shared.selectedSize
            NotificationManager.shared.notifyDiskFull(status, reclaimable: selected > 0 ? selected : result?.totalSize)
        }
        model.startMonitoring()

        // First launch: scan in the background so the popover has numbers.
        if model.result == nil || (model.result?.finishedAt.timeIntervalSinceNow ?? 0) < -6 * 3600 {
            Task { await model.scan() }
        }
        Task { await UpdateChecker.shared.checkIfNeeded() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Status item

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        switch model.phase {
        case .scanning, .cleaning: symbol = "arrow.triangle.2.circlepath"
        case .idle: symbol = "internaldrive"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TidyDrive")
        image?.isTemplate = true
        button.image = image
        if model.isOverThreshold, let disk = model.disk {
            button.title = " \(disk.usedPercent)%"
            button.toolTip = "TidyDrive: disk \(disk.usedPercent)% full"
        } else {
            button.title = ""
            button.toolTip = model.disk.map { "TidyDrive: \(ByteFormat.string($0.available)) free" } ?? "TidyDrive"
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.checkDisk()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Windows

    func showReview(_ category: Category?) {
        popover.performClose(nil)
        model.focusedCategory = category
        if reviewWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ReviewView(model: model)))
            window.title = "TidyDrive"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 980, height: 640))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("TidyDriveReview")
            reviewWindow = window
        }
        present(reviewWindow!)
    }

    func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings, updates: UpdateChecker.shared)))
            window.title = "TidyDrive Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        present(settingsWindow!)
    }

    private func present(_ window: NSWindow) {
        // A menu bar app has no Dock icon; switch to a regular app while a
        // window is open so it can come to the front and take keyboard focus.
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            let open = [self.reviewWindow, self.settingsWindow].compactMap { $0 }.filter(\.isVisible)
            if open.isEmpty { NSApp.setActivationPolicy(.accessory) }
        }
        if (notification.object as? NSWindow) === settingsWindow {
            // New project folders or categories should show up right away.
            Task { await model.scan() }
        }
    }
}

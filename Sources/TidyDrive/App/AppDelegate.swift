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
    private var diskMapWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    private let model = AppModel.shared
    private let settings = AppSettings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
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
            openDiskMap: { [weak self] in self?.showDiskMap() },
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

        // `open TidyDrive.app --args --show review|diskmap|settings` opens a
        // window straight away, for when the menu bar icon is hidden behind
        // the notch or a crowded menu bar.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--show"), i + 1 < args.count {
            switch args[i + 1] {
            case "review": showReview(nil)
            case "diskmap": showDiskMap()
            case "settings": showSettings()
            default: break
            }
        }
    }

    /// A second launch (double-clicking the app while it runs) opens the
    /// review window, so TidyDrive is reachable without its menu bar icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showReview(nil) }
        return true
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

    // MARK: - Main menu

    /// The menu bar shows while a window is open (the app is `.regular` then),
    /// so it needs the usual items: Settings on ⌘, and the shortcuts people
    /// expect for closing, hiding and quitting.
    private func installMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(menuShowSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Review", action: #selector(menuShowReview), keyEquivalent: "1").target = self
        appMenu.addItem(withTitle: "Disk Map", action: #selector(menuShowDiskMap), keyEquivalent: "2").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide TidyDrive", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit TidyDrive", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "TidyDrive")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: editMenu, title: "Edit")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Review", action: #selector(menuShowReview), keyEquivalent: "").target = self
        windowMenu.addItem(withTitle: "Disk Map", action: #selector(menuShowDiskMap), keyEquivalent: "").target = self
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: windowMenu, title: "Window")

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc private func menuShowSettings() { showSettings() }
    @objc private func menuShowReview() { showReview(nil) }
    @objc private func menuShowDiskMap() { showDiskMap() }

    // MARK: - Windows

    func showReview(_ category: Category?) {
        popover.performClose(nil)
        model.focusedCategory = category
        if reviewWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ReviewView(
                model: model,
                openSettings: { [weak self] in self?.showSettings() },
                openDiskMap: { [weak self] in self?.showDiskMap() }
            )))
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

    func showDiskMap() {
        popover.performClose(nil)
        if diskMapWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: DiskMapView()))
            window.title = "TidyDrive Disk Map"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1080, height: 700))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("TidyDriveDiskMap")
            diskMapWindow = window
        }
        present(diskMapWindow!)
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
        let wasAccessory = NSApp.activationPolicy() != .regular
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        guard wasAccessory,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // AppKit quirk: right after switching from .accessory to .regular the
        // menu bar stays on the previous app. Handing focus to the Dock and
        // then taking it back makes macOS show our menu bar.
        dock.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            let open = [self.reviewWindow, self.settingsWindow, self.diskMapWindow].compactMap { $0 }.filter(\.isVisible)
            if open.isEmpty { NSApp.setActivationPolicy(.accessory) }
        }
        if (notification.object as? NSWindow) === settingsWindow {
            // New project folders or categories should show up right away.
            Task { await model.scan() }
        }
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

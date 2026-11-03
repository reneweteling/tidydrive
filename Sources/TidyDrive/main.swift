import AppKit
import TidyDriveCore

if CommandLineMode.runIfRequested() { exit(0) }
if MainActor.assumeIsolated({ AssetRenderer.runIfRequested() }) { exit(0) }

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()

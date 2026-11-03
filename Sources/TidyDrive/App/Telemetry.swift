import Foundation
import Sentry

/// Crash reports through Sentry. Switched off in Settings, General. Events
/// carry the app version and category names, never paths or file names,
/// because those would reveal project and client names.
enum Telemetry {
    private static let dsn = "https://37d270a251d1cdce69663c622d485ac4@o157871.ingest.us.sentry.io/4512369271832576"
    private static var started = false

    @MainActor
    static func startIfEnabled() {
        // A bare binary from `swift build` has no bundle and no version; only
        // the packaged app reports.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let enabled = AppSettings.shared.crashReports
        if enabled, !started {
            SentrySDK.start { options in
                options.dsn = dsn
                options.releaseName = "tidydrive@\(appVersion)"
                options.environment = environment
                options.sendDefaultPii = false
                options.enableAutoSessionTracking = true
                options.enableAppHangTracking = true
                options.enableCrashHandler = true
                options.attachStacktrace = true
                options.tracesSampleRate = 0
                options.maxBreadcrumbs = 50
                options.beforeSend = { event in
                    // Belt and braces: strip anything that looks like a path
                    // from messages before they leave the machine.
                    if let message = event.message?.formatted {
                        event.message = SentryMessage(formatted: scrub(message))
                    }
                    event.exceptions?.forEach { $0.value = scrub($0.value) }
                    return event
                }
            }
            started = true
        } else if !enabled, started {
            SentrySDK.close()
            started = false
        }
    }

    static func breadcrumb(_ name: String, data: [String: Any] = [:]) {
        guard started else { return }
        let crumb = Breadcrumb(level: .info, category: "usage")
        crumb.message = name
        crumb.data = data
        SentrySDK.addBreadcrumb(crumb)
    }

    static func captureCleanupFailure(category: String, action: String) {
        guard started else { return }
        SentrySDK.capture(message: "Cleanup failed") { scope in
            scope.setLevel(.warning)
            scope.setTag(value: category, key: "category")
            scope.setTag(value: action, key: "action")
        }
    }

    static func scrub(_ text: String) -> String {
        text.replacingOccurrences(of: #"(/Users|/Volumes|/private|~)/[^\s'"]+"#, with: "<path>", options: .regularExpression)
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private static var environment: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }
}

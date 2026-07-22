import Foundation
import CoreGraphics

/// A small, testable description of a ScreenCaptureKit window. Keeping the
/// policy independent of `SCWindow` lets us exercise it without screen-recording
/// permission or a particular set of running applications.
struct WindowCandidateMetadata {
    enum ApplicationKind {
        case regular
        case accessory
        case prohibited
    }

    let title: String?
    let applicationName: String?
    let bundleIdentifier: String?
    let processID: Int32
    let frame: CGRect
    let windowLayer: Int
    let isOnScreen: Bool
    let applicationKind: ApplicationKind
    let isTerminated: Bool
}

enum WindowCandidatePolicy {
    private static let infrastructureBundleIdentifiers: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.dock",
        "com.apple.loginwindow",
        "com.apple.notificationcenterui",
        "com.apple.screencaptureui",
        "com.apple.screensaver.engine",
        "com.apple.spotlight",
        "com.apple.systemuiserver",
        "com.apple.wallpaper",
        "com.apple.wallpaper.agent",
        "com.apple.windowmanager"
    ]

    private static let infrastructureApplicationNames: Set<String> = [
        "control center",
        "dock",
        "loginwindow",
        "notification center",
        "screencaptureui",
        "screensaverengine",
        "spotlight",
        "systemuiserver",
        "wallpaper",
        "window server",
        "windowmanager"
    ]

    static func shouldInclude(
        _ candidate: WindowCandidateMetadata,
        currentProcessID: Int32,
        currentBundleIdentifier: String?
    ) -> Bool {
        guard candidate.isOnScreen,
              !candidate.isTerminated,
              candidate.processID != currentProcessID,
              (0...3).contains(candidate.windowLayer),
              candidate.frame.origin.x.isFinite,
              candidate.frame.origin.y.isFinite,
              candidate.frame.width.isFinite,
              candidate.frame.height.isFinite,
              candidate.frame.width >= 160,
              candidate.frame.height >= 120
        else { return false }

        let title = normalizedText(candidate.title)
        let applicationName = normalizedText(candidate.applicationName)
        guard title != nil || applicationName != nil else { return false }

        let bundleIdentifier = normalizedIdentifier(candidate.bundleIdentifier)
        if let current = normalizedIdentifier(currentBundleIdentifier),
           bundleIdentifier == current {
            return false
        }
        if let bundleIdentifier,
           infrastructureBundleIdentifiers.contains(bundleIdentifier) {
            return false
        }
        if bundleIdentifier == nil,
           let applicationName,
           infrastructureApplicationNames.contains(applicationName.lowercased()) {
            return false
        }

        switch candidate.applicationKind {
        case .regular:
            // A normal user application may expose an untitled main window
            // (notably some iOS-on-Mac and Wine clients), but tiny untitled
            // utility panels should not become capture choices.
            if title != nil { return true }
            return candidate.windowLayer == 0
                && candidate.frame.width >= 320
                && candidate.frame.height >= 200
        case .accessory:
            // A few Java/Wine/Electron chess clients present their main window
            // as an accessory process. Keep only a substantial layer-0 window,
            // which still removes menu-bar popovers and helper panels.
            return candidate.windowLayer == 0
                && candidate.frame.width >= 320
                && candidate.frame.height >= 200
        case .prohibited:
            return false
        }
    }

    static func displayTitle(
        applicationName rawApplicationName: String?,
        windowTitle rawWindowTitle: String?
    ) -> String {
        let applicationName = normalizedText(rawApplicationName)
        let windowTitle = normalizedText(rawWindowTitle)

        switch (applicationName, windowTitle) {
        case let (applicationName?, windowTitle?)
            where applicationName.compare(
                windowTitle,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame:
            return applicationName
        case let (applicationName?, windowTitle?):
            return "\(applicationName) — \(windowTitle)"
        case let (applicationName?, nil):
            return applicationName
        case let (nil, windowTitle?):
            return windowTitle
        case (nil, nil):
            return "未知窗口"
        }
    }

    static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func normalizedIdentifier(_ value: String?) -> String? {
        normalizedText(value)?.lowercased()
    }
}

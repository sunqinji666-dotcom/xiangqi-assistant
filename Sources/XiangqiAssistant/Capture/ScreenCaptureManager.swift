import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

// MARK: - Screen Capture Manager

/// Captures screenshots using the system window list and keeps the selectable
/// sources limited to user-facing application windows.
@MainActor
class ScreenCaptureManager: ObservableObject {

    @Published var hasPermission: Bool = false
    @Published private(set) var availableWindows: [SCWindow] = []
    @Published private(set) var lastCaptureError: String?

    private struct WindowIdentity {
        let windowID: CGWindowID
        let processID: Int32
        let bundleIdentifier: String?
        let title: String?
        let frame: CGRect

        var stableIdentifier: String {
            let owner = WindowCandidatePolicy.normalizedIdentifier(bundleIdentifier)
                ?? "pid:\(processID)"
            let normalizedTitle = WindowCandidatePolicy.normalizedText(title) ?? "(untitled)"
            return "\(owner)|\(normalizedTitle.lowercased())"
        }
    }

    private var selectedWindow: SCWindow?
    private var sharableContent: SCShareableContent?
    private var selectedDisplayID: CGDirectDisplayID?
    private(set) var isFullScreenCaptureSelected = true

    // MARK: Permission and window refresh

    func requestPermission() async {
        // Ask macOS to register/refresh Screen Recording consent before querying
        // ScreenCaptureKit. Keeping the same signed app identity prevents this
        // from becoming a repeated permission request after each build.
        if !CGPreflightScreenCaptureAccess() {
            guard CGRequestScreenCaptureAccess() else {
                hasPermission = false
                availableWindows = []
                selectedWindow = nil
                isFullScreenCaptureSelected = false
                print("[ScreenCapture] Screen Recording permission not granted")
                return
            }
        }

        do {
            let content = try await loadShareableContent()
            applyShareableContent(content)
            hasPermission = true
        } catch {
            hasPermission = false
            availableWindows = []
            selectedWindow = nil
            isFullScreenCaptureSelected = false
            lastCaptureError = "无法刷新窗口列表：\(error.localizedDescription)"
            print("[ScreenCapture] Permission denied or error: \(error)")
        }
    }

    // MARK: Window Selection

    /// Screen frame of the currently selected window (Quartz global screen
    /// coordinates, origin at the top-left of the primary display).
    var selectedWindowFrame: CGRect? { selectedWindow?.frame }
    var selectedWindowID: CGWindowID? { selectedWindow?.windowID }
    var selectedWindowBundleIdentifier: String? {
        selectedWindow?.owningApplication?.bundleIdentifier
    }
    var selectedWindowApplicationName: String? {
        selectedWindow?.owningApplication?.applicationName
    }
    var selectedWindowTitle: String? { selectedWindow?.title }
    var selectedWindowDisplayID: UInt32? {
        guard let frame = selectedWindow?.frame else { return nil }
        return sharableContent?.displays.max { lhs, rhs in
            let left = lhs.frame.intersection(frame)
            let right = rhs.frame.intersection(frame)
            return left.width * left.height < right.width * right.height
        }?.displayID
    }
    var selectedWindowStableIdentifier: String? {
        selectedWindow.map(identity(for:))?.stableIdentifier
    }
    var selectedCaptureSourceKey: String? {
        if let selectedWindow {
            return BoardGeometrySourceStore.windowSourceKey(
                bundleIdentifier: selectedWindow.owningApplication?.bundleIdentifier,
                applicationName: selectedWindow.owningApplication?.applicationName
            )
        }
        guard isFullScreenCaptureSelected else { return nil }
        return BoardGeometrySourceStore.displaySourceKey(
            displayID: UInt32(selectedDisplayID ?? CGMainDisplayID())
        )
    }

    func displayTitle(for window: SCWindow) -> String {
        WindowCandidatePolicy.displayTitle(
            applicationName: window.owningApplication?.applicationName,
            windowTitle: window.title
        )
    }

    func selectWindow(_ window: SCWindow) {
        selectedWindow = availableWindows.first(where: { $0.windowID == window.windowID })
            ?? window
        isFullScreenCaptureSelected = false
    }

    func clearWindowSelection() {
        selectedWindow = nil
        isFullScreenCaptureSelected = true
    }

    /// Preserve the distinction between a user explicitly choosing full-screen
    /// capture and a stale menu item referring to a window that no longer
    /// exists. An unavailable target must never silently become full-screen.
    func markWindowSelectionUnavailable() {
        selectedWindow = nil
        isFullScreenCaptureSelected = false
    }

    func selectDisplay(_ displayID: UInt32?) {
        selectedDisplayID = displayID.map { CGDirectDisplayID($0) }
        if selectedWindow == nil { isFullScreenCaptureSelected = true }
    }

    /// Find the best matching user window by title, application name, or bundle
    /// identifier. Filtering remains independent from these chess keywords.
    func autoSelectWindow(titleContaining query: String) -> SCWindow? {
        let matches = availableWindows.filter { window in
            window.title?.localizedCaseInsensitiveContains(query) == true
                || window.owningApplication?.applicationName
                    .localizedCaseInsensitiveContains(query) == true
                || window.owningApplication?.bundleIdentifier
                    .localizedCaseInsensitiveContains(query) == true
        }
        let match = matches.max { lhs, rhs in
            lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }
        if let match {
            selectedWindow = match
            isFullScreenCaptureSelected = false
        }
        return match
    }

    func autoSelectWindow(bundleIdentifier: String) -> SCWindow? {
        let matches = availableWindows.filter {
            $0.owningApplication?.bundleIdentifier == bundleIdentifier
        }
        let match = matches.max { lhs, rhs in
            lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }
        if let match {
            selectedWindow = match
            isFullScreenCaptureSelected = false
        }
        return match
    }

    // MARK: Screenshot

    /// Capture the selected window, or the explicitly selected display when no
    /// window is selected. The method never silently substitutes a full-display
    /// image for a selected-window image because those coordinate spaces differ.
    func captureFrame() async -> CGImage? {
        lastCaptureError = nil
        let image: CGImage?
        if let window = selectedWindow {
            image = await captureWindow(window)
        } else if isFullScreenCaptureSelected {
            image = captureFullScreen()
        } else {
            lastCaptureError = "目标窗口已关闭或暂时不可见，请刷新后重新选择"
            image = nil
        }
        if image == nil {
            let selected = selectedWindow.map {
                "\(displayTitle(for: $0)) [\($0.windowID)]"
            } ?? "nil"
            let available = availableWindows.map {
                "\(displayTitle(for: $0)) [\($0.windowID)]"
            }.joined(separator: "; ")
            let diagnostic = "permission=\(hasPermission)\nselected=\(selected)\nerror=\(lastCaptureError ?? "none")\navailable=\(available)\n"
            guard let cacheDirectory = FileManager.default.urls(
                for: .cachesDirectory, in: .userDomainMask
            ).first else { return nil }
            try? diagnostic.write(
                to: cacheDirectory.appendingPathComponent(
                    "xiangqi-assistant-capture-error.txt"
                ),
                atomically: true,
                encoding: .utf8
            )
        }
        return image
    }

    // MARK: Private

    private func captureWindow(_ window: SCWindow) async -> CGImage? {
        if let image = windowListSnapshot(window) {
            return image
        }
        if let image = await screenCaptureKitSnapshot(window) {
            return image
        }

        // Some games recreate a Metal/legacy window while changing space or
        // focus. Re-enumerate and rebind only to the same stable application
        // identity; never match another program solely because its title agrees.
        do {
            let content = try await loadShareableContent()
            applyShareableContent(content, preserving: identity(for: window))
            guard let refreshed = selectedWindow else {
                lastCaptureError = "目标窗口已关闭或暂时不可见，请刷新后重新选择"
                return nil
            }
            if let image = windowListSnapshot(refreshed) {
                return image
            }
            if let image = await screenCaptureKitSnapshot(refreshed) {
                return image
            }
            lastCaptureError = "目标窗口截图失败；请保持窗口可见，或明确选择“全屏捕获”"
        } catch {
            lastCaptureError = "无法刷新目标窗口：\(error.localizedDescription)"
        }
        return nil
    }

    private func windowListSnapshot(_ window: SCWindow) -> CGImage? {
        CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            window.windowID,
            [.bestResolution, .boundsIgnoreFraming]
        )
    }

    /// Modern window-only fallback for Metal/Electron/iOS-on-Mac clients that
    /// can be enumerated by ScreenCaptureKit but return no CGWindow image. It
    /// uses the same window-relative coordinate space and never captures a
    /// display as a substitute.
    private func screenCaptureKitSnapshot(_ window: SCWindow) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * 2))
        configuration.height = max(1, Int(window.frame.height * 2))
        configuration.showsCursor = false
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            print("[ScreenCapture] Window-only ScreenCaptureKit fallback failed: \(error)")
            return nil
        }
    }

    private func captureFullScreen() -> CGImage? {
        let displayID = selectedDisplayID ?? CGMainDisplayID()
        let image = CGDisplayCreateImage(displayID)
        if image == nil {
            lastCaptureError = "无法取得当前屏幕截图，请检查屏幕录制权限"
        }
        return image
    }

    private func loadShareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
    }

    private func applyShareableContent(
        _ content: SCShareableContent,
        preserving explicitIdentity: WindowIdentity? = nil
    ) {
        let previousIdentity = explicitIdentity ?? selectedWindow.map(identity(for:))
        sharableContent = content
        let userWindows = content.windows.filter(isUserWindow(_:))
        availableWindows = removeAuxiliaryUntitledWindows(from: userWindows)
            .sorted(by: windowSortOrder(_:_:))

        guard let previousIdentity else { return }
        selectedWindow = reboundWindow(for: previousIdentity, in: availableWindows)
        isFullScreenCaptureSelected = false
    }

    private func isUserWindow(_ window: SCWindow) -> Bool {
        guard let owner = window.owningApplication else { return false }
        let runningApplication = NSRunningApplication(
            processIdentifier: owner.processID
        )
        let applicationKind: WindowCandidateMetadata.ApplicationKind
        switch runningApplication?.activationPolicy {
        case .regular:
            applicationKind = .regular
        case .accessory:
            applicationKind = .accessory
        case .prohibited, nil:
            applicationKind = .prohibited
        @unknown default:
            applicationKind = .prohibited
        }

        return WindowCandidatePolicy.shouldInclude(
            WindowCandidateMetadata(
                title: window.title,
                applicationName: owner.applicationName,
                bundleIdentifier: owner.bundleIdentifier,
                processID: owner.processID,
                frame: window.frame,
                windowLayer: window.windowLayer,
                isOnScreen: window.isOnScreen,
                applicationKind: applicationKind,
                isTerminated: runningApplication?.isTerminated ?? false
            ),
            currentProcessID: ProcessInfo.processInfo.processIdentifier,
            currentBundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    private func windowSortOrder(_ lhs: SCWindow, _ rhs: SCWindow) -> Bool {
        let left = displayTitle(for: lhs)
        let right = displayTitle(for: rhs)
        let comparison = left.localizedStandardCompare(right)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        let leftArea = lhs.frame.width * lhs.frame.height
        let rightArea = rhs.frame.width * rhs.frame.height
        if leftArea != rightArea { return leftArea > rightArea }
        return lhs.windowID < rhs.windowID
    }

    private func removeAuxiliaryUntitledWindows(
        from windows: [SCWindow]
    ) -> [SCWindow] {
        windows.filter { candidate in
            guard WindowCandidatePolicy.normalizedText(candidate.title) == nil,
                  let processID = candidate.owningApplication?.processID
            else { return true }

            let candidateArea = candidate.frame.width * candidate.frame.height
            let hasLargerTitledWindow = windows.contains { other in
                guard other.windowID != candidate.windowID,
                      other.owningApplication?.processID == processID,
                      WindowCandidatePolicy.normalizedText(other.title) != nil
                else { return false }
                let otherArea = other.frame.width * other.frame.height
                return otherArea >= candidateArea * 1.5
            }
            return !hasLargerTitledWindow
        }
    }

    private func identity(for window: SCWindow) -> WindowIdentity {
        WindowIdentity(
            windowID: window.windowID,
            processID: window.owningApplication?.processID ?? 0,
            bundleIdentifier: window.owningApplication?.bundleIdentifier,
            title: window.title,
            frame: window.frame
        )
    }

    private func reboundWindow(
        for identity: WindowIdentity,
        in windows: [SCWindow]
    ) -> SCWindow? {
        if let exact = windows.first(where: { $0.windowID == identity.windowID }) {
            return exact
        }

        let normalizedTitle = WindowCandidatePolicy.normalizedText(identity.title)
        let sameProcess = windows.filter {
            $0.owningApplication?.processID == identity.processID
                && WindowCandidatePolicy.normalizedText($0.title) == normalizedTitle
        }
        if let closest = closestWindow(to: identity.frame, in: sameProcess) {
            return closest
        }

        // PID may change when an application recreates/relaunches its window.
        // Require both bundle ID and a non-empty exact title in that case.
        if let bundleIdentifier = identity.bundleIdentifier,
           let normalizedTitle {
            let sameApplication = windows.filter {
                $0.owningApplication?.bundleIdentifier == bundleIdentifier
                    && WindowCandidatePolicy.normalizedText($0.title) == normalizedTitle
            }
            return closestWindow(to: identity.frame, in: sameApplication)
        }
        return nil
    }

    private func closestWindow(to frame: CGRect, in windows: [SCWindow]) -> SCWindow? {
        windows.min { lhs, rhs in
            frameDistance(lhs.frame, frame) < frameDistance(rhs.frame, frame)
        }
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.midX - rhs.midX)
            + abs(lhs.midY - rhs.midY)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }
}

// MARK: - Window List View Model

extension SCWindow: @retroactive Identifiable {
    public var id: CGWindowID { windowID }
}

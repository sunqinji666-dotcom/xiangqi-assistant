import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

// MARK: - Screen Capture Manager

/// Captures screenshots using ScreenCaptureKit (macOS 13+).
/// Falls back to CGWindowListCreateImage for older systems.
@MainActor
class ScreenCaptureManager: ObservableObject {

    @Published var hasPermission: Bool = false
    @Published var availableWindows: [SCWindow] = []
    @Published private(set) var lastCaptureError: String?

    private var selectedWindow: SCWindow?
    private var sharableContent: SCShareableContent?
    private var selectedDisplayID: CGDirectDisplayID?

    // MARK: Permission

    func requestPermission() async {
        // Ask macOS to register/refresh Screen Recording consent before querying
        // ScreenCaptureKit. Without this call, a newly signed local build can
        // repeatedly receive SCStreamErrorDomain -3801 even when the toggle is on.
        if !CGPreflightScreenCaptureAccess() {
            guard CGRequestScreenCaptureAccess() else {
                hasPermission = false
                print("[ScreenCapture] Screen Recording permission not granted")
                return
            }
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            sharableContent = content
            availableWindows = content.windows.filter {
                $0.title != nil && !$0.title!.isEmpty
            }
            hasPermission = true
        } catch {
            hasPermission = false
            print("[ScreenCapture] Permission denied or error: \(error)")
        }
    }

    // MARK: Window Selection

    /// Screen frame of the currently selected window (macOS coordinates, origin bottom-left)
    var selectedWindowFrame: CGRect? { selectedWindow?.frame }

    func selectWindow(_ window: SCWindow) {
        selectedWindow = window
    }

    func clearWindowSelection() {
        selectedWindow = nil
    }

    func selectDisplay(_ displayID: UInt32?) {
        selectedDisplayID = displayID.map { CGDirectDisplayID($0) }
    }

    /// Find the best matching window by title substring (case-insensitive).
    func autoSelectWindow(titleContaining query: String) -> SCWindow? {
        let match = availableWindows.first {
            $0.title?.localizedCaseInsensitiveContains(query) == true
        }
        if let match { selectedWindow = match }
        return match
    }

    // MARK: Screenshot

    /// Capture the selected window (or full screen if none selected).
    /// Returns a CGImage or nil on failure.
    func captureFrame() async -> CGImage? {
        lastCaptureError = nil
        let image: CGImage?
        if let window = selectedWindow {
            image = await captureWindow(window)
        } else {
            image = captureFullScreen()
        }
        if image == nil {
            let selected = selectedWindow.map {
                "\($0.title ?? "(untitled)") [\($0.windowID)]"
            } ?? "nil"
            let available = availableWindows.map {
                "\($0.title ?? "(untitled)") [\($0.windowID)]"
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
        // XQWizard's legacy/Metal window can leave SCScreenshotManager waiting
        // indefinitely even though it is listed by ScreenCaptureKit.  The
        // system window-list snapshot is synchronous and reliably handles
        // that kind of window, so prefer it for selected game windows.
        if let image = windowListSnapshot(window) {
            return image
        }

        // Some games recreate their Metal/legacy window while changing space
        // or focus.  A cached SCWindow then has the right title but cannot be
        // captured. Refresh the shareable-content list and retry with the
        // freshly issued window handle before declaring capture failure.
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            sharableContent = content
            availableWindows = content.windows.filter { $0.title?.isEmpty == false }
            if let refreshed = content.windows.first(where: { $0.windowID == window.windowID })
                ?? content.windows.first(where: { $0.title == window.title }) {
                selectedWindow = refreshed
                if let image = windowListSnapshot(refreshed) {
                    return image
                }
                // Last resort: capture the display containing the game
                // window. Board recognition can locate the board inside it.
                if let image = captureDisplay(containing: refreshed.frame) {
                    return image
                }
            }
            lastCaptureError = "未找到象棋巫师窗口，请在窗口列表中刷新后重新选择"
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

    private func captureDisplay(containing frame: CGRect) -> CGImage? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return nil
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success,
              let display = displays.first(where: { CGDisplayBounds($0).intersects(frame) })
        else { return nil }
        return CGDisplayCreateImage(display)
    }

    private func captureWindowOnce(_ window: SCWindow) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width  = Int(window.frame.width  * 2) // retina
        config.height = Int(window.frame.height * 2)
        config.scalesToFit = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            lastCaptureError = "象棋巫师截图失败：\(error.localizedDescription)"
            print("[ScreenCapture] Window capture failed: \(error)")
            return nil
        }
    }

    private func captureFullScreen() -> CGImage? {
        // Fallback: capture primary display
        let displayID = selectedDisplayID ?? CGMainDisplayID()
        let image = CGDisplayCreateImage(displayID)
        if image == nil {
            lastCaptureError = "无法取得当前屏幕截图，请检查屏幕录制权限"
        }
        return image
    }

}

// MARK: - Window List View Model

extension SCWindow: @retroactive Identifiable {
    public var id: CGWindowID { windowID }
}

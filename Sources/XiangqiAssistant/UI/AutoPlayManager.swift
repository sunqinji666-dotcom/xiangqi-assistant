import Foundation
import CoreGraphics
import AppKit

// MARK: - Pending Move

/// Carries everything needed to translate a UCI move into screen clicks.
struct PendingMove {
    let uci: String
    let boardNormalizedRect: CGRect  // board position within capture image (0–1)
    let windowFrame: CGRect?         // SCWindow/Quartz global coords (origin at main-screen top-left)
    /// Present after the user has manually framed the board. This is the
    /// authoritative source for clicks, especially with more than one display.
    let boardGeometry: BoardGeometry?
}

// MARK: - Auto Play Manager

/// Executes a chess move by simulating two mouse clicks at the piece's source
/// and destination squares on screen.
///
/// Requires Accessibility permission:
///   System Settings → Privacy & Security → Accessibility → add this app
@MainActor
class AutoPlayManager: ObservableObject {

    @Published var hasPermission: Bool = false

    // MARK: Permission

    func checkPermission() {
        hasPermission = AXIsProcessTrusted()
    }

    func requestPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(opts as CFDictionary)
        // Re-check after a short delay (user may have just granted it)
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            hasPermission = AXIsProcessTrusted()
        }
    }

    // MARK: Execute

    /// Clicks source square then destination square for the given UCI move.
    func execute(move: PendingMove) {
        guard hasPermission else {
            print("[AutoPlay] 缺少辅助功能权限，无法自动走棋")
            return
        }
        guard let uciMove = UCIMove(uci: move.uci) else { return }

        let fromPt: CGPoint
        let toPt: CGPoint
        if let geometry = move.boardGeometry {
            // Do not reconstruct a second-display point from a capture image:
            // the selector already gave us the exact global screen points.
            fromPt = quartzPoint(fromAppKit: geometry.screenPoint(col: uciMove.from.col, row: uciMove.from.row))
            toPt = quartzPoint(fromAppKit: geometry.screenPoint(col: uciMove.to.col, row: uciMove.to.row))
        } else if let windowFrame = move.windowFrame {
            let boardRect = screenRect(from: move.boardNormalizedRect, windowFrame: windowFrame)
            fromPt = intersection(col: uciMove.from.col, row: uciMove.from.row, in: boardRect)
            toPt = intersection(col: uciMove.to.col, row: uciMove.to.row, in: boardRect)
        } else {
            print("[AutoPlay] 没有可用的棋盘屏幕坐标")
            return
        }

        print("[AutoPlay] \(move.uci) -> \(fromPt) → \(toPt)")

        click(at: fromPt)
        Thread.sleep(forTimeInterval: 0.25)
        click(at: toPt)
    }

    // MARK: Coordinate Mapping

    /// Convert a normalized board rect (within capture image) + window frame
    /// into an actual screen rect in CGEvent coordinates (origin top-left).
    private func screenRect(from normalized: CGRect, windowFrame: CGRect) -> CGRect {
        // SCWindow.frame is already in the same global, top-left-origin
        // coordinate space used by CGEvent. On this Mac the upper external
        // display legitimately has a negative Y (for example -845). Flipping
        // it as if it were an NSWindow/AppKit frame turns that point into a
        // positive main-display coordinate and sends the mouse to the top edge
        // of the main screen.
        let bx = windowFrame.minX + normalized.minX * windowFrame.width
        let by = windowFrame.minY + normalized.minY * windowFrame.height
        let bw = normalized.width  * windowFrame.width
        let bh = normalized.height * windowFrame.height
        return CGRect(x: bx, y: by, width: bw, height: bh)
    }

    /// Maps a board intersection (col 0-8, row 0-9) to a Quartz screen point.
    private func intersection(col: Int, row: Int, in boardRect: CGRect) -> CGPoint {
        let x = boardRect.minX + boardRect.width  * CGFloat(col) / 8.0
        let y = boardRect.minY + boardRect.height * CGFloat(row) / 9.0
        return CGPoint(x: x, y: y)
    }

    private var mainScreenMaxY: CGFloat {
        NSScreen.main?.frame.maxY ?? CGFloat(CGDisplayBounds(CGMainDisplayID()).height)
    }

    private func quartzPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: mainScreenMaxY - point.y)
    }

    // MARK: CGEvent Mouse Click

    private func click(at point: CGPoint) {
        let src  = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                           mouseCursorPosition: point, mouseButton: .left)
        let up   = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                           mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.04)
        up?.post(tap: .cghidEventTap)
    }

}

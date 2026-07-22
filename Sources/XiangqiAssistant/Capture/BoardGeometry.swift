import Foundation
import CoreGraphics
import AppKit

// MARK: - BoardGeometry
// Stores the screen position of the chess board's top-left and bottom-right
// corner intersections. Once calibrated, Vision detection is never used again.

struct BoardGeometry: Codable {
    // Screen coordinates (macOS, origin bottom-left).
    // topLeft  = position of the piece at column 0, row 0 (black's left rook)
    // bottomRight = position of the piece at column 8, row 9 (red's right rook)
    var topLeft: CGPoint
    var bottomRight: CGPoint
    /// Display used by the selector. Optional keeps older saved files readable.
    var screenFrame: CGRect?
    var displayID: UInt32?

    /// The axis-aligned bounding rect of the board in screen coordinates.
    var screenRect: CGRect {
        CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width:  abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }

    /// Linear interpolation: map grid (col 0-8, row 0-9) to screen point.
    func screenPoint(col: Int, row: Int) -> CGPoint {
        CGPoint(
            x: topLeft.x + (bottomRight.x - topLeft.x) * CGFloat(col) / 8.0,
            y: topLeft.y + (bottomRight.y - topLeft.y) * CGFloat(row) / 9.0
        )
    }

    /// Convert board screen rect to normalized image coords.
    /// `imageSize`  : size of the captured image (may be 2× on Retina).
    /// `windowFrame`: the SCWindow frame in Quartz global screen coords.
    func normalizedBoardRect(imageSize: CGSize, windowFrame: CGRect) -> CGRect {
        // Board rect in macOS screen coords
        let br = screenRect
        // SCWindow uses Quartz coordinates (top-left origin), whereas the
        // selector stores AppKit coordinates (bottom-left origin). Convert the
        // complete window rect once before comparing the two.
        let mainMaxY = NSScreen.main?.frame.maxY ?? CGFloat(CGDisplayBounds(CGMainDisplayID()).height)
        let appKitWindow = CGRect(
            x: windowFrame.minX,
            y: mainMaxY - windowFrame.maxY,
            width: windowFrame.width,
            height: windowFrame.height
        )
        // Relative to the window
        let relX = (br.minX - appKitWindow.minX) / appKitWindow.width
        let relY = (br.minY - appKitWindow.minY) / appKitWindow.height
        let relW = br.width  / appKitWindow.width
        let relH = br.height / appKitWindow.height
        // SCScreenshot Y-axis: top is y=0 in the image (opposite of macOS screen)
        return CGRect(x: relX, y: 1 - relY - relH, width: relW, height: relH)
    }

    /// Convert screen coordinates to normalized coordinates for a primary
    /// display capture. This avoids mixing NSScreen/AppKit coordinates with
    /// SCWindow coordinates when the chess window is on another display.
    func normalizedFullScreenRect() -> CGRect? {
        guard let screen = NSScreen.main, screen.frame.width > 0, screen.frame.height > 0 else {
            return nil
        }
        let captureFrame = screenFrame ?? screen.frame
        let br = screenRect
        let relX = (br.minX - captureFrame.minX) / captureFrame.width
        let relY = (br.minY - captureFrame.minY) / captureFrame.height
        let relW = br.width / captureFrame.width
        let relH = br.height / captureFrame.height
        return CGRect(x: relX, y: 1 - relY - relH, width: relW, height: relH)
    }

    // MARK: Persistence

    private static var saveURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XiangqiAssistant/board_geometry.json")
    }

    static func load() -> BoardGeometry? {
        guard let data = try? Data(contentsOf: saveURL),
              let geo  = try? JSONDecoder().decode(BoardGeometry.self, from: data)
        else { return nil }
        return geo
    }

    func save() {
        let dir = Self.saveURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Self.saveURL)
        }
    }

    static func delete() {
        try? FileManager.default.removeItem(at: saveURL)
    }
}

// MARK: - CGPoint Codable
extension CGPoint: @retroactive Codable {
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        self.init(x: try c.decode(CGFloat.self), y: try c.decode(CGFloat.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x); try c.encode(y)
    }
}

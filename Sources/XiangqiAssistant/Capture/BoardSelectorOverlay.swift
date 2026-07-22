import AppKit
import CoreGraphics

// MARK: - Board Selector Overlay
// Shows a full-screen dimmed overlay. User drags to select the chess board area.
// On completion, calls `onGeometry` with a BoardGeometry in macOS screen coords.

@MainActor
class BoardSelectorOverlay: NSObject {

    var onGeometry: ((BoardGeometry) -> Void)?
    var onCancel: (() -> Void)?

    private var overlayWindow: NSWindow?

    // MARK: Show / Hide

    func show(displayID: UInt32? = nil) {
        // Prefer the display containing the selected capture window. Falling
        // back to the pointer still supports explicit full-screen capture.
        let pointer = NSEvent.mouseLocation
        let requestedScreen = displayID.flatMap { requestedDisplayID in
            NSScreen.screens.first { screen in
                (screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber)?.uint32Value == requestedDisplayID
            }
        }
        guard let screen = requestedScreen
            ?? NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? NSScreen.main
        else { return }

        let selectorView = SelectorView()
        selectorView.onSelection = { [weak self] selectedRect in
            self?.dismiss()
            // selectedRect is in NSView coords (bottom-left origin, relative to screen)
            // Convert the drag rect (which is the board AREA) into two corner points.
            // topLeft  = macOS-coord top-left of rect  = (minX, maxY)
            // bottomRight = macOS-coord bottom-right   = (maxX, minY)
            let geo = BoardGeometry(
                topLeft:     CGPoint(x: selectedRect.minX, y: selectedRect.maxY),
                bottomRight: CGPoint(x: selectedRect.maxX, y: selectedRect.minY),
                screenFrame: screen.frame,
                displayID: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                windowNormalizedRect: nil
            )
            self?.onGeometry?(geo)
        }
        selectorView.onCancel = { [weak self] in
            self?.dismiss()
            self?.onCancel?()
        }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask:   [.borderless],
            backing:     .buffered,
            defer:       false
        )
        window.isOpaque          = false
        window.backgroundColor   = .clear
        window.level             = .screenSaver
        window.ignoresMouseEvents = false
        window.contentView       = selectorView
        window.makeKeyAndOrderFront(nil)
        overlayWindow = window
    }

    func dismiss() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
    }
}

// MARK: - Selector View

private class SelectorView: NSView {

    var onSelection: ((CGRect) -> Void)?
    var onCancel:    (() -> Void)?

    private var startPoint: CGPoint?
    private var selectionRect: CGRect?

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Dark overlay
        NSColor(calibratedWhite: 0, alpha: 0.55).setFill()
        bounds.fill()

        if let rect = selectionRect {
            // Punch out the selection (transparent)
            NSGraphicsContext.current?.compositingOperation = .clear
            rect.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            // Blue border around selection
            NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            border.stroke()

            // Crosshair dots at the two corners we'll store
            drawDot(at: CGPoint(x: rect.minX, y: rect.maxY), color: .systemBlue)  // top-left
            drawDot(at: CGPoint(x: rect.maxX, y: rect.minY), color: .systemBlue)  // bottom-right

            // Instruction label
            drawLabel("松开鼠标确认选择   Esc 取消",
                      at: CGPoint(x: rect.midX, y: rect.midY))
        } else {
            drawLabel("拖动鼠标框选棋盘区域   Esc 取消",
                      at: CGPoint(x: bounds.midX, y: bounds.midY))
        }
    }

    private func drawDot(at point: CGPoint, color: NSColor) {
        color.setFill()
        let r: CGFloat = 5
        let oval = NSBezierPath(ovalIn: CGRect(x: point.x - r, y: point.y - r,
                                               width: r * 2, height: r * 2))
        oval.fill()
    }

    private func drawLabel(_ text: String, at center: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .shadow: {
                let s = NSShadow(); s.shadowBlurRadius = 4
                s.shadowColor = .black; return s
            }()
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz  = str.size()
        str.draw(at: CGPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2))
    }

    // MARK: Mouse Events

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        selectionRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        selectionRect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width:  abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = selectionRect, rect.width > 20, rect.height > 20 else {
            selectionRect = nil; needsDisplay = true; return
        }
        // Convert NSView rect to screen rect
        if let screenRect = window?.convertToScreen(rect) {
            onSelection?(screenRect)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }  // Esc
    }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
}

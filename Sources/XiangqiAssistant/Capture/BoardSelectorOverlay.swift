import AppKit
import CoreGraphics

// MARK: - Board Selector Overlay
// Shows a full-screen dimmed overlay. User drags to select the chess board area.
// On completion, calls `onGeometry` with a BoardGeometry in macOS screen coords.

@MainActor
class BoardSelectorOverlay: NSObject {

    var onGeometry: ((BoardGeometry) -> Void)?
    var onCancel: (() -> Void)?

    private var overlayWindows: [NSWindow] = []

    // MARK: Show / Hide

    func show(displayID: UInt32? = nil) {
        dismiss()
        // A selected window can move between displays while ScreenCaptureKit
        // still exposes its previous display metadata. Put a selector on every
        // attached screen so the user's drag is always received on the screen
        // where the board is actually visible.
        let requestedScreen = displayID.flatMap { requestedDisplayID in
            NSScreen.screens.first { screen in
                (screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber)?.uint32Value == requestedDisplayID
            }
        }
        var screens = NSScreen.screens
        if let requestedScreen,
           let index = screens.firstIndex(of: requestedScreen) {
            screens.remove(at: index)
            screens.insert(requestedScreen, at: 0)
        }
        guard !screens.isEmpty else { return }

        for screen in screens {
            let selectorView = SelectorView()
            selectorView.onSelection = { [weak self] selectedRect in
                self?.dismiss()
                let geo = BoardGeometry(
                    topLeft: CGPoint(x: selectedRect.minX, y: selectedRect.maxY),
                    bottomRight: CGPoint(x: selectedRect.maxX, y: selectedRect.minY),
                    screenFrame: screen.frame,
                    displayID: (screen.deviceDescription[
                        NSDeviceDescriptionKey("NSScreenNumber")
                    ] as? NSNumber)?.uint32Value,
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
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.ignoresMouseEvents = false
            window.contentView = selectorView
            window.orderFrontRegardless()
            overlayWindows.append(window)
        }
        overlayWindows.first?.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll(keepingCapacity: false)
    }
}

// MARK: - Selector View

private class SelectorView: NSView {

    var onSelection: ((CGRect) -> Void)?
    var onCancel:    (() -> Void)?

    private var startPoint: CGPoint?
    private var selectionRect: CGRect?
    private lazy var confirmButton: NSButton = {
        let button = NSButton(title: "确认保存", target: self,
                              action: #selector(confirmSelection))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 16, weight: .semibold)
        button.isHidden = true
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installConfirmationButton()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installConfirmationButton()
    }

    private func installConfirmationButton() {
        addSubview(confirmButton)
        NSLayoutConstraint.activate([
            confirmButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            confirmButton.bottomAnchor.constraint(equalTo: bottomAnchor,
                                                   constant: -36),
            confirmButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 128),
            confirmButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 40)
        ])
    }

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
            drawLabel("框选完成后，点击下方「确认保存」   Esc 取消",
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
        confirmButton.isHidden = true
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
            selectionRect = nil
            confirmButton.isHidden = true
            needsDisplay = true
            return
        }
        startPoint = nil
        confirmButton.isHidden = false
        needsDisplay = true
    }

    @objc private func confirmSelection() {
        guard let rect = selectionRect,
              let screenRect = window?.convertToScreen(rect)
        else { return }
        onSelection?(screenRect)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }  // Esc
        if event.keyCode == 36, !confirmButton.isHidden { // Return
            confirmSelection()
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
}

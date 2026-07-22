import AppKit
import SwiftUI

// MARK: - Non-Activating Floating Panel

/// An NSPanel that floats above all windows and never steals keyboard focus.
class FloatingPanel: NSPanel {

    private static let interfaceScale: CGFloat = 1.2
    private static let panelSize = NSSize(
        width: 626 * interfaceScale,
        height: 472 * interfaceScale
    )

    init(contentView: some View) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [
                .borderless,
                .nonactivatingPanel,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating                    // 始终在最上层
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        hasShadow = true

        let hostingView = NSHostingView(
            rootView: contentView
                .scaleEffect(Self.interfaceScale)
                .frame(width: Self.panelSize.width,
                       height: Self.panelSize.height)
        )
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 16
        hostingView.layer?.masksToBounds = true
        self.contentView = hostingView

        // Position: bottom-right of main screen
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - Self.panelSize.width - 20
            let y = screen.visibleFrame.minY + 40
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    // Allow panel to become key only when user clicks inside it
    override var canBecomeKey: Bool { true }
}

// MARK: - Panel Manager (singleton)

@MainActor
class PanelManager: ObservableObject {
    static let shared = PanelManager()
    private var panel: FloatingPanel?

    func show(viewModel: AssistantViewModel) {
        if panel == nil {
            panel = FloatingPanel(contentView: AssistantView(vm: viewModel))
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggle(viewModel: AssistantViewModel) {
        if panel?.isVisible == true { hide() } else { show(viewModel: viewModel) }
    }
}

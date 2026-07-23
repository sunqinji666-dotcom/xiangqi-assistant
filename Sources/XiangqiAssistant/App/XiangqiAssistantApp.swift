import SwiftUI
import AppKit
import Combine
import ApplicationServices
import ImageIO

// MARK: - App Entry Point

@main
struct XiangqiAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No main window — the app lives entirely in the menu bar + floating panel
        Settings { EmptyView() }
    }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    private static let wizardBundleIdentifier = "com.jpcxc.xqwiphone"

    private struct WizardReplay {
        let board: BoardState
        let sideToMove: PieceSide
        let moves: [(side: PieceSide, move: UCIMove)]
        let positionKeys: [String]
    }

    private struct SavedBoardSnapshot: Codable {
        let board: BoardState
        let isReversed: Bool
    }

    private static let savedBoardSnapshotsKey =
        "xiangqiAssistant.savedBoardSnapshots.v1"

    private var statusItem: NSStatusItem?
    private let vm = AssistantViewModel()
    private let engine = PikafishEngine()
    private lazy var searchCoordinator = EngineSearchCoordinator(engine: engine)
    private let openingBook = OpeningBook.shared
    private let captureManager = ScreenCaptureManager()

    // Shared TemplateLibrary — used by both recognizer and calibrationManager
    private let templateLibrary = TemplateLibrary.load()
    private lazy var recognizer = BoardRecognizer(library: templateLibrary)
    private lazy var calibrationManager = CalibrationManager(
        captureManager: captureManager,
        recognizer: recognizer,
        library: templateLibrary
    )
    private let boardSelector = BoardSelectorOverlay()
    private let qwenReviewService = QwenBoardReviewService()
    /// A short-lived, lower-resource second engine supplies independently
    /// ranked candidates for Qwen without interrupting the green main search.
    private let qwenCandidateEngine = PikafishEngine(
        threads: 2,
        hashMegabytes: 128
    )

    private var analysisTask: Task<Void, Never>?
    private var aiReviewTask: Task<Void, Never>?
    private var qwenAdviceTask: Task<Void, Never>?
    private var qwenAdviceFEN: String?
    private var latestRecognizedBoardRect: CGRect?
    private var pendingAIReviewBoard: BoardState?
    private var pendingAIReviewSourceKey: String?
    private var searchRevision = 0
    private var activeSearchPositionKey: String?
    private var completedSearchPositionKey: String?

    private struct PonderHint {
        let originFEN: String
        let predictedMove: String
        let response: EngineMove
        let targetSide: PieceSide
        let mode: AnalysisMode
    }
    private var ponderHint: PonderHint?
    private var calibrationObserver: AnyCancellable?
    private var lastConfirmedBoard: BoardState?
    /// Most recent complete board produced by the screenshot recognizer before
    /// any user overrides. “恢复自动” reads from this clean source instead of
    /// from an already edited trusted board.
    private var latestRawRecognizedBoard: BoardState?
    private var currentSideToMove: PieceSide = .red
    /// Short rolling sample used throughout the game for per-square voting.
    private var baselineObservations: [BoardState] = []
    private var baselineOrientationVotes: [Bool] = []
    /// The visible board orientation is a session property, not a per-frame
    /// recognition result. Once a fresh scan establishes it, transient model
    /// noise, move highlights and animations must never flip the preview in
    /// the middle of a game.
    private var lockedPreviewIsReversed: Bool?
    private var forceEngineRefresh = false
    private var historyFromStart = false
    private var observedMoves: [(side: PieceSide, move: UCIMove)] = []
    private var recentPositionKeys: [String] = []
    /// XQWizard may expose only the currently visible score rows. Keep the
    /// rows already observed in this process so the exact position can still
    /// be replayed after older rows scroll out of its accessibility tree.
    private var wizardMoveRows: [Int: String] = [:]
    private var lastCaptureDiagnosticAt = Date.distantPast
    private var pendingBoardSelectionSourceKey: String?
    private enum ManualSquareOverride {
        case empty
        case piece(Piece)
    }
    private enum AIReviewFlowError: LocalizedError {
        case captureFailed(String)
        case noBoardRect
        case sourceChanged

        var errorDescription: String? {
            switch self {
            case .captureFailed(let message): return message
            case .noBoardRect: return "尚未确定棋盘区域，请先完成一次识别"
            case .sourceChanged: return "复核期间目标窗口已变化，请重试"
            }
        }
    }
    /// Session-local user corrections. They intentionally outrank every
    /// screenshot until the user chooses “恢复自动识别” for that square.
    private var manualSquareOverrides: [BoardPosition: ManualSquareOverride] = [:]

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Wire UI callbacks
        vm.onToggleAnalysis = { [weak self] in
            guard let self else { return }
            if self.vm.isRunning { self.stopAnalysis() } else { self.startAnalysis() }
        }
        vm.onCalibrate = { [weak self] in
            self?.recognizer.captureWindowFrame = self?.captureManager.selectedWindowFrame
            Task { await self?.calibrationManager.performCalibration() }
        }
        vm.onWindowSelected = { [weak self] windowID in
            self?.selectCaptureSource(windowID: windowID)
        }
        vm.onRefreshWindows = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previousTarget = self.captureManager.selectedWindowStableIdentifier
                await self.captureManager.requestPermission()
                self.refreshWindowList()
                // Metal/iOS games can recreate the same visible window with a
                // new transient CGWindowID. Treat the stable app/title identity
                // as the source: rebinding that same target must not erase the
                // trusted board, manual corrections, or engine result.
                let sourceChanged = previousTarget
                    != self.captureManager.selectedWindowStableIdentifier
                if sourceChanged {
                    self.recognizer.resetCaptureSourceState()
                }
                self.migrateLegacyGeometryIfNeeded()
                self.applySavedGeometryForCurrentSource()
                if sourceChanged {
                    self.resetCaptureSession(message: "目标窗口已变化，正在重新锁定局面")
                }
            }
        }
        // This app intentionally does not install any mouse-control callback.
        // Accessibility is used solely to read XQWizard's score sheet for
        // position verification; it never sends click events to the board.
        vm.onSelectBoard = { [weak self] in
            guard let self else { return }
            self.pendingBoardSelectionSourceKey =
                self.captureManager.selectedCaptureSourceKey
            self.boardSelector.show(
                displayID: self.captureManager.selectedWindowDisplayID
            )
        }
        vm.onPlayerSideChanged = { _ in
            // Player side is presentation context only. Do not discard a
            // trusted position merely because the user changes the label.
            // Turn inference continues to come exclusively from board changes.
        }
        vm.onTurnSideChanged = { [weak self] side in
            self?.synchronizeTurn(to: side)
        }
        vm.onResyncPosition = { [weak self] in
            self?.requestPositionResync()
        }
        vm.onCorrectBoardSquare = { [weak self] position, correction in
            self?.correctBoardSquare(position, correction: correction)
        }
        vm.onFlipBoard = { [weak self] in
            self?.flipPreviewOrientation()
        }
        vm.onStartAIReview = { [weak self] in
            self?.startAIReview()
        }
        vm.onApplyAIReview = { [weak self] in
            self?.applyAIReview()
        }
        vm.onDismissAIReview = { [weak self] in
            self?.dismissAIReview()
        }
        vm.onForceAnalyzePreview = { [weak self] in
            self?.forceAnalyzeCurrentPreview()
        }
        vm.onRequestQwenAdvice = { [weak self] in
            self?.requestQwenAdvice()
        }
        vm.onAnalysisModeChanged = { [weak self] _ in
            guard let self else { return }
            self.searchCoordinator.cancel()
            self.searchRevision += 1
            self.activeSearchPositionKey = nil
            self.completedSearchPositionKey = nil
            self.ponderHint = nil
            self.forceEngineRefresh = true
            self.vm.bestMove = "--"
            self.vm.bestMoveCN = "正在切换棋力"
            self.vm.recommendedSide = nil
            self.resetDisplayedEvaluation()
            self.vm.searchDetail = "保留当前棋盘 · 正在用新棋力重新计算"
        }
        // Restore saved board geometry if any
        vm.hasBoardGeometry = false
        captureManager.selectDisplay(recognizer.boardGeometry?.displayID)
        boardSelector.onGeometry = { [weak self] geo in
            guard let self else { return }
            let sourceKey = self.pendingBoardSelectionSourceKey
                ?? self.captureManager.selectedCaptureSourceKey
            self.pendingBoardSelectionSourceKey = nil
            guard let sourceKey,
                  sourceKey == self.captureManager.selectedCaptureSourceKey
            else {
                self.vm.calibrationMessage = "❌ 目标窗口已变化，请重新框选"
                self.showBoardSelectionAlert(
                    title: "棋盘没有保存",
                    message: "框选期间目标窗口发生了变化，请重新选择目标程序后再框一次。"
                )
                return
            }

            var savedGeometry = geo
            if let windowFrame = self.captureManager.selectedWindowFrame {
                savedGeometry = geo.storingWindowRelativeRect(
                    windowFrame: windowFrame
                )
                guard savedGeometry.windowNormalizedRect != nil else {
                    self.vm.calibrationMessage = "❌ 框选区域不在目标窗口内，请重新框选"
                    self.showBoardSelectionAlert(
                        title: "棋盘没有保存",
                        message: "蓝框必须完整位于当前选择的象棋程序窗口内，请重新框选。"
                    )
                    return
                }
            }
            BoardGeometrySourceStore.save(
                geometry: savedGeometry,
                sourceKey: sourceKey
            )
            self.recognizer.resetCaptureSourceState()
            self.recognizer.boardGeometry = savedGeometry
            // Preserve an explicitly selected target window. The recognizer
            // already converts the screen rectangle into that window's image
            // coordinates. Only full-screen mode needs a display selection.
            if self.captureManager.selectedWindowID == nil {
                self.captureManager.selectDisplay(savedGeometry.displayID)
            }
            self.vm.selectedWindowID = self.captureManager.selectedWindowID
            self.vm.captureSourceUnavailable = false
            self.vm.hasBoardGeometry = true
            self.resetCaptureSession(message: "新棋盘区域已保存，正在重新锁定局面")
            self.vm.calibrationMessage = "✅ 棋盘已定位，手动框选成功"
            self.showBoardSelectionAlert(
                title: "棋盘已保存",
                message: "这个象棋程序的棋盘区域已经永久保存。现在可以点击播放开始识别。"
            )
        }
        boardSelector.onCancel = { [weak self] in
            self?.pendingBoardSelectionSourceKey = nil
        }

        // Reflect calibration state in VM
        vm.isCalibrated = recognizer.usesTheOneModel || templateLibrary.isCalibrated
        calibrationObserver = calibrationManager.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .success:
                    self.vm.isCalibrated = true
                    self.vm.calibrationMessage = ""
                case .failed(let msg):
                    self.vm.calibrationMessage = "❌ \(msg)"
                case .inProgress:
                    self.vm.calibrationMessage = "校准中，请稍候…"
                case .notCalibrated:
                    self.vm.isCalibrated = self.recognizer.usesTheOneModel
                    self.vm.calibrationMessage = ""
                }
            }

        setupMenuBar()

        Task { @MainActor in
            await captureManager.requestPermission()
            refreshWindowList()
            // Always prefer a concrete chess window when ScreenCaptureKit
            // exposes it. If XQWizard is temporarily omitted from that list,
            // retain the saved full-screen board geometry as the fallback.
            autoSelectChessApp()
            migrateLegacyGeometryIfNeeded()
            applySavedGeometryForCurrentSource()
            if vm.selectedWindowID == nil, let geometry = recognizer.boardGeometry {
                captureManager.clearWindowSelection()
                captureManager.selectDisplay(geometry.displayID)
                vm.selectedWindowID = nil
            }
            do {
                try await engine.start()
                vm.status = .idle
            } catch {
                vm.status = .error
                vm.errorMessage = error.localizedDescription
            }
        }

        PanelManager.shared.show(viewModel: vm)
    }

    // MARK: Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem?.button {
            btn.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "象棋助手")
            btn.action = #selector(togglePanel)
            btn.target = self
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "显示/隐藏面板",  action: #selector(togglePanel),    keyEquivalent: "")
        menu.addItem(withTitle: "开始分析",       action: #selector(startAnalysis),  keyEquivalent: "s")
        menu.addItem(withTitle: "停止",          action: #selector(stopAnalysis),   keyEquivalent: ".")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "一键校准",        action: #selector(startCalibration),  keyEquivalent: "k")
        menu.addItem(withTitle: "手动框选棋盘",     action: #selector(selectBoardManually), keyEquivalent: "b")
        menu.addItem(withTitle: "重置校准",         action: #selector(resetCalibration),    keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出",          action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
    }

    @objc private func togglePanel() {
        PanelManager.shared.toggle(viewModel: vm)
    }

    // MARK: Window Management

    /// Known chess app window title keywords (case-insensitive)
    private static let chessAppKeywords = [
        "野狐", "天天象棋", "QQ象棋", "象棋", "弈城", "棋院",
        "xiangqi", "chess", "pikafish", "飞刀"
    ]

    private func refreshWindowList() {
        let windows = captureManager.availableWindows.map {
            (id: $0.windowID, title: captureManager.displayTitle(for: $0))
        }
        vm.availableWindows = windows
        vm.selectedWindowID = captureManager.selectedWindowID
        vm.captureSourceUnavailable = captureManager.selectedWindowID == nil
            && !captureManager.isFullScreenCaptureSelected
    }

    private func autoSelectChessApp() {
        guard captureManager.selectedWindowID == nil else { return }
        if let win = captureManager.autoSelectWindow(
            bundleIdentifier: Self.wizardBundleIdentifier
        ) {
            vm.selectedWindowID = win.windowID
            refreshWindowList()
            print("[AutoDetect] 已自动选择窗口: \(captureManager.displayTitle(for: win))")
            return
        }
        for keyword in Self.chessAppKeywords {
            if let win = captureManager.autoSelectWindow(titleContaining: keyword) {
                vm.selectedWindowID = win.windowID
                refreshWindowList()
                print("[AutoDetect] 已自动选择窗口: \(captureManager.displayTitle(for: win))")
                return
            }
        }
    }

    private func selectCaptureSource(windowID: UInt32?) {
        let previousSourceKey = captureManager.selectedCaptureSourceKey
        let previousWindowID = captureManager.selectedWindowID
        if let windowID {
            if let window = captureManager.availableWindows.first(where: {
                $0.windowID == windowID
            }) {
                captureManager.selectWindow(window)
            } else {
                captureManager.markWindowSelectionUnavailable()
            }
        } else {
            captureManager.clearWindowSelection()
            captureManager.selectDisplay(recognizer.boardGeometry?.displayID)
        }
        vm.selectedWindowID = captureManager.selectedWindowID
        vm.captureSourceUnavailable = windowID != nil
            && captureManager.selectedWindowID == nil

        let sourceChanged = previousWindowID != captureManager.selectedWindowID
            || previousSourceKey != captureManager.selectedCaptureSourceKey
        guard sourceChanged else { return }
        recognizer.resetCaptureSourceState()
        migrateLegacyGeometryIfNeeded()
        applySavedGeometryForCurrentSource()
        resetCaptureSession(message: vm.captureSourceUnavailable
            ? "目标窗口已失效，请刷新后重新选择"
            : "已切换目标程序，正在重新锁定局面")
    }

    private func applySavedGeometryForCurrentSource() {
        guard let currentSourceKey = captureManager.selectedCaptureSourceKey else {
            recognizer.boardGeometry = nil
            vm.hasBoardGeometry = false
            return
        }

        var geometry = BoardGeometrySourceStore.geometry(for: currentSourceKey)
        // Recover a rectangle written by an older build, then immediately put
        // it into the per-source registry so a missing JSON file cannot lose
        // it again.
        if geometry == nil,
           BoardGeometrySourceStore.sourceKey == currentSourceKey,
           let legacyGeometry = BoardGeometry.load() {
            geometry = legacyGeometry
            BoardGeometrySourceStore.save(
                geometry: legacyGeometry,
                sourceKey: currentSourceKey
            )
        }
        guard var geometry else {
            recognizer.boardGeometry = nil
            vm.hasBoardGeometry = false
            return
        }

        if captureManager.selectedWindowID != nil,
           geometry.windowNormalizedRect == nil,
           let windowFrame = captureManager.selectedWindowFrame {
            let upgraded = geometry.storingWindowRelativeRect(
                windowFrame: windowFrame
            )
            guard upgraded.windowNormalizedRect != nil else {
                recognizer.boardGeometry = nil
                vm.hasBoardGeometry = false
                return
            }
            geometry = upgraded
            BoardGeometrySourceStore.save(
                geometry: geometry,
                sourceKey: currentSourceKey
            )
        }

        recognizer.boardGeometry = geometry
        vm.hasBoardGeometry = true
        if captureManager.isFullScreenCaptureSelected {
            captureManager.selectDisplay(geometry.displayID)
        }
    }

    /// Migrate only geometry whose old metadata proves it belongs to the
    /// current application. The sole metadata-free exception is the original
    /// XQWizard-only build; unknown rectangles are never treated as universal.
    private func migrateLegacyGeometryIfNeeded() {
        guard var geometry = BoardGeometry.load(),
              BoardGeometrySourceStore.sourceKey == nil,
              let currentSourceKey = captureManager.selectedCaptureSourceKey
        else { return }

        let selectedBundleIdentifier = WindowCandidatePolicy.normalizedIdentifier(
            captureManager.selectedWindowBundleIdentifier
        )
        let legacyBundleIdentifier = WindowCandidatePolicy.normalizedIdentifier(
            BoardGeometrySourceStore.legacyBundleIdentifier
        )
        let provenSameApplication = legacyBundleIdentifier != nil
            && legacyBundleIdentifier == selectedBundleIdentifier
        let originalWizardMigration = legacyBundleIdentifier == nil
            && selectedBundleIdentifier == Self.wizardBundleIdentifier
        guard provenSameApplication || originalWizardMigration else { return }

        if geometry.windowNormalizedRect == nil,
           let windowFrame = captureManager.selectedWindowFrame {
            let migrated = geometry.storingWindowRelativeRect(
                windowFrame: windowFrame
            )
            guard migrated.windowNormalizedRect != nil else { return }
            geometry = migrated
            geometry.save()
        }
        BoardGeometrySourceStore.save(
            geometry: geometry,
            sourceKey: currentSourceKey
        )
    }

    // MARK: Calibration

    @objc private func startCalibration() {
        recognizer.captureWindowFrame = captureManager.selectedWindowFrame
        Task { await calibrationManager.performCalibration() }
    }

    @objc private func resetCalibration() {
        calibrationManager.resetCalibration()
    }

    @objc private func selectBoardManually() {
        pendingBoardSelectionSourceKey = captureManager.selectedCaptureSourceKey
        boardSelector.show(displayID: captureManager.selectedWindowDisplayID)
    }

    @objc private func clearBoardGeometry() {
        if let sourceKey = captureManager.selectedCaptureSourceKey {
            BoardGeometrySourceStore.removeGeometry(for: sourceKey)
        }
        recognizer.resetCaptureSourceState()
        recognizer.boardGeometry = nil
        vm.hasBoardGeometry = false
        resetCaptureSession(message: "棋盘框选已清除")
        vm.calibrationMessage = "框选已清除，将恢复 Vision 自动检测"
    }

    private func showBoardSelectionAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = title == "棋盘已保存" ? .informational : .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Align turn inference to a known real-world turn without touching the
    /// capture source, recognized board, calibration, or board geometry. This
    /// is needed when attaching to a game that was already underway: a static
    /// screenshot cannot prove which colour made the last move.
    private func synchronizeTurn(to side: PieceSide) {
        currentSideToMove = side
        vm.currentTurnSide = side
        lastConfirmedBoard?.redToMove = (side == .red)
        baselineObservations.removeAll(keepingCapacity: true)
        baselineOrientationVotes.removeAll(keepingCapacity: true)
        searchCoordinator.cancel()
        searchRevision += 1
        activeSearchPositionKey = nil
        completedSearchPositionKey = nil
        ponderHint = nil
        forceEngineRefresh = true
        vm.bestMove = "--"
        vm.bestMoveCN = "正在计算\(side == .red ? "红方" : "黑方")走法"
        vm.recommendedSide = nil
        resetDisplayedEvaluation()
        vm.status = vm.isRunning
            ? (lastConfirmedBoard == nil ? .capturing : .stable)
            : .idle
        vm.searchDetail = "已同步为\(side == .red ? "红方" : "黑方")走 · 保持棋盘识别不变"
    }

    /// Rotates only the visual projection. Recognition and engine coordinates
    /// remain canonical, and the user's choice stays locked for this run.
    private func flipPreviewOrientation() {
        let reversed = !vm.previewIsReversed
        vm.previewIsReversed = reversed
        lockedPreviewIsReversed = reversed
        if let board = lastConfirmedBoard ?? vm.lastAnalyzedBoard, board.isValid {
            persistTrustedBoard(board, isReversed: reversed)
        }
        vm.searchDetail = "已手动翻转棋盘 · 本轮分析保持此方向"
    }

    // MARK: Manual Qwen visual review

    private func startAIReview() {
        aiReviewTask?.cancel()
        pendingAIReviewBoard = nil
        pendingAIReviewSourceKey = nil
        vm.aiReviewBoard = nil
        vm.aiReviewDifferences = []
        vm.aiReviewConfidence = nil
        vm.aiReviewMessage = ""

        aiReviewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let image = await self.captureManager.captureFrame() else {
                    throw AIReviewFlowError.captureFailed(
                        self.captureManager.lastCaptureError ?? "未取得当前窗口图像"
                    )
                }

                self.recognizer.captureWindowFrame =
                    self.captureManager.selectedWindowFrame
                var boardRect = self.latestRecognizedBoardRect
                if boardRect == nil {
                    boardRect = await self.recognizer.recognize(image: image)?.boardRect
                }
                guard let boardRect,
                      let boardImage = self.cropReviewBoard(
                        from: image,
                        normalizedRect: boardRect
                      )
                else {
                    throw AIReviewFlowError.noBoardRect
                }

                self.vm.aiReviewSnapshot = NSImage(
                    cgImage: boardImage,
                    size: NSSize(width: boardImage.width, height: boardImage.height)
                )
                self.vm.aiReviewPhase = .captured
                NSSound(named: "Tink")?.play()
                try await Task.sleep(nanoseconds: 220_000_000)

                self.vm.aiReviewPhase = .sending
                try await Task.sleep(nanoseconds: 360_000_000)

                self.vm.aiReviewPhase = .reviewing
                let sourceKey = self.captureManager.selectedCaptureSourceKey
                guard let baseline = self.vm.lastAnalyzedBoard,
                      baseline.isValid else {
                    throw QwenBoardReviewError.invalidBoard
                }
                let result = try await self.qwenReviewService.review(
                    boardImage: boardImage,
                    baseline: baseline,
                    imageIsReversed: self.vm.previewIsReversed
                )
                try Task.checkCancellation()
                guard sourceKey == self.captureManager.selectedCaptureSourceKey else {
                    throw AIReviewFlowError.sourceChanged
                }

                var reviewedBoard = result.board
                reviewedBoard.redToMove = self.currentSideToMove == .red
                let protected = self.protectRecognizedPieceSides(
                    in: reviewedBoard,
                    baseline: baseline
                )
                reviewedBoard = protected.board
                let differences = self.boardDifferences(
                    baseline,
                    reviewedBoard
                )

                self.pendingAIReviewBoard = reviewedBoard
                self.pendingAIReviewSourceKey = sourceKey
                self.vm.aiReviewBoard = reviewedBoard
                self.vm.aiReviewDifferences = differences
                self.vm.aiReviewConfidence = result.confidence
                self.vm.aiReviewModelName = result.modelName
                var reviewNotes: [String] = []
                if let note = result.note, !note.isEmpty { reviewNotes.append(note) }
                if protected.count > 0 {
                    reviewNotes.append("已拦截 \(protected.count) 处仅红黑颜色冲突，保留原预览阵营")
                }
                reviewNotes.append("最终可应用修正 \(differences.count) 处")
                self.vm.aiReviewMessage = reviewNotes.joined(separator: " · ")
                self.vm.aiReviewPhase = .ready
                self.aiReviewTask = nil
            } catch is CancellationError {
                self.aiReviewTask = nil
            } catch {
                self.vm.aiReviewMessage = error.localizedDescription
                self.vm.aiReviewPhase = .failed
                self.aiReviewTask = nil
            }
        }
    }

    private func applyAIReview() {
        guard var reviewedBoard = pendingAIReviewBoard else { return }
        guard pendingAIReviewSourceKey == captureManager.selectedCaptureSourceKey else {
            vm.aiReviewMessage = "目标窗口已变化，请重新复核"
            vm.aiReviewPhase = .failed
            return
        }
        guard !vm.aiReviewDifferences.isEmpty else {
            dismissAIReview(clearMessage: false)
            vm.searchDetail = "千问与当前预览一致 · 无需应用"
            return
        }

        reviewedBoard.redToMove = currentSideToMove == .red
        let rawBase = latestRawRecognizedBoard
            ?? lastConfirmedBoard
            ?? vm.lastAnalyzedBoard
            ?? BoardState()

        // Applying the review replaces previous session-local edits. Only the
        // cells where Qwen differs from the current raw screenshot are pinned;
        // the existing recognizer remains responsible for every other cell.
        manualSquareOverrides.removeAll(keepingCapacity: true)
        for row in 0..<10 {
            for col in 0..<9 {
                let position = BoardPosition(col: col, row: row)
                guard rawBase[position] != reviewedBoard[position] else { continue }
                if let piece = reviewedBoard[position] {
                    manualSquareOverrides[position] = .piece(piece)
                } else {
                    manualSquareOverrides[position] = .empty
                }
            }
        }

        baselineObservations.removeAll(keepingCapacity: true)
        baselineOrientationVotes.removeAll(keepingCapacity: true)
        historyFromStart = false
        observedMoves.removeAll(keepingCapacity: true)
        recentPositionKeys.removeAll(keepingCapacity: true)
        lastConfirmedBoard = reviewedBoard
        vm.lastAnalyzedBoard = reviewedBoard
        vm.diagnosticCapture = nil
        vm.errorMessage = nil
        vm.status = .stable
        persistTrustedBoard(reviewedBoard, isReversed: vm.previewIsReversed)

        let changedCount = vm.aiReviewDifferences.count
        dismissAIReview(clearMessage: false)
        analyzeTrustedBoardImmediately(reviewedBoard)
        vm.searchDetail = "千问复核局面已应用 · 修正 \(changedCount) 个交叉点"
    }

    private func dismissAIReview(clearMessage: Bool = true) {
        aiReviewTask?.cancel()
        aiReviewTask = nil
        pendingAIReviewBoard = nil
        pendingAIReviewSourceKey = nil
        vm.aiReviewPhase = .idle
        vm.aiReviewSnapshot = nil
        vm.aiReviewBoard = nil
        vm.aiReviewDifferences = []
        vm.aiReviewConfidence = nil
        if clearMessage { vm.aiReviewMessage = "" }
    }

    private func cropReviewBoard(
        from image: CGImage,
        normalizedRect: CGRect
    ) -> CGImage? {
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: image.width,
            height: image.height
        )
        let pixelRect = CGRect(
            x: normalizedRect.minX * CGFloat(image.width),
            y: normalizedRect.minY * CGFloat(image.height),
            width: normalizedRect.width * CGFloat(image.width),
            height: normalizedRect.height * CGFloat(image.height)
        ).integral.intersection(imageBounds)
        guard pixelRect.width > 20, pixelRect.height > 20 else { return nil }
        return image.cropping(to: pixelRect)
    }

    private func boardDifferences(
        _ lhs: BoardState?,
        _ rhs: BoardState
    ) -> Set<BoardPosition> {
        var differences: Set<BoardPosition> = []
        for row in 0..<10 {
            for col in 0..<9 {
                let position = BoardPosition(col: col, row: row)
                if lhs?[position] != rhs[position] {
                    differences.insert(position)
                }
            }
        }
        return differences
    }

    /// A general vision model may find the correct glyph and square but flip
    /// its colour. If the current preview and Qwen agree on occupancy and kind,
    /// Qwen alone is not allowed to reverse the side. This guard exists only in
    /// the optional review path; it does not modify screenshot recognition.
    private func protectRecognizedPieceSides(
        in reviewed: BoardState,
        baseline: BoardState?
    ) -> (board: BoardState, count: Int) {
        guard let baseline else { return (reviewed, 0) }
        var protected = reviewed
        var count = 0
        for row in 0..<10 {
            for col in 0..<9 {
                let position = BoardPosition(col: col, row: row)
                guard let current = baseline[position],
                      let proposed = reviewed[position],
                      current.kind == proposed.kind,
                      current.side != proposed.side
                else { continue }
                protected[position] = current
                count += 1
            }
        }
        return (protected, count)
    }

    /// Deliberately forget only the tracked game state. Capture permissions,
    /// selected window, board geometry, templates and ONNX models stay intact.
    /// The last preview stays visible while the current screenshot replaces
    /// the tracked state in the background.
    private func requestPositionResync() {
        searchCoordinator.cancel()
        searchRevision += 1
        activeSearchPositionKey = nil
        completedSearchPositionKey = nil
        ponderHint = nil

        lastConfirmedBoard = nil
        latestRawRecognizedBoard = nil
        baselineObservations.removeAll(keepingCapacity: true)
        baselineOrientationVotes.removeAll(keepingCapacity: true)
        lockedPreviewIsReversed = nil
        currentSideToMove = vm.currentTurnSide
        historyFromStart = false
        observedMoves.removeAll(keepingCapacity: true)
        recentPositionKeys.removeAll(keepingCapacity: true)

        vm.needsPositionResync = false
        vm.status = vm.lastAnalyzedBoard == nil ? .capturing : .stable
        vm.bestMove = "--"
        vm.bestMoveCN = "正在重新同步当前局面"
        vm.recommendedSide = nil
        vm.errorMessage = nil
        vm.searchDetail = "保留当前预览 · 后台重新同步截图"
    }

    // MARK: Analysis Loop

    @objc private func startAnalysis() {
        guard analysisTask == nil else { return }
        guard recognizer.usesTheOneModel || templateLibrary.isCalibrated else {
            vm.calibrationMessage = "请先完成校准再开始分析"
            return
        }
        // A fresh launch defaults to Red, while a manual turn synchronization
        // made before resuming analysis must be honoured.
        lastConfirmedBoard = nil
        latestRawRecognizedBoard = nil
        currentSideToMove = vm.currentTurnSide
        baselineObservations.removeAll(keepingCapacity: true)
        baselineOrientationVotes.removeAll(keepingCapacity: true)
        lockedPreviewIsReversed = nil
        // Pause → Start always begins a brand-new visual scan. Session-local
        // edits belong to the previous run and must not mask the current board.
        manualSquareOverrides.removeAll(keepingCapacity: true)
        vm.needsPositionResync = false
        forceEngineRefresh = false
        historyFromStart = false
        observedMoves = []
        recentPositionKeys = []
        vm.lastAnalyzedBoard = nil
        vm.previewIsReversed = false
        vm.bestMove = "--"
        vm.bestMoveCN = "--"
        vm.recommendedSide = nil
        resetDisplayedEvaluation()
        searchCoordinator.cancel()
        searchRevision += 1
        activeSearchPositionKey = nil
        completedSearchPositionKey = nil
        ponderHint = nil
        vm.isRunning = true
        restorePersistedBoardIfAvailable(analyzeImmediately: false)

        analysisTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.analyzeOnce()
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            }
        }
    }

    @objc private func stopAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        searchCoordinator.cancel()
        searchRevision += 1
        activeSearchPositionKey = nil
        vm.isRunning = false
        vm.status = .idle
        vm.searchDetail = ""
    }

    private func analyzeOnce() async {
        // Generic chess clients must use the user's fixed crop.  Silently
        // falling back to pose/Vision after that crop disappeared was the
        // source of the visible “识别中 / 识别不稳定” loop: window chrome,
        // start overlays and move animations were intermittently treated as
        // the board. XQWizard keeps its dedicated fixed-layout/score-sheet
        // path and is therefore exempt.
        let requiresManualGeometry =
            captureManager.selectedWindowBundleIdentifier
                != Self.wizardBundleIdentifier
        if requiresManualGeometry && recognizer.boardGeometry == nil {
            vm.status = .needsBoardSelection
            vm.bestMoveCN = "请先框选棋盘"
            vm.bestMove = "点击右下角蓝色框选按钮"
            vm.errorMessage = nil
            vm.needsPositionResync = false
            vm.searchDetail = "每个象棋程序只需框选一次，之后会永久记住"
            return
        }
        // Keep the steady "就绪" indicator while the periodic refresh runs.
        // Setting .capturing on every 0.5 s tick made a successful analysis
        // visibly flicker between "识别中" and "就绪".
        if lastConfirmedBoard == nil {
            vm.status = .capturing
        }

        // Manual board geometry is stored in screen coordinates and needs the
        // current capture window frame to convert into image coordinates.
        recognizer.captureWindowFrame = captureManager.selectedWindowFrame
        recognizer.preferredWindowBoardRect =
            captureManager.selectedWindowBundleIdentifier
                == Self.wizardBundleIdentifier
            ? CGRect(x: 0.065, y: 0.075, width: 0.64, height: 0.88)
            : nil

        guard let image = await captureManager.captureFrame() else {
            refreshWindowList()
            vm.bestMoveCN = "截图失败"
            vm.bestMove = captureManager.lastCaptureError ?? "未取得窗口图像"
            print("[Analysis] no capture: \(captureManager.lastCaptureError ?? "unknown")")
            vm.errorMessage = captureManager.lastCaptureError
                ?? "未取得目标窗口截图，请检查屏幕录制权限"
            if lastConfirmedBoard == nil {
                vm.status = .error
            } else {
                vm.searchDetail = "截图暂时中断 · 保留当前棋盘"
            }
            return
        }
        // A game may recreate its native window while retaining the same app
        // and title. Reflect the fresh ScreenCaptureKit handle in the picker.
        if vm.selectedWindowID != captureManager.selectedWindowID {
            refreshWindowList()
            recognizer.captureWindowFrame = captureManager.selectedWindowFrame
        }

        // XQWizard's accessibility score sheet is a client-specific enhancement.
        // Enable it only for an explicitly selected XQWizard window; a running
        // background copy must never overwrite another application's board.
        let isWizardTarget = captureManager.selectedWindowBundleIdentifier
            == Self.wizardBundleIdentifier
        // Read the score sheet independently of image recognition. For
        // XQWizard this is an exact, read-only source of the position and must
        // remain available even when the image model cannot locate the board.
        let wizardReplay = isWizardTarget ? replayXQWizardScoreSheet() : nil
        let result = await recognizer.recognize(image: image)
        if let result {
            latestRecognizedBoardRect = result.boardRect
        }

        guard result != nil || wizardReplay != nil else {
            print("[Analysis] recognizer and XQWizard replay both returned nil")
            saveCaptureDiagnostic(image)
            if lastConfirmedBoard == nil {
                vm.status = .capturing
                vm.bestMoveCN = "正在确认棋盘"
                vm.bestMove = "已截图，等待稳定识别"
            }
            return
        }
        if let result, result.status != .stable {
            print("[Analysis] model status=\(String(describing: result.status)) valid=\(result.boardState.isValid)")
            saveCaptureDiagnostic(image)
        }

        var board = wizardReplay?.board ?? result!.boardState
        let usedWizardReplay = wizardReplay != nil
        if board.isValid {
            latestRawRecognizedBoard = board
        }
        board = applyingManualOverrides(to: board)
        let previewIsReversed = !usedWizardReplay
            && (result?.isReversedForDisplay ?? false)
        // XQWizard exposes its visible score sheet through macOS
        // Accessibility.  Replaying that notation from the initial position
        // gives an exact board even when blue last-move corners confuse the
        // image model about a piece's colour or leave a ghost at its old cell.
        // Keep the screenshot as a target-window sanity check rather than
        // blindly trusting a score sheet from an unrelated window.
        // When XQWizard itself is the selected capture target, its score sheet
        // is authoritative. Do not require a noisy image model to agree before
        // accepting it; that requirement defeated the fallback precisely when
        // recognition failed or the empty opening score sheet was visible.

        // One simple recognition rule for startup and the whole game: keep the
        // latest five frames and vote independently at every intersection.
        // No turn inference, legal-move gate, one/two-ply branch, or repair
        // candidate can block a stable visual board.
        let sampleSize = 5
        baselineObservations.append(board)
        baselineOrientationVotes.append(previewIsReversed)
        if baselineObservations.count > sampleSize {
            baselineObservations.removeFirst(baselineObservations.count - sampleSize)
        }
        if baselineOrientationVotes.count > sampleSize {
            baselineOrientationVotes.removeFirst(
                baselineOrientationVotes.count - sampleSize
            )
        }

        if usedWizardReplay {
            guard board.isValid else { return }
        } else {
            if baselineObservations.count >= sampleSize,
               let consensus = BoardState.temporalConsensus(
                from: baselineObservations,
                minimumAgreement: 0.60
               ) {
                board = consensus
            } else if board.isValid {
                // A complete current observation is usable even when one or
                // two highlighted cells flicker between frames. Requiring all
                // 90 intersections to reach a simultaneous 3/5 majority made
                // an otherwise readable board wait forever at startup.
                // Multi-frame voting remains a quality improvement when it
                // succeeds, but it is never a gate that blocks recognition.
            } else {
                if lastConfirmedBoard == nil {
                    vm.status = .capturing
                    vm.bestMoveCN = "正在确认棋盘"
                    vm.bestMove = "等待一帧完整棋盘"
                }
                return
            }
        }

        let previousBoard = lastConfirmedBoard
        let layoutChanged = previousBoard == nil
            || previousBoard?.sameLayout(as: board) == false
        if layoutChanged, previousBoard != nil {
            historyFromStart = false
            observedMoves.removeAll(keepingCapacity: true)
            ponderHint = nil
        }
        // Lock orientation on the first accepted board of this scan. The old
        // rolling 3-of-5 vote allowed a few noisy frames to rotate the entire
        // preview halfway through a game.
        if lockedPreviewIsReversed == nil {
            lockedPreviewIsReversed = previewIsReversed
        }
        vm.previewIsReversed = lockedPreviewIsReversed ?? previewIsReversed
        vm.needsPositionResync = false
        vm.errorMessage = nil
        vm.diagnosticCapture = nil

        if let replay = wizardReplay, replay.board.sameLayout(as: board) {
            historyFromStart = true
            observedMoves = replay.moves
            recentPositionKeys = replay.positionKeys
        }

        board.redToMove = (currentSideToMove == .red)
        lastConfirmedBoard = board
        if latestRawRecognizedBoard == nil {
            latestRawRecognizedBoard = board
        }
        // Recognition UI is updated now, before and independently from the
        // engine. A slow/cancelled search can never masquerade as “未识别”.
        vm.lastAnalyzedBoard = board
        persistTrustedBoard(board, isReversed: vm.previewIsReversed)
        if activeSearchPositionKey == nil {
            vm.status = .stable
        }
        appendPositionKey(board.toFEN())

        let fen = board.toFEN()
        clearQwenAdviceIfStale(comparedWith: fen)
        let sideAtRequest = currentSideToMove
        let modeAtRequest = vm.analysisMode
        let moveHistory = historyFromStart ? observedMoves.map { $0.move.uci } : nil
        let positionKey = brainPositionKey(
            fen: fen,
            history: moveHistory,
            mode: modeAtRequest
        )

        let legalMoves = board.legalMoves(for: sideAtRequest)
        if legalMoves.isEmpty {
            // Xiangqi has no stalemate draw: a side with no legal move has
            // lost. Resolve this before asking UCI, whose terminal response is
            // `bestmove (none)`, so the same finished board cannot leave an
            // active search key stuck forever.
            if completedSearchPositionKey != positionKey || vm.bestMoveCN != "对局结束" {
                searchCoordinator.cancel()
                searchRevision += 1
                activeSearchPositionKey = nil
                completedSearchPositionKey = positionKey
                forceEngineRefresh = false
                ponderHint = nil
                vm.status = .stable
                vm.bestMove = "--"
                vm.bestMoveCN = "对局结束"
                vm.recommendedSide = nil
                vm.score = sideAtRequest == .red ? -100_000 : 100_000
                vm.mateIn = 0
                vm.depth = 0
                vm.pv = []
                vm.lastAnalyzedBoard = board
                vm.errorMessage = nil
                let defeatedSide = sideAtRequest == .red ? "红方" : "黑方"
                vm.searchDetail = "\(defeatedSide)无合法走法"
            } else {
                vm.status = .stable
            }
            return
        }

        if !forceEngineRefresh,
           activeSearchPositionKey == positionKey || completedSearchPositionKey == positionKey {
            if activeSearchPositionKey == nil { vm.status = .stable }
            return
        }

        searchRevision += 1
        let revision = searchRevision
        activeSearchPositionKey = positionKey
        completedSearchPositionKey = nil
        forceEngineRefresh = false
        vm.status = .analyzing
        vm.searchDetail = "快速计算中"

        let forbiddenMoves = Set(legalMoves.filter {
            shouldAvoidForRepetition($0, in: board, side: sideAtRequest)
        }.map(\.uci))
        let allowedMoves = legalMoves
            .filter { !forbiddenMoves.contains($0.uci) }
            .map(\.uci)

        let request = BrainSearchRequest(
            revision: revision,
            positionKey: positionKey,
            fen: fen,
            movesFromStart: moveHistory,
            board: board,
            sideToMove: sideAtRequest,
            mode: brainMode(modeAtRequest),
            openingWeights: openingWeights(for: board, side: sideAtRequest,
                                           history: moveHistory),
            repetitionForbiddenMoves: forbiddenMoves,
            repetitionAllowedMoves: allowedMoves
        )

        searchCoordinator.replaceSearch(
            with: request,
            onUpdate: { [weak self] update in
                self?.applyBrainUpdate(
                    update,
                    board: board,
                    side: sideAtRequest,
                    fen: fen,
                    mode: modeAtRequest
                )
            },
            onFailure: { [weak self] failedRevision, error in
                guard let self,
                      self.searchRevision == failedRevision,
                      self.activeSearchPositionKey == positionKey
                else { return }
                if case EngineError.noLegalMove = error {
                    self.activeSearchPositionKey = nil
                    self.completedSearchPositionKey = positionKey
                    self.forceEngineRefresh = false
                    self.ponderHint = nil
                    self.vm.status = .stable
                    self.vm.bestMove = "--"
                    self.vm.bestMoveCN = "对局结束"
                    self.vm.recommendedSide = nil
                    self.vm.score = sideAtRequest == .red ? -100_000 : 100_000
                    self.vm.mateIn = 0
                    self.vm.depth = 0
                    self.vm.pv = []
                    self.vm.lastAnalyzedBoard = board
                    self.vm.errorMessage = nil
                    let defeatedSide = sideAtRequest == .red ? "红方" : "黑方"
                    self.vm.searchDetail = "\(defeatedSide)无合法走法"
                    return
                }
                self.activeSearchPositionKey = nil
                self.forceEngineRefresh = true
                // An engine retry is not a recognition failure. Keep the
                // trusted board and green recognition state visible.
                self.vm.status = .stable
                self.vm.errorMessage = "引擎已自动恢复：\(error.localizedDescription)"
                self.vm.searchDetail = "棋盘保持不变 · 准备重新分析"
            }
        )
    }

    private func applyBrainUpdate(
        _ update: BrainSearchUpdate,
        board: BoardState,
        side: PieceSide,
        fen: String,
        mode: AnalysisMode
    ) {
        guard update.revision == searchRevision,
              update.positionKey == activeSearchPositionKey,
              vm.analysisMode == mode,
              currentSideToMove == side,
              lastConfirmedBoard?.toFEN() == fen,
              let uciMove = UCIMove(uci: update.move.uci),
              let movingPiece = board[uciMove.from],
              movingPiece.side == side,
              board.isLegalMove(uciMove, for: side)
        else { return }

        vm.bestMove = update.move.uci
        vm.bestMoveCN = ChineseNotation.convert(uci: update.move.uci, state: board)
        vm.recommendedSide = side
        vm.score = AdaptiveSearchPolicy.redPerspectiveScore(
            update.move.score,
            sideToMove: side
        )
        vm.mateIn = AdaptiveSearchPolicy.redPerspectiveMateDistance(
            update.move.mateIn,
            sideToMove: side
        )
        vm.depth = update.move.depth
        vm.pv = update.move.pv
        vm.lastAnalyzedBoard = board
        vm.errorMessage = nil

        switch update.phase {
        case .quick:
            vm.status = .stable
            switch update.source {
            case .openingBook:
                vm.searchDetail = "本地开局库候选已由引擎复核 · 后台深化中"
            case .ponderCache:
                vm.searchDetail = "对手应手命中预计算 · 正在复核"
            case .engine:
                vm.searchDetail = "快速答案 · 后台深化中"
            }
        case .deepening:
            vm.status = .analyzing
            vm.searchDetail = "局面复杂 · 深化至 15 秒"
        case .final:
            vm.status = .stable
            vm.searchDetail = "超强结果 · 深度 \(update.move.depth)"
            activeSearchPositionKey = nil
            completedSearchPositionKey = update.positionKey
        }

        // A single Pikafish process doubles as ponder: on the opponent's
        // position, its PV predicts both the opponent move and our response.
        // The cached response is displayed only after a matching observed move
        // and a fresh legality check on the resulting board.
        // A single Pikafish process doubles as ponder: on the opponent's
        // position, its PV predicts both the opponent move and our response.
        // The cached response is displayed only after a matching observed move
        // and a fresh legality check on the resulting board.
        if (update.phase == .quick || update.phase == .final),
           side != vm.playerSide,
           update.move.pv.count >= 2,
           update.move.pv[0] == update.move.uci,
           let predicted = UCIMove(uci: update.move.pv[0]),
           board.isLegalMove(predicted, for: side) {
            var nextBoard = board.applying(predicted)
            let targetSide: PieceSide = side == .red ? .black : .red
            nextBoard.redToMove = (targetSide == .red)
            let responseUCI = update.move.pv[1]
            if let response = UCIMove(uci: responseUCI),
               nextBoard.isLegalMove(response, for: targetSide) {
                let responseScore = update.move.score == Int.min
                    ? Int.max : -update.move.score
                let responseMate = update.move.mateIn.map {
                    $0 == Int.min ? Int.max : -$0
                }
                ponderHint = PonderHint(
                    originFEN: fen,
                    predictedMove: predicted.uci,
                    response: EngineMove(
                        uci: responseUCI,
                        score: responseScore,
                        mateIn: responseMate,
                        depth: max(0, update.move.depth - 1),
                        pv: Array(update.move.pv.dropFirst())
                    ),
                    targetSide: targetSide,
                    mode: mode
                )
            }
        }
    }

    private func brainPositionKey(
        fen: String,
        history: [String]?,
        mode: AnalysisMode
    ) -> String {
        let historyKey = history?.joined(separator: ",") ?? "fen-only"
        return "\(fen)|\(historyKey)|\(mode.rawValue)"
    }

    private func brainMode(_ mode: AnalysisMode) -> BrainSearchMode {
        switch mode {
        case .normal: return .normal
        case .aggressive: return .aggressive
        case .ultra: return .ultra
        }
    }

    private func openingWeights(
        for board: BoardState,
        side: PieceSide,
        history: [String]?
    ) -> [String: Int] {
        // The book is an opening-only hint. Unknown history, deep positions, or
        // repetition immediately fall back to unrestricted Pikafish.
        guard let history,
              history.count <= 20,
              recentPositionKeys.filter({ $0 == board.toFEN() }).count < 2
        else { return [:] }
        let candidates = openingBook.candidates(
            for: board.toFEN(),
            board: board,
            side: side,
            limit: 8
        )
        return Dictionary(uniqueKeysWithValues: candidates.map { ($0.uci, $0.weight) })
    }

    private func resetDisplayedEvaluation() {
        vm.score = 0
        vm.mateIn = nil
        vm.depth = 0
        vm.pv = []
        vm.searchDetail = ""
        vm.errorMessage = nil
    }

    /// Keeps the most recent trusted board for each selected chess program.
    /// A relaunch or transient native-window recreation can therefore show a
    /// useful position immediately while screenshots refresh in the background.
    private func persistTrustedBoard(_ board: BoardState, isReversed: Bool) {
        guard board.isValid,
              let sourceKey = captureManager.selectedCaptureSourceKey,
              let data = try? JSONEncoder().encode(
                SavedBoardSnapshot(board: board, isReversed: isReversed)
              )
        else { return }
        var snapshots = UserDefaults.standard.dictionary(
            forKey: Self.savedBoardSnapshotsKey
        ) as? [String: String] ?? [:]
        snapshots[sourceKey] = data.base64EncodedString()
        UserDefaults.standard.set(snapshots, forKey: Self.savedBoardSnapshotsKey)
    }

    private func persistedBoardForCurrentSource() -> SavedBoardSnapshot? {
        guard let sourceKey = captureManager.selectedCaptureSourceKey,
              let snapshots = UserDefaults.standard.dictionary(
                forKey: Self.savedBoardSnapshotsKey
              ) as? [String: String],
              let encoded = snapshots[sourceKey],
              let data = Data(base64Encoded: encoded),
              let snapshot = try? JSONDecoder().decode(
                SavedBoardSnapshot.self, from: data
              ),
              snapshot.board.isValid
        else { return nil }
        return snapshot
    }

    private func restorePersistedBoardIfAvailable(
        analyzeImmediately: Bool = true
    ) {
        guard let snapshot = persistedBoardForCurrentSource() else { return }
        var board = snapshot.board
        board.redToMove = currentSideToMove == .red
        if analyzeImmediately {
            lastConfirmedBoard = board
            latestRawRecognizedBoard = board
            vm.lastAnalyzedBoard = board
            vm.previewIsReversed = snapshot.isReversed
            lockedPreviewIsReversed = snapshot.isReversed
            vm.status = .stable
            forceEngineRefresh = true
            vm.bestMoveCN = "已恢复上次局面"
            vm.bestMove = "立即重新计算"
            vm.searchDetail = "截图将在后台继续更新"
            analyzeTrustedBoardImmediately(board)
        } else {
            // Pause → Start is a hard visual rescan boundary.  A saved board
            // may remain on screen as a harmless placeholder, but it must not
            // become recognition evidence, a confirmed baseline, or an engine
            // input for the new run.  Only fresh captures may repopulate
            // lastConfirmedBoard/latestRawRecognizedBoard below analyzeOnce().
            lastConfirmedBoard = nil
            latestRawRecognizedBoard = nil
            vm.lastAnalyzedBoard = board
            vm.previewIsReversed = snapshot.isReversed
            lockedPreviewIsReversed = nil
            vm.status = .capturing
            forceEngineRefresh = false
            vm.bestMoveCN = "正在扫描当前画面"
            vm.bestMove = "保留上次预览，等待当前截图"
            vm.recommendedSide = nil
            vm.searchDetail = "暂停后重新开始：强制分析整个当前棋盘"
        }
    }

    private func applyingManualOverrides(to board: BoardState) -> BoardState {
        var corrected = board
        for (position, override) in manualSquareOverrides {
            switch override {
            case .empty:
                corrected[position] = nil
            case .piece(let piece):
                corrected[position] = piece
            }
        }
        return corrected
    }

    /// Immediately trusts the board already visible in the preview and starts
    /// the local engine. No new screenshot, temporal vote, or frame transition
    /// is required. The recognition pipeline itself remains unchanged.
    private func forceAnalyzeCurrentPreview() {
        guard var board = vm.lastAnalyzedBoard else {
            vm.searchDetail = "当前没有可强制分析的预览局面"
            return
        }
        board.redToMove = currentSideToMove == .red
        guard board.isValid else {
            vm.searchDetail = "当前预览缺少完整将帅或棋子数量异常，请先完成人工编辑"
            return
        }

        baselineObservations.removeAll(keepingCapacity: true)
        baselineOrientationVotes.removeAll(keepingCapacity: true)
        historyFromStart = false
        observedMoves.removeAll(keepingCapacity: true)
        recentPositionKeys.removeAll(keepingCapacity: true)
        lastConfirmedBoard = board
        vm.lastAnalyzedBoard = board
        vm.needsPositionResync = false
        vm.errorMessage = nil
        vm.diagnosticCapture = nil
        forceEngineRefresh = true
        persistTrustedBoard(board, isReversed: vm.previewIsReversed)
        clearQwenAdviceIfStale(comparedWith: board.toFEN())
        analyzeTrustedBoardImmediately(board)
        vm.searchDetail = "已强制采用当前预览 · 无需等待新帧"
    }

    private func requestQwenAdvice() {
        qwenAdviceTask?.cancel()
        guard var board = vm.lastAnalyzedBoard else {
            vm.qwenAdvicePhase = .failed
            vm.qwenAdviceMessage = "请先识别、摆好或复核一个局面"
            return
        }
        board.redToMove = currentSideToMove == .red
        guard board.isValid else {
            vm.qwenAdvicePhase = .failed
            vm.qwenAdviceMessage = "当前预览局面不完整，千问建议未发送"
            return
        }
        guard let greenMove = UCIMove(uci: vm.bestMove),
              board.isLegalMove(greenMove, for: currentSideToMove) else {
            vm.qwenAdvicePhase = .failed
            vm.qwenAdviceMessage = "请等本地超强引擎先给出当前最佳着法"
            return
        }

        let requestedFEN = board.toFEN()
        let requestedGreenMove = greenMove.uci
        let side = currentSideToMove
        vm.qwenAdvicePhase = .loading
        vm.qwenAdviceMoveUCI = ""
        vm.qwenAdviceMoveCN = ""
        vm.qwenAdviceReason = ""
        vm.qwenAdvicePlan = ""
        vm.qwenAdviceConfidence = nil
        vm.qwenAdviceMessage = ""
        vm.qwenAdviceCandidateRank = nil
        vm.qwenAdviceCandidateCount = nil
        vm.qwenAdviceScoreGapCentipawns = nil
        vm.qwenAdviceAgreesWithGreen = nil

        qwenAdviceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.qwenCandidateEngine.start()
                let rawCandidates = try await self.qwenCandidateEngine.analyzeCandidates(
                    fen: requestedFEN,
                    movetime: 3_500,
                    count: 6
                )
                let candidates = self.safeQwenCandidates(rawCandidates)
                guard !candidates.isEmpty else {
                    throw QwenBoardReviewError.invalidAdvice
                }
                let result = try await self.qwenReviewService.advise(
                    board: board,
                    sideToMove: side,
                    engineCandidates: candidates,
                    greenMoveUCI: requestedGreenMove
                )
                try Task.checkCancellation()
                guard var current = self.vm.lastAnalyzedBoard else {
                    throw QwenBoardReviewError.invalidBoard
                }
                current.redToMove = self.currentSideToMove == .red
                guard current.toFEN() == requestedFEN else {
                    self.vm.qwenAdvicePhase = .failed
                    self.vm.qwenAdviceMessage = "局面已变化，请重新请求千问建议"
                    self.qwenAdviceTask = nil
                    return
                }
                self.qwenAdviceFEN = requestedFEN
                self.vm.qwenAdviceMoveUCI = result.move.uci
                self.vm.qwenAdviceMoveCN = result.moveCN
                self.vm.qwenAdviceReason = result.reason
                self.vm.qwenAdvicePlan = result.plan
                self.vm.qwenAdviceConfidence = result.confidence
                self.vm.qwenAdviceMessage = result.modelName
                self.vm.qwenAdviceCandidateRank = result.candidateRank
                self.vm.qwenAdviceCandidateCount = result.candidateCount
                self.vm.qwenAdviceScoreGapCentipawns = result.scoreGapCentipawns
                self.vm.qwenAdviceAgreesWithGreen = result.move.uci == self.vm.bestMove
                self.vm.qwenAdvicePhase = .ready
                self.qwenAdviceTask = nil
            } catch is CancellationError {
                self.qwenAdviceTask = nil
            } catch {
                self.vm.qwenAdvicePhase = .failed
                self.vm.qwenAdviceMessage = error.localizedDescription
                self.qwenAdviceTask = nil
            }
        }
    }

    /// Keep Qwen expressive without allowing it to select a strategically
    /// losing move.  The second Pikafish instance is authoritative here:
    /// ordinary alternatives stay within 1.20 pawns of its first choice, and
    /// a forced winning mate may only be replaced by another winning mate.
    private func safeQwenCandidates(_ candidates: [EngineMove]) -> [EngineMove] {
        guard let best = candidates.first else { return [] }
        let filtered: [EngineMove]
        if let bestMate = best.mateIn, bestMate > 0 {
            filtered = candidates.filter { ($0.mateIn ?? 0) > 0 }
        } else if let bestMate = best.mateIn, bestMate < 0 {
            filtered = candidates.filter { candidate in
                guard let mate = candidate.mateIn else { return true }
                return mate < 0
            }
        } else {
            filtered = candidates.filter { candidate in
                guard candidate.mateIn == nil else {
                    return (candidate.mateIn ?? -1) > 0
                }
                return best.score - candidate.score <= 120
            }
        }
        return Array(filtered.prefix(6))
    }

    private func clearQwenAdviceIfStale(comparedWith fen: String) {
        guard let qwenAdviceFEN, qwenAdviceFEN != fen else { return }
        qwenAdviceTask?.cancel()
        qwenAdviceTask = nil
        self.qwenAdviceFEN = nil
        vm.qwenAdvicePhase = .idle
        vm.qwenAdviceMoveUCI = ""
        vm.qwenAdviceMoveCN = ""
        vm.qwenAdviceReason = ""
        vm.qwenAdvicePlan = ""
        vm.qwenAdviceConfidence = nil
        vm.qwenAdviceMessage = ""
        vm.qwenAdviceCandidateRank = nil
        vm.qwenAdviceCandidateCount = nil
        vm.qwenAdviceScoreGapCentipawns = nil
        vm.qwenAdviceAgreesWithGreen = nil
    }

    private func correctBoardSquare(
        _ position: BoardPosition,
        correction: BoardSquareCorrection
    ) {
        switch correction {
        case .followRecognition:
            manualSquareOverrides.removeValue(forKey: position)
        case .empty:
            manualSquareOverrides[position] = .empty
        case .piece(let piece):
            manualSquareOverrides[position] = .piece(piece)
        }

        guard let trusted = latestRawRecognizedBoard
                ?? lastConfirmedBoard
                ?? vm.lastAnalyzedBoard
        else {
            vm.searchDetail = "请先识别出棋盘，再使用摆棋或擦棋工具"
            return
        }
        let corrected = applyingManualOverrides(to: trusted)
        // Always show the user's edit immediately. Moving a king or repairing
        // several related squares necessarily creates a temporarily incomplete
        // position between clicks; that must not make the editor unusable.
        vm.lastAnalyzedBoard = corrected
        vm.diagnosticCapture = nil
        guard corrected.isValid else {
            searchCoordinator.cancel()
            searchRevision += 1
            activeSearchPositionKey = nil
            completedSearchPositionKey = nil
            vm.errorMessage = nil
            vm.status = .stable
            vm.bestMove = "--"
            vm.bestMoveCN = "人工编辑中"
            vm.recommendedSide = nil
            vm.searchDetail = "继续摆棋或擦棋；局面完整后会自动重新计算"
            return
        }

        searchCoordinator.cancel()
        searchRevision += 1
        activeSearchPositionKey = nil
        completedSearchPositionKey = nil
        ponderHint = nil
        lastConfirmedBoard = corrected
        baselineObservations.removeAll(keepingCapacity: true)
        baselineOrientationVotes.removeAll(keepingCapacity: true)
        historyFromStart = false
        forceEngineRefresh = true
        vm.lastAnalyzedBoard = corrected
        persistTrustedBoard(corrected, isReversed: vm.previewIsReversed)
        vm.diagnosticCapture = nil
        vm.errorMessage = nil
        vm.status = .stable
        vm.searchDetail = correctionDescription(correction)
        analyzeTrustedBoardImmediately(corrected)
    }

    /// Starts the chess brain from an already trusted in-memory position.
    /// Manual corrections and restored snapshots must not wait for another
    /// screenshot before they can produce a move recommendation.
    private func analyzeTrustedBoardImmediately(_ board: BoardState) {
        guard board.isValid else { return }
        var board = board
        board.redToMove = currentSideToMove == .red
        lastConfirmedBoard = board
        vm.lastAnalyzedBoard = board

        let fen = board.toFEN()
        clearQwenAdviceIfStale(comparedWith: fen)
        let sideAtRequest = currentSideToMove
        let modeAtRequest = vm.analysisMode
        let moveHistory = historyFromStart ? observedMoves.map { $0.move.uci } : nil
        let positionKey = brainPositionKey(
            fen: fen,
            history: moveHistory,
            mode: modeAtRequest
        )
        let legalMoves = board.legalMoves(for: sideAtRequest)

        guard !legalMoves.isEmpty else {
            searchCoordinator.cancel()
            searchRevision += 1
            activeSearchPositionKey = nil
            completedSearchPositionKey = positionKey
            forceEngineRefresh = false
            ponderHint = nil
            vm.status = .stable
            vm.bestMove = "--"
            vm.bestMoveCN = "对局结束"
            vm.recommendedSide = nil
            vm.score = sideAtRequest == .red ? -100_000 : 100_000
            vm.mateIn = 0
            vm.depth = 0
            vm.pv = []
            vm.errorMessage = nil
            vm.searchDetail = "\(sideAtRequest == .red ? "红方" : "黑方")无合法走法"
            return
        }

        if !forceEngineRefresh,
           activeSearchPositionKey == positionKey || completedSearchPositionKey == positionKey {
            if activeSearchPositionKey == nil { vm.status = .stable }
            return
        }

        searchCoordinator.cancel()
        searchRevision += 1
        let revision = searchRevision
        activeSearchPositionKey = positionKey
        completedSearchPositionKey = nil
        forceEngineRefresh = false
        vm.status = .analyzing
        vm.bestMove = "--"
        vm.bestMoveCN = "正在计算"
        vm.recommendedSide = nil
        vm.searchDetail = "人工局面已接管 · 快速计算中"

        let forbiddenMoves = Set(legalMoves.filter {
            shouldAvoidForRepetition($0, in: board, side: sideAtRequest)
        }.map(\.uci))
        let allowedMoves = legalMoves
            .filter { !forbiddenMoves.contains($0.uci) }
            .map(\.uci)
        let request = BrainSearchRequest(
            revision: revision,
            positionKey: positionKey,
            fen: fen,
            movesFromStart: moveHistory,
            board: board,
            sideToMove: sideAtRequest,
            mode: brainMode(modeAtRequest),
            openingWeights: openingWeights(
                for: board,
                side: sideAtRequest,
                history: moveHistory
            ),
            repetitionForbiddenMoves: forbiddenMoves,
            repetitionAllowedMoves: allowedMoves
        )

        searchCoordinator.replaceSearch(
            with: request,
            onUpdate: { [weak self] update in
                self?.applyBrainUpdate(
                    update,
                    board: board,
                    side: sideAtRequest,
                    fen: fen,
                    mode: modeAtRequest
                )
            },
            onFailure: { [weak self] failedRevision, error in
                guard let self,
                      self.searchRevision == failedRevision,
                      self.activeSearchPositionKey == positionKey
                else { return }
                self.activeSearchPositionKey = nil
                self.forceEngineRefresh = true
                self.vm.status = .stable
                self.vm.errorMessage = "引擎已自动恢复：\(error.localizedDescription)"
                self.vm.searchDetail = "人工局面保持不变 · 准备重新分析"
            }
        )
    }

    private func correctionDescription(_ correction: BoardSquareCorrection) -> String {
        switch correction {
        case .followRecognition:
            return "已恢复该位置的自动识别"
        case .empty:
            return "已手动清空该位置 · 后续以人工修正为准"
        case .piece(let piece):
            return "已手动放置\(piece.kind.displayName(side: piece.side)) · 后续以人工修正为准"
        }
    }

    /// Clears only the state learned from the current capture source. Models,
    /// templates, engine configuration, and any compatible saved board geometry
    /// remain intact when the user switches to another application window.
    private func resetCaptureSession(message: String?) {
        dismissAIReview()
        latestRecognizedBoardRect = nil
        searchCoordinator.cancel()
        searchRevision += 1
        activeSearchPositionKey = nil
        completedSearchPositionKey = nil
        ponderHint = nil

        lastConfirmedBoard = nil
        latestRawRecognizedBoard = nil
        // A manual turn choice belongs to the user and must survive window
        // refreshes, re-framing and capture-source changes.
        currentSideToMove = vm.currentTurnSide
        baselineObservations.removeAll(keepingCapacity: true)
        baselineOrientationVotes.removeAll(keepingCapacity: true)
        lockedPreviewIsReversed = nil
        manualSquareOverrides.removeAll(keepingCapacity: true)
        forceEngineRefresh = false
        historyFromStart = false
        observedMoves.removeAll(keepingCapacity: true)
        recentPositionKeys.removeAll(keepingCapacity: true)
        wizardMoveRows.removeAll(keepingCapacity: true)

        vm.lastAnalyzedBoard = nil
        vm.previewIsReversed = false
        vm.bestMove = "--"
        vm.bestMoveCN = "--"
        vm.recommendedSide = nil
        vm.diagnosticCapture = nil
        vm.needsPositionResync = false
        resetDisplayedEvaluation()
        vm.status = vm.isRunning ? .capturing : .idle
        if vm.isRunning {
            restorePersistedBoardIfAvailable()
        }
        if let message { vm.searchDetail = message }
    }

    private func appendPositionKey(_ key: String) {
        guard recentPositionKeys.last != key else { return }
        recentPositionKeys.append(key)
        if recentPositionKeys.count > 80 {
            recentPositionKeys.removeFirst(recentPositionKeys.count - 80)
        }
    }

    /// Keeps one throttled, local snapshot only while diagnosing a failed
    /// recognition.  It is never transmitted and lets us tell a bad capture
    /// from a board-locator/model failure instead of changing thresholds blind.
    private func saveCaptureDiagnostic(_ image: CGImage) {
        guard Date().timeIntervalSince(lastCaptureDiagnosticAt) > 2 else { return }
        lastCaptureDiagnosticAt = Date()
        guard let cacheDirectory = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else { return }
        let url = cacheDirectory.appendingPathComponent(
            "xiangqi-assistant-last-capture.png"
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
    }

    // MARK: XQWizard score-sheet bridge

    /// Reads the move rows already visible in XQWizard's right-hand score
    /// sheet and replays them with this app's own legal-move generator.
    /// Nothing is clicked or controlled; this is a read-only reliability path.
    private func replayXQWizardScoreSheet() -> WizardReplay? {
        // The capture source can be the whole display when ScreenCaptureKit
        // temporarily fails to enumerate the XQWizard window.  Do not make
        // that UI label a prerequisite for the read-only score-sheet bridge:
        // the screenshot/layout mismatch check in `analyzeOnce` is the actual
        // safeguard against applying a score sheet to an unrelated board.
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.jpcxc.xqwiphone")
                .first(where: { !$0.isTerminated })
        else { return nil }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        var lines: [String] = []
        collectWizardMoveLines(from: root, depth: 0, into: &lines)

        // An empty score sheet is not “no recognition”: it is XQWizard's exact
        // initial position. This is the most important startup anchor.
        if lines.isEmpty {
            wizardMoveRows.removeAll()
            var initial = BoardState.initialPosition()
            initial.redToMove = true
            return WizardReplay(
                board: initial,
                sideToMove: .red,
                moves: [],
                positionKeys: [initial.toFEN()]
            )
        }

        let uniqueLines = Array(Set(lines))
        if let incomingFirst = uniqueLines.first(where: { wizardMoveNumber($0) == 1 }),
           let cachedFirst = wizardMoveRows[1],
           cachedFirst != incomingFirst {
            wizardMoveRows.removeAll()
        }
        for line in uniqueLines {
            let number = wizardMoveNumber(line)
            guard number != Int.max else { continue }
            wizardMoveRows[number] = line
        }

        guard let lastNumber = wizardMoveRows.keys.max(),
              lastNumber >= 1,
              (1...lastNumber).allSatisfy({ wizardMoveRows[$0] != nil })
        else { return nil }
        let ordered = (1...lastNumber).compactMap { wizardMoveRows[$0] }

        var board = BoardState.initialPosition()
        var side: PieceSide = .red
        var replayed: [(side: PieceSide, move: UCIMove)] = []
        var keys = [board.toFEN()]

        for line in ordered {
            let fields = wizardNotationFields(in: line)
            guard !fields.isEmpty else { continue }
            for notation in fields.prefix(2) {
                guard !notation.isEmpty else { continue }
                let matches = board.legalMoves(for: side).filter {
                    normalizeWizardNotation(
                        ChineseNotation.convert(uci: $0.uci, state: board)
                    ) == notation
                }
                guard matches.count == 1, let move = matches.first else {
                    return nil
                }
                replayed.append((side, move))
                board = board.applying(move)
                side = side == .red ? .black : .red
                board.redToMove = (side == .red)
                keys.append(board.toFEN())
            }
        }
        return WizardReplay(board: board, sideToMove: side,
                            moves: replayed, positionKeys: keys)
    }

    private func collectWizardMoveLines(
        from element: AXUIElement,
        depth: Int,
        into lines: inout [String]
    ) {
        guard depth <= 12 else { return }
        // Different XQWizard releases publish each score row as either its
        // accessibility description, value, or title.  Read all three, but
        // only retain text that begins with a numbered move row.
        for attribute in [kAXDescriptionAttribute, kAXValueAttribute, kAXTitleAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let text = value as? String,
               text.range(of: #"^\s*\d+[\.．]"#, options: .regularExpression) != nil,
               !lines.contains(text) {
                lines.append(text)
            }
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenValue
        ) == .success,
              let children = childrenValue as? [AXUIElement]
        else { return }
        for child in children {
            collectWizardMoveLines(from: child, depth: depth + 1, into: &lines)
        }
    }

    private func wizardMoveNumber(_ line: String) -> Int {
        let digits = line.drop(while: { $0.isWhitespace }).prefix { $0.isNumber }
        return Int(digits) ?? Int.max
    }

    /// Normalizes both score-row formats emitted by XQWizard:
    /// `1.,炮八平五,马2进3` and `1. 炮八平五, 马2进3`.
    private func wizardNotationFields(in line: String) -> [String] {
        let withoutNumber = line.replacingOccurrences(
            of: #"^\s*\d+[\.．]\s*"#,
            with: "",
            options: .regularExpression
        )
        return withoutNumber
            .replacingOccurrences(of: "，", with: ",")
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { normalizeWizardNotation(String($0)) }
            .filter { !$0.isEmpty }
    }

    private func normalizeWizardNotation(_ raw: String) -> String {
        let digitMap: [Character: Character] = [
            "1":"一", "2":"二", "3":"三", "4":"四", "5":"五",
            "6":"六", "7":"七", "8":"八", "9":"九",
            "１":"一", "２":"二", "３":"三", "４":"四", "５":"五",
            "６":"六", "７":"七", "８":"八", "９":"九"
        ]
        return String(raw.compactMap { character in
            if character.isWhitespace { return nil }
            return digitMap[character] ?? character
        })
    }

    private func wouldRevisitRepeatedPosition(_ move: UCIMove, in board: BoardState) -> Bool {
        var next = board.applying(move)
        next.redToMove.toggle()
        let key = next.toFEN()
        return recentPositionKeys.filter { $0 == key }.count >= 2
    }

    private func shouldAvoidForRepetition(
        _ move: UCIMove,
        in board: BoardState,
        side: PieceSide
    ) -> Bool {
        if wouldRevisitRepeatedPosition(move, in: board) { return true }
        let currentVisits = recentPositionKeys.filter { $0 == board.toFEN() }.count
        guard currentVisits >= 2,
              let previous = observedMoves.last(where: { $0.side == side })?.move
        else { return false }
        return move.from == previous.to && move.to == previous.from
    }

}

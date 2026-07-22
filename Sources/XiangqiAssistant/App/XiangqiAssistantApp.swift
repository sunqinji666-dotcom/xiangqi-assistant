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

    private var analysisTask: Task<Void, Never>?
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
    private var currentSideToMove: PieceSide = .red
    private var candidateBoard: BoardState?
    private var candidateCount = 0
    private var candidatePlies = 0
    private var consecutiveBadFrames = 0
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
                let previousWindowID = self.captureManager.selectedWindowID
                let previousTarget = self.captureManager.selectedWindowStableIdentifier
                await self.captureManager.requestPermission()
                self.refreshWindowList()
                let sourceChanged = previousWindowID
                        != self.captureManager.selectedWindowID
                    || previousTarget
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
        vm.onClearBoard = { [weak self] in
            guard let self else { return }
            BoardGeometry.delete()
            BoardGeometrySourceStore.clear()
            self.recognizer.resetCaptureSourceState()
            self.recognizer.boardGeometry = nil
            self.vm.hasBoardGeometry = false
            self.resetCaptureSession(message: "棋盘框选已清除")
        }
        vm.onPlayerSideChanged = { [weak self] playerSide in
            guard let self else { return }
            // The side picker must never rewrite turn inference or discard a
            // trusted position.  It does, however, control which side gets a
            // displayed move: while an opponent is thinking we keep tracking
            // and pondering, but do not present their move as ours.
            if self.currentSideToMove != playerSide {
                self.showWaitingForOpponent(side: self.currentSideToMove)
            } else if self.lastConfirmedBoard != nil {
                // An answer may already have been computed while this side
                // was hidden. Ask the existing capture loop to publish a
                // fresh, user-side result without resetting the session.
                self.forceEngineRefresh = true
            }
        }
        vm.onAnalysisModeChanged = { [weak self] _ in
            guard let self else { return }
            self.searchCoordinator.cancel()
            self.searchRevision += 1
            self.activeSearchPositionKey = nil
            self.completedSearchPositionKey = nil
            self.ponderHint = nil
            self.forceEngineRefresh = true
            self.vm.lastAnalyzedBoard = nil
            self.vm.bestMove = "--"
            self.vm.bestMoveCN = "--"
            self.vm.recommendedSide = nil
            self.resetDisplayedEvaluation()
            self.vm.searchDetail = "棋力模式已切换，准备重新计算"
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
                return
            }

            var savedGeometry = geo
            if let windowFrame = self.captureManager.selectedWindowFrame {
                savedGeometry = geo.storingWindowRelativeRect(
                    windowFrame: windowFrame
                )
                guard savedGeometry.windowNormalizedRect != nil else {
                    self.vm.calibrationMessage = "❌ 框选区域不在目标窗口内，请重新框选"
                    return
                }
            }
            savedGeometry.save()
            BoardGeometrySourceStore.save(sourceKey: sourceKey)
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
        menu.addItem(withTitle: "清除框选",         action: #selector(clearBoardGeometry),  keyEquivalent: "")
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
        guard var geometry = BoardGeometry.load() else {
            recognizer.boardGeometry = nil
            vm.hasBoardGeometry = false
            return
        }

        let savedSourceKey = BoardGeometrySourceStore.sourceKey
        let currentSourceKey = captureManager.selectedCaptureSourceKey
        let isCompatible = savedSourceKey != nil
            && savedSourceKey == currentSourceKey

        if isCompatible,
           captureManager.selectedWindowID != nil,
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
            geometry.save()
        }

        recognizer.boardGeometry = isCompatible ? geometry : nil
        vm.hasBoardGeometry = isCompatible
        if isCompatible, captureManager.isFullScreenCaptureSelected {
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
        BoardGeometrySourceStore.save(sourceKey: currentSourceKey)
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
        BoardGeometry.delete()
        BoardGeometrySourceStore.clear()
        recognizer.resetCaptureSourceState()
        recognizer.boardGeometry = nil
        vm.hasBoardGeometry = false
        resetCaptureSession(message: "棋盘框选已清除")
        vm.calibrationMessage = "框选已清除，将恢复 Vision 自动检测"
    }

    // MARK: Analysis Loop

    @objc private func startAnalysis() {
        guard analysisTask == nil else { return }
        guard recognizer.usesTheOneModel || templateLibrary.isCalibrated else {
            vm.calibrationMessage = "请先完成校准再开始分析"
            return
        }
        // A fresh Xiangqi game always starts with Red. `playerSide` means who
        // operates this assistant, not whose turn the engine should assume.
        lastConfirmedBoard = nil
        currentSideToMove = .red
        candidateBoard = nil
        candidateCount = 0
        candidatePlies = 0
        consecutiveBadFrames = 0
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
        // Keep the steady "就绪" indicator while the periodic refresh runs.
        // Setting .capturing on every 0.5 s tick made a successful analysis
        // visibly flicker between "识别中" and "就绪".
        if vm.status != .stable {
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
            recordBadFrame()
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

        guard result != nil || wizardReplay != nil else {
            vm.bestMoveCN = "定位失败"
            vm.bestMove = "未找到棋盘区域"
            print("[Analysis] recognizer and XQWizard replay both returned nil")
            vm.calibrationMessage = "诊断：已截到窗口，但棋盘与棋谱均未返回结果"
            saveCaptureDiagnostic(image)
            recordBadFrame()
            return
        }
        if let result, result.status != .stable {
            vm.diagnosticCapture = NSImage(cgImage: image, size: .zero)
            print("[Analysis] model status=\(String(describing: result.status)) valid=\(result.boardState.isValid)")
            // After a position has been locked, a noisy frame is diagnostic
            // evidence only. It must not overwrite the reliable move display.
            if lastConfirmedBoard == nil {
                vm.calibrationMessage = "正在锁定棋盘局面…"
            }
            saveCaptureDiagnostic(image)
        }

        var board = wizardReplay?.board ?? result!.boardState
        let usedWizardReplay = wizardReplay != nil
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

        // Used only by the brain layer to reuse a predicted response when the
        // opponent actually follows Pikafish's principal variation.
        var acceptedTransition: (originFEN: String, move: UCIMove)?

        // ── Inter-frame validation & turn inference ──────────────────────────
        if let prev = lastConfirmedBoard {
            if prev.sameLayout(as: board) {
                consecutiveBadFrames = 0
                candidateBoard = nil
                candidateCount = 0
                candidatePlies = 0
                board.redToMove = (currentSideToMove == .red)
                if !forceEngineRefresh {
                    // Engine work is deliberately independent from this 0.5 s
                    // recognition loop. Keep its visible state while the same
                    // trusted board is deepening in the background.
                    if activeSearchPositionKey == nil {
                        vm.status = .stable
                    }
                    return
                }
            } else {
                // Every changed layout—raw, repaired, one ply or two plies—must
                // appear in two matching captures. This prevents a selection
                // highlight or animation frame from poisoning the trusted state.
                let sideBeforeTransition = currentSideToMove
                var proposedBoard: BoardState?
                var proposedPlies = 0
                let observedIsValid = board.isValid
                let isOnePly = observedIsValid && (
                    prev.isLegalTransition(to: board, movingSide: currentSideToMove) ||
                    prev.isPlausibleSingleMove(to: board, movingSide: currentSideToMove)
                )
                let isTwoPly = observedIsValid && !isOnePly && prev.isLegalTwoPlyTransition(
                    to: board, firstSide: currentSideToMove
                )
                if isOnePly {
                    proposedBoard = board
                    proposedPlies = 1
                } else if isTwoPly {
                    proposedBoard = board
                    proposedPlies = 2
                } else if let repaired = prev.bestMatchingTransition(
                    to: board,
                    firstSide: currentSideToMove,
                    maxMismatches: 2
                ) {
                    proposedBoard = repaired.state
                    proposedPlies = repaired.plies
                } else {
                    candidateBoard = nil
                    candidateCount = 0
                    candidatePlies = 0
                    vm.status = .stable
                    vm.errorMessage = nil
                    return
                }

                guard let proposedBoard else { return }
                if let previousCandidate = candidateBoard,
                   previousCandidate.sameLayout(as: proposedBoard),
                   candidatePlies == proposedPlies {
                    candidateCount += 1
                } else {
                    candidateBoard = proposedBoard
                    candidateCount = 1
                    candidatePlies = proposedPlies
                }
                // A selected piece, animation or move marker can remain on
                // screen for around one second. Require three identical
                // observations before a displayed move becomes trusted.
                guard candidateCount >= 3 else {
                    vm.status = .stable
                    vm.errorMessage = nil
                    return
                }
                board = proposedBoard

                if proposedPlies == 1 {
                    currentSideToMove = currentSideToMove == .red ? .black : .red
                }
                if let sequence = prev.transitionMoves(to: board, firstSide: sideBeforeTransition),
                   sequence.count == proposedPlies {
                    if proposedPlies == 1, let onlyMove = sequence.first {
                        var origin = prev
                        origin.redToMove = (sideBeforeTransition == .red)
                        acceptedTransition = (origin.toFEN(), onlyMove)
                    }
                    var side = sideBeforeTransition
                    for move in sequence {
                        observedMoves.append((side, move))
                        side = side == .red ? .black : .red
                    }
                } else {
                    historyFromStart = false
                }
                candidateBoard = nil
                candidateCount = 0
                candidatePlies = 0
            }
        } else {
            // A raw frame with a highlighted/miscoloured piece can be marked
            // invalid by the vision model.  When the visible XQWizard score
            // sheet has independently replayed to the same board, that
            // replay is stronger evidence than the raw model status and is
            // safe to use for the initial trusted position.
            guard (result?.status == .stable || usedWizardReplay), board.isValid else {
                candidateBoard = nil
                candidateCount = 0
                candidatePlies = 0
                recordBadFrame()
                return
            }
            // The opening position has no earlier board that can prove it.
            // Confirm it twice before the engine sees it.
            if let previousCandidate = candidateBoard, previousCandidate.sameLayout(as: board) {
                candidateCount += 1
            } else {
                candidateBoard = board
                candidateCount = 1
                candidatePlies = 0
            }
            // The first position has no preceding move to validate it
            // against, so use the same stricter three-frame confirmation.
            guard candidateCount >= 3 else {
                vm.status = .capturing
                return
            }
            historyFromStart = board.sameLayout(as: BoardState.initialPosition())
            observedMoves = []
            recentPositionKeys = []
        }
        consecutiveBadFrames = 0

        // Defense in depth: only a materially valid position may become the
        // next trusted state or reach the engine/UI.
        guard board.isValid else {
            recordBadFrame()
            return
        }

        // Engine positions always use canonical coordinates. Only the preview
        // mirrors a client that has rendered Black at the bottom of the screen.
        vm.previewIsReversed = previewIsReversed

        if let replay = wizardReplay, replay.board.sameLayout(as: board) {
            currentSideToMove = replay.sideToMove
            historyFromStart = true
            observedMoves = replay.moves
            recentPositionKeys = replay.positionKeys
        }

        board.redToMove = (currentSideToMove == .red)
        lastConfirmedBoard = board
        appendPositionKey(board.toFEN())

        let fen = board.toFEN()
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

        // Ponder without a second engine process: while the opponent was
        // thinking, the previous PV already contained our predicted response.
        // If the observed move matches, show that legal reply instantly, then
        // let the fresh 2→6→15 second search confirm or improve it.
        if let transition = acceptedTransition,
           let hint = ponderHint,
           hint.originFEN == transition.originFEN,
           hint.predictedMove == transition.move.uci,
           hint.targetSide == sideAtRequest,
           hint.mode == modeAtRequest,
           let response = UCIMove(uci: hint.response.uci),
           board.isLegalMove(response, for: sideAtRequest) {
            applyBrainUpdate(
                BrainSearchUpdate(
                    revision: revision,
                    positionKey: positionKey,
                    phase: .quick,
                    source: .ponderCache,
                    move: hint.response
                ),
                board: board,
                side: sideAtRequest,
                fen: fen,
                mode: modeAtRequest
            )
        }
        if acceptedTransition != nil { ponderHint = nil }

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
                self.vm.status = .capturing
                self.vm.errorMessage = "引擎已自动恢复：\(error.localizedDescription)"
                self.vm.searchDetail = "准备重新分析"
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

        // Continue analysing the opponent's turn for the ponder cache, but
        // never draw their best move as an instruction for the player.  The
        // previous version only stored `playerSide` as a label, which made a
        // Black player see a green Red arrow until Red had physically moved.
        guard side == vm.playerSide else {
            showWaitingForOpponent(side: side, board: board)
            buildPonderHintIfPossible(
                update: update,
                board: board,
                side: side,
                fen: fen,
                mode: mode
            )
            return
        }

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
        buildPonderHintIfPossible(
            update: update,
            board: board,
            side: side,
            fen: fen,
            mode: mode
        )
    }

    private func showWaitingForOpponent(side: PieceSide, board: BoardState? = nil) {
        let opponentLabel = side == .red ? "红方" : "黑方"
        vm.bestMove = "--"
        vm.bestMoveCN = "等待\(opponentLabel)走棋"
        vm.recommendedSide = nil
        vm.depth = 0
        vm.pv = []
        if let board { vm.lastAnalyzedBoard = board }
        vm.status = .stable
        vm.searchDetail = "我方\(vm.playerSide == .red ? "红方" : "黑方") · 等待\(opponentLabel)走棋"
        vm.errorMessage = nil
    }

    private func buildPonderHintIfPossible(
        update: BrainSearchUpdate,
        board: BoardState,
        side: PieceSide,
        fen: String,
        mode: AnalysisMode
    ) {
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

    /// Clears only the state learned from the current capture source. Models,
    /// templates, engine configuration, and any compatible saved board geometry
    /// remain intact when the user switches to another application window.
    private func resetCaptureSession(message: String?) {
        searchCoordinator.cancel()
        searchRevision += 1
        activeSearchPositionKey = nil
        completedSearchPositionKey = nil
        ponderHint = nil

        lastConfirmedBoard = nil
        currentSideToMove = .red
        candidateBoard = nil
        candidateCount = 0
        candidatePlies = 0
        consecutiveBadFrames = 0
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
        resetDisplayedEvaluation()
        vm.status = vm.isRunning ? .capturing : .idle
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

    /// Keep a good board visible through occasional bad screenshots. Only a
    /// sustained failure is shown as an actual recognition problem.
    private func recordBadFrame() {
        consecutiveBadFrames += 1
        print("[Analysis] bad frame #\(consecutiveBadFrames), confirmed=\(lastConfirmedBoard != nil)")
        if lastConfirmedBoard != nil {
            // Preserve the last trusted board indefinitely.  Recognition can
            // resume as soon as a legal successor appears; an arbitrary count
            // of bad frames must never invalidate known-good state.
            vm.status = .stable
        } else if consecutiveBadFrames < 5 {
            vm.status = .capturing
        } else {
            vm.status = .unstable
        }
    }
}

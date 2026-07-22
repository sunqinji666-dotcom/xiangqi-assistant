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

    private struct WizardReplay {
        let board: BoardState
        let sideToMove: PieceSide
        let moves: [(side: PieceSide, move: UCIMove)]
        let positionKeys: [String]
    }

    private var statusItem: NSStatusItem?
    private let vm = AssistantViewModel()
    private let engine = PikafishEngine()
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
            guard let self else { return }
            if let wid = windowID,
               let win = self.captureManager.availableWindows.first(where: { $0.windowID == wid }) {
                self.captureManager.selectWindow(win)
            } else {
                self.captureManager.clearWindowSelection()
            }
            self.vm.selectedWindowID = windowID
        }
        vm.onRefreshWindows = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.captureManager.requestPermission()
                self.refreshWindowList()
            }
        }
        // This app intentionally does not install any mouse-control callback.
        // Accessibility is used solely to read XQWizard's score sheet for
        // position verification; it never sends click events to the board.
        vm.onSelectBoard = { [weak self] in
            self?.boardSelector.show()
        }
        vm.onClearBoard = { [weak self] in
            guard let self else { return }
            BoardGeometry.delete()
            self.recognizer.boardGeometry = nil
            self.vm.hasBoardGeometry = false
        }
        vm.onPlayerSideChanged = { [weak self] side in
            guard let self else { return }
            // Player side controls whether auto-play is allowed. It must not
            // overwrite the actual turn state; a fresh game always starts Red.
            self.currentSideToMove = .red
            self.lastConfirmedBoard = nil
            self.vm.lastAnalyzedBoard = nil
            self.vm.bestMove = "--"
            self.vm.bestMoveCN = "--"
            self.vm.recommendedSide = nil
            self.historyFromStart = false
            self.observedMoves = []
            self.recentPositionKeys = []
        }
        vm.onAnalysisModeChanged = { [weak self] _ in
            guard let self else { return }
            self.forceEngineRefresh = true
            self.vm.lastAnalyzedBoard = nil
        }
        // Restore saved board geometry if any
        vm.hasBoardGeometry = recognizer.boardGeometry != nil
        captureManager.selectDisplay(recognizer.boardGeometry?.displayID)
        boardSelector.onGeometry = { [weak self] geo in
            guard let self else { return }
            geo.save()
            self.recognizer.boardGeometry = geo
            // The overlay records primary-screen coordinates. Use a matching
            // full-screen capture rather than mixing them with SCWindow's
            // global coordinates (which may belong to another display).
            self.captureManager.clearWindowSelection()
            self.captureManager.selectDisplay(geo.displayID)
            self.vm.selectedWindowID = nil
            self.vm.hasBoardGeometry = true
            self.vm.calibrationMessage = "✅ 棋盘已定位，手动框选成功"
        }
        boardSelector.onCancel = { }

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
            (id: $0.windowID, title: $0.title ?? "未知窗口")
        }
        vm.availableWindows = windows
    }

    private func autoSelectChessApp() {
        for keyword in Self.chessAppKeywords {
            if let win = captureManager.autoSelectWindow(titleContaining: keyword) {
                vm.selectedWindowID = win.windowID
                vm.availableWindows = captureManager.availableWindows.map {
                    (id: $0.windowID, title: $0.title ?? "未知窗口")
                }
                print("[AutoDetect] 已自动选择窗口: \(win.title ?? keyword)")
                return
            }
        }
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
        boardSelector.show()
    }

    @objc private func clearBoardGeometry() {
        BoardGeometry.delete()
        recognizer.boardGeometry = nil
        vm.hasBoardGeometry = false
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
        vm.bestMove = "--"
        vm.bestMoveCN = "--"
        vm.recommendedSide = nil
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
        vm.isRunning = false
        vm.status = .idle
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
        recognizer.preferredWindowBoardRect = vm.windowTitle
            .localizedCaseInsensitiveContains("象棋巫师")
            ? CGRect(x: 0.065, y: 0.075, width: 0.64, height: 0.88)
            : nil

        guard let image = await captureManager.captureFrame() else {
            vm.bestMoveCN = "截图失败"
            vm.bestMove = captureManager.lastCaptureError ?? "未取得窗口图像"
            print("[Analysis] no capture: \(captureManager.lastCaptureError ?? "unknown")")
            vm.errorMessage = captureManager.lastCaptureError
                ?? "未取得象棋巫师截图，请检查屏幕录制权限"
            recordBadFrame()
            return
        }

        let wizardIsRunning = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.jpcxc.xqwiphone")
            .contains(where: { !$0.isTerminated })
        let isWizardTarget = vm.windowTitle
            .localizedCaseInsensitiveContains("象棋巫师") || (
                vm.selectedWindowID == nil &&
                recognizer.boardGeometry != nil &&
                wizardIsRunning
            )
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

        // ── Inter-frame validation & turn inference ──────────────────────────
        if let prev = lastConfirmedBoard {
            if prev.sameLayout(as: board) {
                consecutiveBadFrames = 0
                candidateBoard = nil
                candidateCount = 0
                candidatePlies = 0
                board.redToMove = (currentSideToMove == .red)
                if !forceEngineRefresh {
                    vm.status = .stable
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
                    to: board, firstSide: currentSideToMove
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
                guard candidateCount >= 2 else {
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
            guard candidateCount >= 2 else {
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

        if let replay = wizardReplay, replay.board.sameLayout(as: board) {
            currentSideToMove = replay.sideToMove
            historyFromStart = true
            observedMoves = replay.moves
            recentPositionKeys = replay.positionKeys
        }

        board.redToMove = (currentSideToMove == .red)
        lastConfirmedBoard = board
        appendPositionKey(board.toFEN())

        // ── Skip if board unchanged since last analysis ──────────────────────
        if let analyzed = vm.lastAnalyzedBoard, analyzed.sameLayout(as: board), analyzed.redToMove == board.redToMove {
            vm.status = .stable; return
        }

        vm.status = .analyzing
        let fen = board.toFEN()
        let sideAtRequest = currentSideToMove
        let layoutAtRequest = board

        do {
            let moveHistory = historyFromStart ? observedMoves.map { $0.move.uci } : nil
            var move: EngineMove
            switch vm.analysisMode {
            case .aggressive:
                let candidates = try await engine.analyzeCandidates(
                    fen: fen,
                    movesFromStart: moveHistory,
                    movetime: StrengthProfile.aggressiveMoveTime,
                    count: StrengthProfile.aggressiveCandidates
                )
                guard !candidates.isEmpty else {
                    throw EngineError.launchFailed("引擎没有返回候选走法")
                }
                move = AggressiveMoveSelector.select(
                    from: candidates,
                    board: board,
                    side: sideAtRequest,
                    history: historyFromStart ? observedMoves.map { $0.move.uci } : nil
                ) ?? candidates[0]
            case .normal:
                move = try await engine.analyze(
                    fen: fen,
                    movesFromStart: moveHistory,
                    movetime: StrengthProfile.normalMoveTime
                )
            case .ultra:
                // Single-PV search spends the entire budget on the objectively
                // strongest move instead of dividing it among style choices.
                move = try await engine.analyze(
                    fen: fen,
                    movesFromStart: moveHistory,
                    movetime: StrengthProfile.ultraMoveTime
                )
            }
            if let firstChoice = UCIMove(uci: move.uci),
               shouldAvoidForRepetition(firstChoice, in: board, side: sideAtRequest) {
                let alternatives = board.legalMoves(for: sideAtRequest)
                    .filter { $0 != firstChoice }
                    .filter { !wouldRevisitRepeatedPosition($0, in: board) }
                    .map(\.uci)
                if !alternatives.isEmpty {
                    move = try await engine.analyze(
                        fen: fen,
                        movesFromStart: moveHistory,
                        movetime: StrengthProfile.repetitionRecoveryMoveTime,
                        searchMoves: alternatives
                    )
                }
            }
            // The board may have changed while the engine was thinking.
            guard currentSideToMove == sideAtRequest,
                  lastConfirmedBoard?.sameLayout(as: layoutAtRequest) == true,
                  let uciMove = UCIMove(uci: move.uci),
                  let movingPiece = board[uciMove.from],
                  movingPiece.side == sideAtRequest,
                  board.isLegalMove(uciMove, for: sideAtRequest)
            else {
                vm.status = .stable
                return
            }
            vm.bestMove        = move.uci
            vm.bestMoveCN      = ChineseNotation.convert(uci: move.uci, state: board)
            vm.recommendedSide = sideAtRequest
            vm.score           = move.score
            vm.depth           = move.depth
            vm.pv              = move.pv
            vm.status          = .stable
            vm.lastAnalyzedBoard = board
            forceEngineRefresh = false
            vm.errorMessage    = nil
        } catch {
            if Task.isCancelled {
                vm.status = .idle
                return
            }
            // Pikafish can leave its output stream unusable after an analysis
            // task is interrupted. Recover in place instead of leaving the UI
            // permanently stuck on “引擎输出流已关闭”.
            do {
                try await engine.restart()
                forceEngineRefresh = true
                vm.status = .capturing
                vm.errorMessage = "引擎已自动恢复，正在重新分析"
                return
            } catch {
                vm.errorMessage = error.localizedDescription
            }
            vm.status = .error
        }
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

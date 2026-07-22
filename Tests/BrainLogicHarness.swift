import Foundation
import CoreGraphics

private enum HarnessFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self { case .assertion(let message): return message }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw HarnessFailure.assertion(message) }
}

@main
struct BrainLogicHarness {
    static func main() async {
        do {
            try await run()
            print("BRAIN_HARNESS_OK")
        } catch {
            print("BRAIN_HARNESS_FAILED: \(error)")
            exit(1)
        }
    }

    private static func run() async throws {
        guard CommandLine.arguments.count >= 2 else {
            throw HarnessFailure.assertion("missing opening-book path")
        }
        try testWindowCandidatePolicy()
        try testBoardOrientationCanonicalization()
        try testPerspectiveAndMatePresentation()
        try testStableRecommendation()
        try testAggressiveMateSafety()
        try testOpeningBook(path: CommandLine.arguments[1])
        try testTerminalBoard()
        try await testLineMailbox()
        try await testRealEngine()
    }

    private static func testWindowCandidatePolicy() throws {
        let ownPID: Int32 = 42
        let ownBundleID = "com.xiangqi.XiangqiAssistant.TheOne"

        func candidate(
            title: String? = "棋局",
            applicationName: String? = "第三方象棋",
            bundleIdentifier: String? = "com.example.chess",
            processID: Int32 = 100,
            frame: CGRect = CGRect(x: 20, y: 20, width: 900, height: 700),
            layer: Int = 0,
            isOnScreen: Bool = true,
            kind: WindowCandidateMetadata.ApplicationKind = .regular,
            isTerminated: Bool = false
        ) -> WindowCandidateMetadata {
            WindowCandidateMetadata(
                title: title,
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                processID: processID,
                frame: frame,
                windowLayer: layer,
                isOnScreen: isOnScreen,
                applicationKind: kind,
                isTerminated: isTerminated
            )
        }

        func included(_ value: WindowCandidateMetadata) -> Bool {
            WindowCandidatePolicy.shouldInclude(
                value,
                currentProcessID: ownPID,
                currentBundleIdentifier: ownBundleID
            )
        }

        try expect(included(candidate()), "ordinary chess window was filtered out")
        try expect(
            included(candidate(
                title: "Apple",
                applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari"
            )),
            "normal Apple application was blanket-filtered"
        )
        try expect(
            included(candidate(
                title: nil,
                applicationName: "iOS 象棋",
                bundleIdentifier: "com.example.ioschess"
            )),
            "user-facing untitled game window was filtered out"
        )
        try expect(
            !included(candidate(
                title: nil,
                applicationName: "辅助面板",
                frame: CGRect(x: 0, y: 0, width: 240, height: 160)
            )),
            "small untitled helper window leaked into the window list"
        )
        try expect(
            !included(candidate(
                applicationName: "Dock",
                bundleIdentifier: "com.apple.dock"
            )),
            "Dock leaked into the window list"
        )
        try expect(
            included(candidate(
                applicationName: "Dock",
                bundleIdentifier: "com.example.user-dock"
            )),
            "third-party app was filtered only because its display name matched a system process"
        )
        try expect(
            !included(candidate(
                applicationName: "Control Center",
                bundleIdentifier: "com.apple.controlcenter"
            )),
            "Control Center leaked into the window list"
        )
        try expect(
            !included(candidate(processID: ownPID)),
            "current process leaked into the window list"
        )
        try expect(
            !included(candidate(
                bundleIdentifier: ownBundleID,
                processID: ownPID + 1
            )),
            "another assistant instance leaked into the window list"
        )
        try expect(
            !included(candidate(layer: 12)),
            "high-level system panel leaked into the window list"
        )
        try expect(
            !included(candidate(
                frame: CGRect(x: 0, y: 0, width: 120, height: 80)
            )),
            "tiny helper window leaked into the window list"
        )
        try expect(
            included(candidate(
                applicationName: "Wine Chess",
                bundleIdentifier: "org.wine.chess",
                kind: .accessory
            )),
            "substantial accessory-hosted game was filtered out"
        )
        try expect(
            !included(candidate(
                frame: CGRect(x: 0, y: 0, width: 250, height: 160),
                kind: .accessory
            )),
            "small accessory panel leaked into the window list"
        )
        try expect(
            !included(candidate(kind: .prohibited)),
            "prohibited background process leaked into the window list"
        )
        try expect(
            WindowCandidatePolicy.displayTitle(
                applicationName: "Safari",
                windowTitle: "在线象棋"
            ) == "Safari — 在线象棋",
            "window display title lost application context"
        )
    }

    private static func testPerspectiveAndMatePresentation() throws {
        try expect(
            AdaptiveSearchPolicy.redPerspectiveScore(42, sideToMove: .red) == 42,
            "red score changed sign"
        )
        try expect(
            AdaptiveSearchPolicy.redPerspectiveScore(42, sideToMove: .black) == -42,
            "black score was not normalized"
        )
        try expect(
            AdaptiveSearchPolicy.redPerspectiveMateDistance(-4, sideToMove: .black) == 4,
            "black-to-move mate direction was not normalized"
        )
        try expect(
            AdaptiveSearchPolicy.mateChineseText(
                mateDistanceFromSideToMove: -4,
                sideToMove: .black
            ) == "红方预计 4 步杀",
            "mate label is incorrect"
        )
    }

    private static func testBoardOrientationCanonicalization() throws {
        let initial = BoardState.initialPosition()
        let reversed = initial.rotated180()
        try expect(!reversed.isValid,
                   "opposite-viewpoint fixture unexpectedly passed canonical validation")
        let canonical = reversed.canonicalOrientation()
        try expect(canonical.wasReversed,
                   "opposite-viewpoint board was not recognized as reversed")
        try expect(canonical.state.sameLayout(as: initial),
                   "opposite-viewpoint board did not rotate back to the initial layout")
    }

    private static func testStableRecommendation() throws {
        let old = AdaptiveSearchPolicy.Recommendation(
            positionKey: "position w", move: "h2e2", scoreCentipawns: 20
        )
        let tied = AdaptiveSearchPolicy.Recommendation(
            positionKey: "position w", move: "c3c4", scoreCentipawns: 27
        )
        let stronger = AdaptiveSearchPolicy.Recommendation(
            positionKey: "position w", move: "c3c4", scoreCentipawns: 35
        )
        try expect(
            AdaptiveSearchPolicy.stabilizedRecommendation(previous: old, incoming: tied).move == old.move,
            "near-tied recommendation flickered"
        )
        try expect(
            AdaptiveSearchPolicy.stabilizedRecommendation(previous: old, incoming: stronger).move == stronger.move,
            "materially stronger recommendation was suppressed"
        )

        let longMate = AdaptiveSearchPolicy.Recommendation(
            positionKey: "position w", move: "a0a1", scoreCentipawns: 99_995, mateDistance: 5
        )
        let shortMate = AdaptiveSearchPolicy.Recommendation(
            positionKey: "position w", move: "a0a2", scoreCentipawns: 99_997, mateDistance: 3
        )
        try expect(
            AdaptiveSearchPolicy.stabilizedRecommendation(previous: longMate, incoming: shortMate).move == shortMate.move,
            "shorter forced mate was suppressed"
        )
    }

    private static func testAggressiveMateSafety() throws {
        let board = BoardState.initialPosition()
        let wins = [
            EngineMove(uci: "h2e2", score: 99_997, mateIn: 3, depth: 20, pv: ["h2e2"]),
            EngineMove(uci: "b2e2", score: 99_995, mateIn: 5, depth: 20, pv: ["b2e2"])
        ]
        try expect(
            AggressiveMoveSelector.select(from: wins, board: board, side: .red, history: [])?.mateIn == 3,
            "aggressive mode lengthened a forced mate"
        )
        let losses = [
            EngineMove(uci: "h2e2", score: -99_992, mateIn: -8, depth: 20, pv: ["h2e2"]),
            EngineMove(uci: "b2e2", score: -99_999, mateIn: -1, depth: 20, pv: ["b2e2"])
        ]
        try expect(
            AggressiveMoveSelector.select(from: losses, board: board, side: .red, history: [])?.mateIn == -8,
            "aggressive mode chose a faster loss"
        )
    }

    private static func testOpeningBook(path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let book = OpeningBook(data: data)
        try expect(book.positionCount >= 60, "opening book lost most positions")
        try expect(book.candidateCount >= 80, "opening book lost most candidates")
        var board = BoardState.initialPosition()
        board.redToMove = true
        let candidates = book.candidates(for: board.toFEN(), board: board, side: .red)
        try expect(!candidates.isEmpty, "initial position has no opening candidates")
        for candidate in candidates {
            guard let move = UCIMove(uci: candidate.uci) else {
                throw HarnessFailure.assertion("book contains malformed UCI")
            }
            try expect(board.isLegalMove(move, for: .red), "book returned an illegal move")
        }
    }

    private static func testTerminalBoard() throws {
        var board = BoardState()
        board.redToMove = false
        board[4, 0] = Piece(kind: .king, side: .black)
        board[0, 0] = Piece(kind: .rook, side: .red)
        board[4, 2] = Piece(kind: .rook, side: .red)
        board[4, 9] = Piece(kind: .king, side: .red)
        try expect(board.isValid, "terminal fixture is structurally invalid")
        try expect(board.legalMoves(for: .black).isEmpty,
                   "terminal fixture unexpectedly has a legal move")
        try expect(
            board.toFEN() == "R3k4/9/4R4/9/9/9/9/9/9/4K4 b - - 0 1",
            "terminal fixture FEN changed"
        )
    }

    private static func testLineMailbox() async throws {
        let timed = EngineLineMailbox()
        let startedAt = Date()
        do {
            _ = try await timed.next(timeout: 0.08)
            throw HarnessFailure.assertion("silent mailbox did not time out")
        } catch EngineError.timeout {
            let elapsed = Date().timeIntervalSince(startedAt)
            try expect(elapsed >= 0.05 && elapsed < 0.6,
                       "mailbox timeout was not governed by wall clock")
        }

        let delivered = EngineLineMailbox()
        let pending = Task { try await delivered.next(timeout: 0.5) }
        try await Task.sleep(nanoseconds: 20_000_000)
        delivered.push("uciok")
        let deliveredLine = try await pending.value
        try expect(deliveredLine == "uciok",
                   "mailbox did not wake a pending reader")

        let draining = EngineLineMailbox()
        draining.push("bestmove h2e2")
        draining.finish(EngineError.launchFailed("test EOF"))
        let bufferedLine = try await draining.next(timeout: 0.1)
        try expect(bufferedLine == "bestmove h2e2",
                   "mailbox discarded buffered output at EOF")
        do {
            _ = try await draining.next(timeout: 0.1)
            throw HarnessFailure.assertion("finished mailbox did not report EOF")
        } catch EngineError.launchFailed {
            // Expected after the already-buffered line has been drained.
        }
    }

    private static func testRealEngine() async throws {
        let engine = PikafishEngine()
        try await engine.start()

        let redMateFEN = "4k4/9/9/9/9/R3P4/9/9/9/4K4 w - - 0 1"
        let blackMateFEN = "4k4/9/9/9/9/R3P4/9/9/9/4K4 b - - 0 1"
        let redResult = try await engine.analyze(fen: redMateFEN, movetime: 700)
        let blackResult = try await engine.analyze(fen: blackMateFEN, movetime: 700)
        try expect((redResult.mateIn ?? 0) > 0, "real engine did not preserve positive mate distance")
        try expect((blackResult.mateIn ?? 0) < 0, "real engine did not preserve negative mate distance")
        try expect(
            AdaptiveSearchPolicy.redPerspectiveMateDistance(
                redResult.mateIn, sideToMove: .red
            )! > 0,
            "red mate normalized incorrectly"
        )
        try expect(
            AdaptiveSearchPolicy.redPerspectiveMateDistance(
                blackResult.mateIn, sideToMove: .black
            )! > 0,
            "black-turn mate normalized incorrectly"
        )

        let terminalFEN = "R3k4/9/4R4/9/9/9/9/9/9/4K4 b - - 0 1"
        do {
            _ = try await engine.analyze(fen: terminalFEN, movetime: 300)
            throw HarnessFailure.assertion("bestmove (none) escaped as a normal move")
        } catch EngineError.noLegalMove {
            // A completed game is a clean terminal result, not malformed UCI.
        }

        let afterTerminal = try await engine.analyze(
            fen: BoardState.initialPosition().toFEN(),
            movetime: 400
        )
        try expect(UCIMove(uci: afterTerminal.uci) != nil,
                   "engine stream was poisoned after bestmove (none)")

        var phases: [EngineSearchPhase] = []
        let adaptive = try await engine.analyzeAdaptive(
            fen: BoardState.initialPosition().toFEN(),
            quickTime: 500,
            normalTime: 1_200,
            complexTime: 2_500
        ) { update in
            phases.append(update.phase)
        }
        try expect(UCIMove(uci: adaptive.uci) != nil, "adaptive search returned malformed move")
        try expect(phases.contains(.quick) && phases.contains(.final), "adaptive milestones were not published")

        let interrupted = Task {
            try await engine.analyzeAdaptive(
                fen: BoardState.initialPosition().toFEN(),
                quickTime: 2_000,
                normalTime: 6_000,
                complexTime: 15_000
            ) { _ in }
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        await engine.cancelCurrentSearch()
        let drained = try await interrupted.value
        try expect(UCIMove(uci: drained.uci) != nil, "graceful stop did not drain bestmove")

        let recovered = try await engine.analyze(
            fen: BoardState.initialPosition().toFEN(),
            movetime: 500
        )
        try expect(UCIMove(uci: recovered.uci) != nil, "engine did not recover after cancellation")
        try await testCoordinatorReplacement(engine: engine)
        await engine.stop()
    }

    @MainActor
    private static func testCoordinatorReplacement(engine: PikafishEngine) async throws {
        let coordinator = EngineSearchCoordinator(engine: engine)
        var board = BoardState.initialPosition()
        board.redToMove = true
        let first = BrainSearchRequest(
            revision: 101,
            positionKey: "first",
            fen: board.toFEN(),
            movesFromStart: [],
            board: board,
            sideToMove: .red,
            mode: .ultra,
            openingWeights: ["h2e2": 560],
            repetitionForbiddenMoves: [],
            repetitionAllowedMoves: []
        )
        let second = BrainSearchRequest(
            revision: 102,
            positionKey: "second",
            fen: board.toFEN(),
            movesFromStart: [],
            board: board,
            sideToMove: .red,
            mode: .normal,
            openingWeights: [:],
            repetitionForbiddenMoves: [],
            repetitionAllowedMoves: []
        )
        let third = BrainSearchRequest(
            revision: 103,
            positionKey: "third",
            fen: board.toFEN(),
            movesFromStart: [],
            board: board,
            sideToMove: .red,
            mode: .normal,
            openingWeights: [:],
            repetitionForbiddenMoves: [],
            repetitionAllowedMoves: []
        )

        var revisions: [Int] = []
        var failed: Error?
        coordinator.replaceSearch(with: first) { revisions.append($0.revision) } onFailure: { _, error in
            failed = error
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        coordinator.replaceSearch(with: second) { revisions.append($0.revision) } onFailure: { _, error in
            failed = error
        }

        let deadline = Date().addingTimeInterval(5)
        while !revisions.contains(102), Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try expect(failed == nil, "coordinator failed while replacing search")
        try expect(revisions.contains(102), "replacement search did not publish")
        try expect(!revisions.contains(101), "stale search published after replacement")

        coordinator.cancel()
        coordinator.replaceSearch(with: third) { revisions.append($0.revision) } onFailure: { _, error in
            failed = error
        }
        let restartDeadline = Date().addingTimeInterval(5)
        while !revisions.contains(103), Date() < restartDeadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try expect(failed == nil, "coordinator failed after stop/start")
        try expect(revisions.contains(103), "search did not restart after graceful cancellation")
        coordinator.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
    }
}

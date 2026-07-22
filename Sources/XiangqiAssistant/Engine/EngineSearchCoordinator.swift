import Foundation

enum BrainSearchMode {
    case normal
    case aggressive
    case ultra
}

enum BrainSearchSource {
    case engine
    case openingBook
    case ponderCache
}

struct BrainSearchRequest {
    let revision: Int
    let positionKey: String
    let fen: String
    let movesFromStart: [String]?
    let board: BoardState
    let sideToMove: PieceSide
    let mode: BrainSearchMode
    let openingWeights: [String: Int]
    let repetitionForbiddenMoves: Set<String>
    let repetitionAllowedMoves: [String]
}

struct BrainSearchUpdate {
    let revision: Int
    let positionKey: String
    let phase: EngineSearchPhase
    let source: BrainSearchSource
    let move: EngineMove
}

/// Serializes every command sent to the one Pikafish process. Replacing a
/// search first stops and drains the old `bestmove`, then starts the new
/// position. This is the boundary that prevents stale output from ever being
/// interpreted as an answer for a newer screenshot.
@MainActor
final class EngineSearchCoordinator {
    private let engine: PikafishEngine
    private var activeRevision: Int?
    private var task: Task<Void, Never>?
    private var lifecycleToken = 0

    init(engine: PikafishEngine) {
        self.engine = engine
    }

    var isSearching: Bool { task != nil }

    func replaceSearch(
        with request: BrainSearchRequest,
        onUpdate: @escaping (BrainSearchUpdate) -> Void,
        onFailure: @escaping (Int, Error) -> Void
    ) {
        let previous = task
        lifecycleToken += 1
        let token = lifecycleToken
        activeRevision = request.revision

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            if let previous {
                await self.engine.cancelCurrentSearch()
                await previous.value
            }
            guard self.activeRevision == request.revision else { return }

            do {
                try await self.run(request: request, onUpdate: onUpdate)
            } catch is CancellationError {
                // A replacement or user pause is an expected control path.
            } catch EngineError.noLegalMove {
                // This is a valid terminal position, not a damaged engine
                // transport. The app decides how to present game-over state.
                guard self.activeRevision == request.revision else { return }
                onFailure(request.revision, EngineError.noLegalMove)
            } catch let searchError {
                // Restart even when this request has already been superseded.
                // The replacement task awaits this one, so it will inherit a
                // clean UCI stream rather than any undrained stale bestmove.
                let shouldReport = self.activeRevision == request.revision
                do {
                    try await self.engine.restart()
                } catch let restartError {
                    if shouldReport {
                        onFailure(request.revision, restartError)
                    }
                    return
                }
                if shouldReport {
                    onFailure(request.revision, searchError)
                }
            }

            if self.lifecycleToken == token,
               self.activeRevision == request.revision {
                self.task = nil
            }
        }
    }

    func cancel() {
        lifecycleToken += 1
        let token = lifecycleToken
        activeRevision = nil
        let previous = task
        guard let previous else {
            task = nil
            return
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.engine.cancelCurrentSearch()
            await previous.value
            if self.lifecycleToken == token {
                self.task = nil
            }
        }
    }

    private func run(
        request: BrainSearchRequest,
        onUpdate: @escaping (BrainSearchUpdate) -> Void
    ) async throws {
        switch request.mode {
        case .normal:
            var move = try await engine.analyze(
                fen: request.fen,
                movesFromStart: request.movesFromStart,
                movetime: StrengthProfile.normalMoveTime
            )
            guard activeRevision == request.revision else { return }
            move = try await recoverFromRepetitionIfNeeded(move, request: request)
            guard activeRevision == request.revision else { return }
            publish(move, phase: .final, source: .engine,
                    request: request, onUpdate: onUpdate)

        case .aggressive:
            let candidates = try await engine.analyzeCandidates(
                fen: request.fen,
                movesFromStart: request.movesFromStart,
                movetime: StrengthProfile.aggressiveMoveTime,
                count: StrengthProfile.aggressiveCandidates
            )
            guard let first = candidates.first else {
                throw EngineError.launchFailed("引擎没有返回候选走法")
            }
            guard activeRevision == request.revision else { return }
            var move = AggressiveMoveSelector.select(
                from: candidates,
                board: request.board,
                side: request.sideToMove,
                history: request.movesFromStart
            ) ?? first
            move = try await recoverFromRepetitionIfNeeded(move, request: request)
            guard activeRevision == request.revision else { return }
            publish(move, phase: .final, source: .engine,
                    request: request, onUpdate: onUpdate)

        case .ultra:
            try await runUltra(request: request, onUpdate: onUpdate)
        }
    }

    private func runUltra(
        request: BrainSearchRequest,
        onUpdate: @escaping (BrainSearchUpdate) -> Void
    ) async throws {
        var incumbent: EngineMove?

        // The local book never decides a move by itself. Pikafish first ranks
        // the whole position with MultiPV; a book preference is eligible only
        // if it appears in that verified top set and is within the tiny safety
        // tolerance of the engine's best score.
        if !request.openingWeights.isEmpty {
            let verified = try await engine.analyzeCandidates(
                fen: request.fen,
                movesFromStart: request.movesFromStart,
                movetime: StrengthProfile.openingBookVerifyTime,
                count: StrengthProfile.openingBookCandidates
            )
            guard activeRevision == request.revision else { return }
            if let choice = verifiedOpeningChoice(
                candidates: verified,
                weights: request.openingWeights
            ) {
                incumbent = choice.move
                publish(choice.move, phase: .quick, source: choice.fromBook ? .openingBook : .engine,
                        request: request, onUpdate: onUpdate)
            }
        }

        var continuation: AsyncStream<EngineSearchUpdate>.Continuation!
        let stream = AsyncStream<EngineSearchUpdate> { continuation = $0 }
        let consumer = Task { @MainActor [weak self] in
            guard let self else { return }
            for await update in stream {
                guard self.activeRevision == request.revision else { return }
                switch update.phase {
                case .quick:
                    let selected = self.stableChoice(
                        previous: incumbent,
                        incoming: update.move,
                        positionKey: request.positionKey
                    )
                    incumbent = selected
                    self.publish(selected, phase: .quick, source: .engine,
                                 request: request, onUpdate: onUpdate)
                case .deepening:
                    let shown = incumbent ?? update.move
                    self.publish(shown, phase: .deepening, source: .engine,
                                 request: request, onUpdate: onUpdate)
                case .final:
                    // Final selection is handled below after a same-search
                    // head-to-head comparison with the displayed incumbent.
                    break
                }
            }
        }

        let challenger: EngineMove
        do {
            challenger = try await engine.analyzeAdaptive(
                fen: request.fen,
                movesFromStart: request.movesFromStart,
                quickTime: StrengthProfile.quickAnswerTime,
                normalTime: StrengthProfile.normalDeepTime,
                complexTime: StrengthProfile.complexDeepTime
            ) { update in
                continuation.yield(update)
            }
            continuation.finish()
            await consumer.value
        } catch {
            continuation.finish()
            consumer.cancel()
            throw error
        }
        guard activeRevision == request.revision else { return }

        var finalMove = challenger
        if let incumbent, incumbent.uci != challenger.uci {
            finalMove = try await compareSamePosition(
                incumbent: incumbent,
                challenger: challenger,
                request: request
            )
            guard activeRevision == request.revision else { return }
        }
        finalMove = try await recoverFromRepetitionIfNeeded(finalMove, request: request)
        guard activeRevision == request.revision else { return }
        publish(finalMove, phase: .final, source: .engine,
                request: request, onUpdate: onUpdate)
    }

    private func compareSamePosition(
        incumbent: EngineMove,
        challenger: EngineMove,
        request: BrainSearchRequest
    ) async throws -> EngineMove {
        let compared = try await engine.analyzeCandidates(
            fen: request.fen,
            movesFromStart: request.movesFromStart,
            movetime: StrengthProfile.stableComparisonTime,
            count: 2,
            searchMoves: [incumbent.uci, challenger.uci]
        )
        guard let first = compared.first else { return challenger }
        if first.uci == incumbent.uci { return first }

        guard let old = compared.first(where: { $0.uci == incumbent.uci }),
              let fresh = compared.first(where: { $0.uci == challenger.uci })
        else { return first }
        return stableChoice(previous: old, incoming: fresh,
                            positionKey: request.positionKey)
    }

    private func recoverFromRepetitionIfNeeded(
        _ move: EngineMove,
        request: BrainSearchRequest
    ) async throws -> EngineMove {
        guard request.repetitionForbiddenMoves.contains(move.uci),
              !request.repetitionAllowedMoves.isEmpty
        else { return move }
        return try await engine.analyze(
            fen: request.fen,
            movesFromStart: request.movesFromStart,
            movetime: StrengthProfile.repetitionRecoveryMoveTime,
            searchMoves: request.repetitionAllowedMoves
        )
    }

    private func stableChoice(
        previous: EngineMove?,
        incoming: EngineMove,
        positionKey: String
    ) -> EngineMove {
        guard let previous else { return incoming }
        let old = AdaptiveSearchPolicy.Recommendation(
            positionKey: positionKey,
            move: previous.uci,
            scoreCentipawns: previous.score,
            mateDistance: previous.mateIn
        )
        let fresh = AdaptiveSearchPolicy.Recommendation(
            positionKey: positionKey,
            move: incoming.uci,
            scoreCentipawns: incoming.score,
            mateDistance: incoming.mateIn
        )
        let selected = AdaptiveSearchPolicy.stabilizedRecommendation(
            previous: old,
            incoming: fresh,
            equalScoreToleranceCentipawns: StrengthProfile.stableScoreTolerance
        )
        return selected.move == incoming.uci ? incoming : previous
    }

    private func verifiedOpeningChoice(
        candidates: [EngineMove],
        weights: [String: Int]
    ) -> (move: EngineMove, fromBook: Bool)? {
        guard let best = candidates.first else { return nil }
        if best.mateIn != nil { return (best, weights[best.uci] != nil) }

        let eligible = candidates.filter { candidate in
            candidate.mateIn == nil &&
                weights[candidate.uci] != nil &&
                best.score - candidate.score <= StrengthProfile.openingBookTieTolerance
        }
        guard let bookMove = eligible.max(by: { lhs, rhs in
            let leftWeight = weights[lhs.uci] ?? 0
            let rightWeight = weights[rhs.uci] ?? 0
            if leftWeight == rightWeight { return lhs.score < rhs.score }
            return leftWeight < rightWeight
        }) else {
            return (best, false)
        }
        return (bookMove, true)
    }

    private func publish(
        _ move: EngineMove,
        phase: EngineSearchPhase,
        source: BrainSearchSource,
        request: BrainSearchRequest,
        onUpdate: (BrainSearchUpdate) -> Void
    ) {
        guard activeRevision == request.revision else { return }
        onUpdate(BrainSearchUpdate(
            revision: request.revision,
            positionKey: request.positionKey,
            phase: phase,
            source: source,
            move: move
        ))
    }
}

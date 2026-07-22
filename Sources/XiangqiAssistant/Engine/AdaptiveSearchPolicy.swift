import Foundation

/// Pure, side-effect-free policy helpers for the engine layer.
///
/// The app can feed snapshots from any engine search into this type without
/// coupling the policy to capture, recognition, UI, or the Pikafish process.
enum AdaptiveSearchPolicy {

    // MARK: - Adaptive search budget

    enum SearchStage: Int, CaseIterable, Equatable {
        /// Publish an initial answer quickly while the position is still current.
        case quickAnswer
        /// Deepen a normal position in the background.
        case regular
        /// Spend extra time resolving a tactical or unstable position.
        case complex

        /// Total search time target for this stage (not an incremental duration).
        var totalBudgetMilliseconds: Int {
            switch self {
            case .quickAnswer: return 2_000
            case .regular:     return 6_000
            case .complex:     return 15_000
            }
        }
    }

    enum PositionComplexity: Equatable {
        /// The principal variation has been quiet and stable long enough.
        case settled
        /// More evidence is useful, but the position is not tactically unstable.
        case normal
        /// A mate line, move churn, or evaluation swing needs deeper confirmation.
        case complex
    }

    /// Aggregated evidence from one search of one unchanged position.
    ///
    /// `mateDistance` follows UCI semantics from the side-to-move perspective:
    /// positive means that side can force mate, negative means that side is
    /// getting mated. `evaluationRangeCentipawns` is the high-low range observed
    /// during the search, rather than only the difference between the last two
    /// samples.
    struct SearchEvidence: Equatable {
        let elapsedMilliseconds: Int
        let mateDistance: Int?
        let bestMoveChangeCount: Int
        let evaluationRangeCentipawns: Int
        let stableForMilliseconds: Int

        init(
            elapsedMilliseconds: Int,
            mateDistance: Int? = nil,
            bestMoveChangeCount: Int = 0,
            evaluationRangeCentipawns: Int = 0,
            stableForMilliseconds: Int = 0
        ) {
            self.elapsedMilliseconds = max(0, elapsedMilliseconds)
            self.mateDistance = mateDistance
            self.bestMoveChangeCount = max(0, bestMoveChangeCount)
            self.evaluationRangeCentipawns = max(0, evaluationRangeCentipawns)
            self.stableForMilliseconds = max(0, stableForMilliseconds)
        }
    }

    /// Thresholds are explicit so fixed-position tests can tune or override them
    /// without changing policy code.
    struct ComplexityThresholds: Equatable {
        let complexBestMoveChanges: Int
        let complexEvaluationRangeCentipawns: Int
        let insufficientStabilityMilliseconds: Int
        let settledEvaluationRangeCentipawns: Int
        let settledStabilityMilliseconds: Int

        static let `default` = ComplexityThresholds(
            complexBestMoveChanges: 2,
            complexEvaluationRangeCentipawns: 35,
            insufficientStabilityMilliseconds: 1_000,
            settledEvaluationRangeCentipawns: 18,
            settledStabilityMilliseconds: 1_500
        )
    }

    /// Mutable accumulator used by the live UCI reader. It intentionally
    /// measures churn after the quick-answer milestone; early iterative-
    /// deepening noise should not make every quiet opening look tactical.
    struct Metrics {
        private var moveAtQuickMilestone: String?
        private var trackedMove: String?
        private var lastMoveChangeAt = SearchStage.quickAnswer.totalBudgetMilliseconds
        private var minimumScore: Int?
        private var maximumScore: Int?
        private(set) var bestMoveChangeCount = 0
        private(set) var mateDistance: Int?
        private(set) var elapsedMilliseconds = 0

        mutating func observe(move: EngineMove, elapsedMilliseconds: Int) {
            self.elapsedMilliseconds = max(self.elapsedMilliseconds, elapsedMilliseconds)
            if move.mateIn != nil { mateDistance = move.mateIn }

            guard elapsedMilliseconds >= SearchStage.quickAnswer.totalBudgetMilliseconds else {
                moveAtQuickMilestone = move.uci
                return
            }

            if trackedMove == nil {
                trackedMove = moveAtQuickMilestone ?? move.uci
                lastMoveChangeAt = SearchStage.quickAnswer.totalBudgetMilliseconds
            }
            if trackedMove != move.uci {
                trackedMove = move.uci
                bestMoveChangeCount += 1
                lastMoveChangeAt = elapsedMilliseconds
            }
            if move.mateIn == nil {
                minimumScore = min(minimumScore ?? move.score, move.score)
                maximumScore = max(maximumScore ?? move.score, move.score)
            }
        }

        var evidence: SearchEvidence {
            SearchEvidence(
                elapsedMilliseconds: elapsedMilliseconds,
                mateDistance: mateDistance,
                bestMoveChangeCount: bestMoveChangeCount,
                evaluationRangeCentipawns: (maximumScore ?? 0) - (minimumScore ?? 0),
                stableForMilliseconds: max(0, elapsedMilliseconds - lastMoveChangeAt)
            )
        }
    }

    static func shouldExtend(metrics: Metrics) -> Bool {
        complexity(for: metrics.evidence) == .complex
    }

    static func complexity(
        for evidence: SearchEvidence,
        thresholds: ComplexityThresholds = .default
    ) -> PositionComplexity {
        // A reported mate is deliberately treated as complex: the 15-second
        // stage confirms the line and improves the mate distance before display.
        if evidence.mateDistance != nil {
            return .complex
        }

        if evidence.bestMoveChangeCount >= thresholds.complexBestMoveChanges ||
            evidence.evaluationRangeCentipawns >= thresholds.complexEvaluationRangeCentipawns {
            return .complex
        }

        // Still changing near/after the regular deadline is tactical uncertainty,
        // even when the raw score range has not crossed the hard threshold.
        if evidence.elapsedMilliseconds >= SearchStage.regular.totalBudgetMilliseconds,
           evidence.stableForMilliseconds < thresholds.insufficientStabilityMilliseconds {
            return .complex
        }

        if evidence.bestMoveChangeCount == 0,
           evidence.evaluationRangeCentipawns <= thresholds.settledEvaluationRangeCentipawns,
           evidence.stableForMilliseconds >= thresholds.settledStabilityMilliseconds {
            return .settled
        }

        return .normal
    }

    /// The total target budget appropriate for the evidence available now.
    /// Every position starts with the 2-second quick-answer stage. Once that
    /// answer is available, normal/settled positions deepen to 6 seconds and
    /// complex positions deepen to 15 seconds.
    static func desiredStage(
        for evidence: SearchEvidence,
        thresholds: ComplexityThresholds = .default
    ) -> SearchStage {
        if evidence.elapsedMilliseconds < SearchStage.quickAnswer.totalBudgetMilliseconds {
            return .quickAnswer
        }

        return complexity(for: evidence, thresholds: thresholds) == .complex
            ? .complex
            : .regular
    }

    /// Returns the next background stage after a completed stage, or `nil` when
    /// no further deepening is warranted. The caller remains responsible for
    /// cancelling work as soon as its position identity changes.
    static func nextStage(
        after completedStage: SearchStage,
        evidence: SearchEvidence,
        thresholds: ComplexityThresholds = .default
    ) -> SearchStage? {
        switch completedStage {
        case .quickAnswer:
            return complexity(for: evidence, thresholds: thresholds) == .complex
                ? .complex
                : .regular
        case .regular:
            return complexity(for: evidence, thresholds: thresholds) == .complex
                ? .complex
                : nil
        case .complex:
            return nil
        }
    }

    // MARK: - Evaluation perspective

    /// Converts an engine centipawn score from side-to-move perspective into a
    /// red-positive score suitable for UI display and history charts.
    static func redPerspectiveScore(
        _ sideToMoveScore: Int,
        sideToMove: PieceSide
    ) -> Int {
        guard sideToMove == .black else { return sideToMoveScore }
        return safelyNegated(sideToMoveScore)
    }

    /// Converts a signed UCI mate distance from side-to-move perspective into
    /// red perspective. Positive means red mates; negative means black mates.
    static func redPerspectiveMateDistance(
        _ sideToMoveMateDistance: Int?,
        sideToMove: PieceSide
    ) -> Int? {
        guard let distance = sideToMoveMateDistance else { return nil }
        return sideToMove == .red ? distance : safelyNegated(distance)
    }

    // MARK: - Mate presentation

    struct MatePresentation: Equatable {
        let attacker: PieceSide
        /// UCI mate count. Zero represents an already finished mate position.
        let moveCount: Int
        let redPerspectiveDistance: Int

        /// Neutral wording that names the winning side explicitly.
        var chineseText: String {
            guard moveCount > 0 else {
                return attacker == .red ? "黑方已被将死" : "红方已被将死"
            }
            return "\(AdaptiveSearchPolicy.sideName(attacker))方预计 \(moveCount) 步杀"
        }

        /// Player-relative wording for compact UI labels.
        func chineseText(viewedBy viewer: PieceSide) -> String {
            guard moveCount > 0 else {
                return attacker == viewer ? "对方已被将死" : "已被将死"
            }
            return attacker == viewer
                ? "预计 \(moveCount) 步杀"
                : "需防 \(moveCount) 步杀"
        }
    }

    /// Builds presentation data from the engine's native side-to-move mate score.
    static func matePresentation(
        mateDistanceFromSideToMove distance: Int?,
        sideToMove: PieceSide
    ) -> MatePresentation? {
        guard let distance else { return nil }
        let redDistance = redPerspectiveMateDistance(distance, sideToMove: sideToMove) ?? 0
        let attacker: PieceSide
        if distance > 0 {
            attacker = sideToMove
        } else {
            attacker = sideToMove == .red ? .black : .red
        }
        return MatePresentation(
            attacker: attacker,
            moveCount: safeMagnitude(distance),
            redPerspectiveDistance: redDistance
        )
    }

    /// Convenience pure function for the common compact-label use case.
    static func mateChineseText(
        mateDistanceFromSideToMove distance: Int?,
        sideToMove: PieceSide,
        viewedBy viewer: PieceSide? = nil
    ) -> String? {
        guard let presentation = matePresentation(
            mateDistanceFromSideToMove: distance,
            sideToMove: sideToMove
        ) else { return nil }

        if let viewer {
            return presentation.chineseText(viewedBy: viewer)
        }
        return presentation.chineseText
    }

    // MARK: - Stable recommendation

    /// A recommendation snapshot for one exact position. `positionKey` should
    /// include the side to move (a full FEN is suitable). Score and mate distance
    /// must both use the side-to-move perspective for that position.
    struct Recommendation: Equatable {
        let positionKey: String
        let move: String
        let scoreCentipawns: Int
        let mateDistance: Int?

        init(
            positionKey: String,
            move: String,
            scoreCentipawns: Int,
            mateDistance: Int? = nil
        ) {
            self.positionKey = positionKey
            self.move = move
            self.scoreCentipawns = scoreCentipawns
            self.mateDistance = mateDistance
        }
    }

    /// Prevents visually noisy best-move flipping within the same position.
    ///
    /// Rules, in priority order:
    /// - Different positions never share a recommendation.
    /// - A forced win beats a non-mate score; a non-mate score beats a forced loss.
    /// - Among winning mates, the shorter mate wins.
    /// - Among losing mates, the longer delay wins.
    /// - Between non-mates within 8 cp, retain the previously displayed move.
    static func stabilizedRecommendation(
        previous: Recommendation?,
        incoming: Recommendation,
        equalScoreToleranceCentipawns: Int = 8
    ) -> Recommendation {
        guard let previous, previous.positionKey == incoming.positionKey else {
            return incoming
        }

        // The move is already stable; accept fresher score/depth-derived data.
        guard previous.move != incoming.move else { return incoming }

        switch (mateClass(previous.mateDistance), mateClass(incoming.mateDistance)) {
        case let (.winning(oldDistance), .winning(newDistance)):
            if newDistance < oldDistance { return incoming }
            return previous

        case let (.losing(oldDistance), .losing(newDistance)):
            if newDistance > oldDistance { return incoming }
            return previous

        case (.winning, _):
            return previous
        case (_, .winning):
            return incoming

        case (.losing, .notMate):
            return incoming
        case (.notMate, .losing):
            return previous

        case (.notMate, .notMate):
            let tolerance = max(0, equalScoreToleranceCentipawns)
            let difference = absoluteDifference(
                previous.scoreCentipawns,
                incoming.scoreCentipawns
            )
            return difference <= UInt(tolerance) ? previous : incoming
        }
    }

    // MARK: - Private helpers

    private enum MateClass {
        case winning(distance: UInt)
        case losing(distance: UInt)
        case notMate
    }

    private static func mateClass(_ distance: Int?) -> MateClass {
        guard let distance else { return .notMate }
        if distance > 0 { return .winning(distance: UInt(distance)) }
        return .losing(distance: UInt(safeMagnitude(distance)))
    }

    private static func sideName(_ side: PieceSide) -> String {
        side == .red ? "红" : "黑"
    }

    private static func safelyNegated(_ value: Int) -> Int {
        value == Int.min ? Int.max : -value
    }

    private static func safeMagnitude(_ value: Int) -> Int {
        value == Int.min ? Int.max : abs(value)
    }

    private static func absoluteDifference(_ lhs: Int, _ rhs: Int) -> UInt {
        if lhs >= rhs {
            let (difference, overflow) = lhs.subtractingReportingOverflow(rhs)
            return overflow ? UInt.max : difference.magnitude
        }
        let (difference, overflow) = rhs.subtractingReportingOverflow(lhs)
        return overflow ? UInt.max : difference.magnitude
    }
}

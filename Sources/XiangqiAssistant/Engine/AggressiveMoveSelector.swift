import Foundation

/// Chooses a forcing move from Pikafish's strongest candidates without
/// sacrificing soundness. The engine first limits the pool to moves close to
/// its best evaluation; this selector then favours prepared attacking openings,
/// checks, captures and active rook/cannon development.
enum AggressiveMoveSelector {
    private static let maximumEvaluationLoss = 20

    /// Short, sound attacking skeletons. A line is only used while the exact
    /// observed history remains its prefix, and only if Pikafish still places
    /// the prepared move inside its top candidate set.
    private static let openingLines: [[String]] = [
        // 中炮过河车 against 屏风马
        ["h2e2", "h9g7", "h0g2", "i9h9", "i0h0", "b9c7", "h0h6"],
        ["h2e2", "b9c7", "h0g2", "h9g7", "i0h0", "i9h9", "h0h6"],
        // 左炮中炮 with the opposite wing developed first
        ["b2e2", "b9c7", "b0c2", "a9b9", "a0b0", "h9g7", "b0b6"],
        // 顺炮/列炮 style active black replies
        ["h2e2", "h7e7", "h0g2", "h9g7", "i0h0", "i9h9"],
        ["b2e2", "b7e7", "b0c2", "b9c7", "a0b0", "a9b9"]
    ]

    static func select(
        from candidates: [EngineMove],
        board: BoardState,
        side: PieceSide,
        history: [String]?
    ) -> EngineMove? {
        guard let best = candidates.first else { return nil }

        // A style preference must never lengthen or throw away a forced win.
        // Preserve the typed mate distance instead of comparing its synthetic
        // centipawn representation.
        let forcedWins = candidates.filter { ($0.mateIn ?? 0) > 0 }
        if let shortestMate = forcedWins.min(by: {
            ($0.mateIn ?? .max) < ($1.mateIn ?? .max)
        }) {
            return shortestMate
        }

        // If the engine says the root side is being mated, stylistic bonuses
        // must not replace a longer defence with a quicker loss. MultiPV order
        // already ranks the best available resistance first.
        if best.mateIn != nil { return best }

        // MultiPV is ordered by engine preference. Keep only objectively close
        // alternatives; an attacking personality must never turn into blundering.
        let eligible = candidates.enumerated().filter { index, candidate in
            index == 0 || (candidate.mateIn == nil &&
                best.score - candidate.score <= maximumEvaluationLoss)
        }

        return eligible.max { lhs, rhs in
            styleScore(lhs.element, rank: lhs.offset, board: board,
                       side: side, history: history)
            < styleScore(rhs.element, rank: rhs.offset, board: board,
                         side: side, history: history)
        }?.element ?? best
    }

    private static func styleScore(
        _ candidate: EngineMove,
        rank: Int,
        board: BoardState,
        side: PieceSide,
        history: [String]?
    ) -> Int {
        guard let move = UCIMove(uci: candidate.uci),
              let movingPiece = board[move.from]
        else { return -10_000 }

        var score = -rank * 16
        score += history.map { openingBonus(move.uci, history: $0) } ?? 0

        if board.givesCheck(after: move, by: side) { score += 125 }
        if let captured = board[move.to] {
            score += pieceValue(captured.kind) / 8
        }

        let forward = side == .red ? move.from.row - move.to.row : move.to.row - move.from.row
        switch movingPiece.kind {
        case .rook:
            score += max(0, forward) * 9
            if crossedRiver(move.to, side: side) { score += 34 }
        case .cannon:
            score += max(0, forward) * 7
            if move.to.col == 4 { score += 28 }
        case .knight:
            score += max(0, forward) * 8
            score += max(0, 4 - abs(4 - move.to.col)) * 4
        case .pawn:
            score += max(0, forward) * 6
        default:
            break
        }
        return score
    }

    private static func openingBonus(_ move: String, history: [String]) -> Int {
        guard history.count < 16 else { return 0 }
        var bonus = 0
        for line in openingLines where history.count < line.count {
            if Array(line.prefix(history.count)) == history,
               line[history.count] == move {
                bonus = max(bonus, 190)
            }
        }

        // Keep useful attacking motifs available when the opponent leaves the
        // exact book line, but let Pikafish's ranking remain decisive.
        if history.count <= 2, ["h2e2", "b2e2", "h7e7", "b7e7"].contains(move) {
            bonus = max(bonus, 95)
        }
        return bonus
    }

    private static func crossedRiver(_ position: BoardPosition, side: PieceSide) -> Bool {
        side == .red ? position.row <= 4 : position.row >= 5
    }

    private static func pieceValue(_ kind: PieceKind) -> Int {
        switch kind {
        case .king: return 10_000
        case .rook: return 900
        case .cannon: return 450
        case .knight: return 420
        case .bishop, .advisor: return 220
        case .pawn: return 100
        }
    }
}

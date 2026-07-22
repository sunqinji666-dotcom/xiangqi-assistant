import Foundation

// MARK: - Piece Types

enum PieceSide: Hashable { case red, black }

enum PieceKind: String, CaseIterable, Hashable {
    case king   = "K"  // 将/帅
    case advisor = "A" // 士/仕
    case bishop = "B"  // 象/相
    case knight = "N"  // 马
    case rook   = "R"  // 车
    case cannon  = "C" // 炮
    case pawn   = "P"  // 卒/兵

    /// Human-readable Chinese name
    func displayName(side: PieceSide) -> String {
        switch (self, side) {
        case (.king,    .red):   return "帅"
        case (.king,    .black): return "将"
        case (.advisor, .red):   return "仕"
        case (.advisor, .black): return "士"
        case (.bishop,  .red):   return "相"
        case (.bishop,  .black): return "象"
        case (.knight,  _):      return "马"
        case (.rook,    _):      return "车"
        case (.cannon,  _):      return "炮"
        case (.pawn,    .red):   return "兵"
        case (.pawn,    .black): return "卒"
        }
    }
}

struct Piece: Hashable {
    let kind: PieceKind
    let side: PieceSide
}

// MARK: - Board Position

/// Column 0-8 (left to right), Row 0-9 (black side top = 0, red side bottom = 9)
struct BoardPosition: Hashable {
    let col: Int // 0-8
    let row: Int // 0-9

    var isValid: Bool { (0...8).contains(col) && (0...9).contains(row) }
}

// MARK: - Board State

/// Full 9×10 board state
struct BoardState: Equatable {
    // 10 rows × 9 cols, nil = empty
    var grid: [[Piece?]] = Array(repeating: Array(repeating: nil, count: 9), count: 10)
    var redToMove: Bool = true

    subscript(col: Int, row: Int) -> Piece? {
        get { grid[row][col] }
        set { grid[row][col] = newValue }
    }

    subscript(pos: BoardPosition) -> Piece? {
        get { grid[pos.row][pos.col] }
        set { grid[pos.row][pos.col] = newValue }
    }

    // MARK: FEN Encoding

    /// Convert board state to WXF/ICCS FEN string for Pikafish.
    /// Format: <board>/<board>/... <w|b> - - 0 1
    func toFEN() -> String {
        var rows: [String] = []
        for row in 0..<10 {
            var rowStr = ""
            var emptyCount = 0
            for col in 0..<9 {
                if let piece = grid[row][col] {
                    if emptyCount > 0 {
                        rowStr += "\(emptyCount)"
                        emptyCount = 0
                    }
                    let letter = piece.kind.rawValue
                    rowStr += piece.side == .red ? letter : letter.lowercased()
                } else {
                    emptyCount += 1
                }
            }
            if emptyCount > 0 { rowStr += "\(emptyCount)" }
            rows.append(rowStr)
        }
        let boardStr = rows.joined(separator: "/")
        let sideChar = redToMove ? "w" : "b"
        return "\(boardStr) \(sideChar) - - 0 1"
    }

    // MARK: Initial Setup

    static func initialPosition() -> BoardState {
        var state = BoardState()
        // Black pieces (top, rows 0-4)
        let backRank: [(Int, PieceKind)] = [
            (0, .rook), (1, .knight), (2, .bishop), (3, .advisor),
            (4, .king),
            (5, .advisor), (6, .bishop), (7, .knight), (8, .rook)
        ]
        for (col, kind) in backRank {
            state[col, 0] = Piece(kind: kind, side: .black)
        }
        state[1, 2] = Piece(kind: .cannon, side: .black)
        state[7, 2] = Piece(kind: .cannon, side: .black)
        for col in [0, 2, 4, 6, 8] {
            state[col, 3] = Piece(kind: .pawn, side: .black)
        }

        // Red pieces (bottom, rows 6-9)
        for (col, kind) in backRank {
            state[col, 9] = Piece(kind: kind, side: .red)
        }
        state[1, 7] = Piece(kind: .cannon, side: .red)
        state[7, 7] = Piece(kind: .cannon, side: .red)
        for col in [0, 2, 4, 6, 8] {
            state[col, 6] = Piece(kind: .pawn, side: .red)
        }
        return state
    }

    // MARK: Helpers

    var pieceCount: Int {
        grid.flatMap { $0 }.compactMap { $0 }.count
    }

    /// Compares only the pieces on the board. The side to move is session
    /// state, so it must not make two identical screenshots look different.
    func sameLayout(as other: BoardState) -> Bool {
        grid == other.grid
    }

    // MARK: Validation

    /// Full validity check:
    /// - each side has exactly one king
    /// - piece counts don't exceed legal maximums
    /// - 帅 is in red palace (rows 7-9, cols 3-5); 将 is in black palace (rows 0-2, cols 3-5)
    var isValid: Bool {
        var redKings = 0, blackKings = 0
        var counts: [PieceSide: [PieceKind: Int]] = [:]

        for row in 0..<10 {
            for col in 0..<9 {
                guard let p = grid[row][col] else { continue }
                counts[p.side, default: [:]][p.kind, default: 0] += 1
                if p.kind == .king {
                    if p.side == .red {
                        redKings += 1
                        // 帅 must stay in red palace: rows 7-9, cols 3-5
                        if !(7...9).contains(row) || !(3...5).contains(col) { return false }
                    } else {
                        blackKings += 1
                        // 将 must stay in black palace: rows 0-2, cols 3-5
                        if !(0...2).contains(row) || !(3...5).contains(col) { return false }
                    }
                }
            }
        }
        guard redKings == 1 && blackKings == 1 else { return false }

        let limits: [PieceKind: Int] = [
            .king: 1, .advisor: 2, .bishop: 2, .knight: 2,
            .rook: 2, .cannon: 2, .pawn: 5
        ]
        for side in [PieceSide.red, .black] {
            for (kind, limit) in limits where (counts[side]?[kind] ?? 0) > limit {
                return false
            }
        }
        return true
    }

    // MARK: Frame-to-Frame Validation

    /// Extracts the single piece movement that changes this layout into `next`.
    /// This validates the shape of a move transition, independently of whose turn it is.
    func inferredMove(to next: BoardState) -> UCIMove? {
        var removed: [(position: BoardPosition, piece: Piece)] = []
        var added: [(position: BoardPosition, piece: Piece)] = []

        for row in 0..<10 {
            for col in 0..<9 {
                let position = BoardPosition(col: col, row: row)
                let before = self[position]
                let after = next[position]
                guard before != after else { continue }
                if let before { removed.append((position, before)) }
                if let after { added.append((position, after)) }
            }
        }

        guard added.count == 1 else { return nil }
        let arrival = added[0]
        let matchingDepartures = removed.filter {
            $0.piece == arrival.piece && $0.position != arrival.position
        }
        guard matchingDepartures.count == 1 else { return nil }

        let departure = matchingDepartures[0]
        guard self[departure.position] == arrival.piece,
              next[departure.position] == nil,
              next[arrival.position] == arrival.piece
        else { return nil }

        if let captured = self[arrival.position] {
            guard captured.side != arrival.piece.side,
                  removed.count == 2,
                  removed.contains(where: { $0.position == arrival.position && $0.piece == captured })
            else { return nil }
        } else if removed.count != 1 {
            return nil
        }

        return UCIMove(from: departure.position, to: arrival.position)
    }

    /// Returns true if `next` can be reached from `self` by one well-formed move.
    /// Use `isLegalTransition` when the moving side is known.
    func isPlausibleSingleMove(to next: BoardState) -> Bool {
        inferredMove(to: next) != nil
    }

    /// Structural transition check used for screen recognition. The model has
    /// already produced a valid full board; here we only require one piece of
    /// the expected side to move from one intersection to another. This avoids
    /// rejecting a visually unambiguous move because the deeper check/checkmate
    /// validator is stricter than the source game's rule implementation.
    func isPlausibleSingleMove(to next: BoardState, movingSide: PieceSide) -> Bool {
        guard let move = inferredMove(to: next), let piece = self[move.from] else { return false }
        return piece.side == movingSide
    }

    /// Returns true if `next` is reached with one fully legal Chinese-chess move.
    func isLegalTransition(to next: BoardState, movingSide: PieceSide) -> Bool {
        guard let move = inferredMove(to: next) else { return false }
        return isLegalMove(move, for: movingSide)
    }

    /// Returns true when `next` is exactly two alternating legal moves away.
    /// This is needed for fast computer opponents: the capture loop can miss
    /// the short frame between the user's move and the automatic reply.
    func isLegalTwoPlyTransition(to next: BoardState, firstSide: PieceSide) -> Bool {
        let secondSide: PieceSide = firstSide == .red ? .black : .red

        for fromRow in 0..<10 {
            for fromCol in 0..<9 {
                let from = BoardPosition(col: fromCol, row: fromRow)
                guard self[from]?.side == firstSide else { continue }

                for toRow in 0..<10 {
                    for toCol in 0..<9 {
                        let to = BoardPosition(col: toCol, row: toRow)
                        let firstMove = UCIMove(from: from, to: to)
                        guard isLegalMove(firstMove, for: firstSide) else { continue }

                        var intermediate = self
                        intermediate[to] = intermediate[from]
                        intermediate[from] = nil
                        if intermediate.isLegalTransition(to: next, movingSide: secondSide) {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    /// Returns the exact observed one- or two-ply sequence.  Unlike a boolean
    /// transition check, this lets the engine receive the full game history so
    /// it can enforce repetition and long-check/long-chase rules.
    func transitionMoves(to next: BoardState, firstSide: PieceSide) -> [UCIMove]? {
        if let move = inferredMove(to: next),
           self[move.from]?.side == firstSide,
           isPseudoLegalMove(move, for: firstSide) {
            return [move]
        }

        let secondSide: PieceSide = firstSide == .red ? .black : .red
        for firstMove in pseudoLegalMoves(for: firstSide) {
            let intermediate = applying(firstMove)
            guard let secondMove = intermediate.inferredMove(to: next),
                  intermediate[secondMove.from]?.side == secondSide,
                  intermediate.isPseudoLegalMove(secondMove, for: secondSide)
            else { continue }
            return [firstMove, secondMove]
        }
        return nil
    }

    func legalMoves(for side: PieceSide) -> [UCIMove] {
        var moves: [UCIMove] = []
        for fromRow in 0..<10 {
            for fromCol in 0..<9 {
                let from = BoardPosition(col: fromCol, row: fromRow)
                guard self[from]?.side == side else { continue }
                for toRow in 0..<10 {
                    for toCol in 0..<9 {
                        let move = UCIMove(
                            from: from,
                            to: BoardPosition(col: toCol, row: toRow)
                        )
                        if isLegalMove(move, for: side) { moves.append(move) }
                    }
                }
            }
        }
        return moves
    }

    func applying(_ move: UCIMove) -> BoardState {
        var next = self
        next[move.to] = next[move.from]
        next[move.from] = nil
        return next
    }

    /// Used by the attack-style recommender to prefer forcing continuations.
    /// The move must already have been validated by the engine/board rules.
    func givesCheck(after move: UCIMove, by side: PieceSide) -> Bool {
        let opponent: PieceSide = side == .red ? .black : .red
        return applying(move).isKingInCheck(side: opponent)
    }

    /// Finds the legal one- or two-ply position closest to a noisy full-board
    /// classifier observation.  This is deliberately based on the last trusted
    /// position: a blue move marker may confuse one piece, but it must not be
    /// allowed to rewrite unrelated pieces elsewhere on the board.
    func bestMatchingTransition(
        to observed: BoardState,
        firstSide: PieceSide,
        maxMismatches: Int = 5
    ) -> (state: BoardState, plies: Int, mismatches: Int)? {
        let baseline = layoutMismatchCount(with: observed)
        var best: (state: BoardState, plies: Int, mismatches: Int)?
        var secondBest = Int.max

        func consider(_ candidate: BoardState, plies: Int) {
            let mismatch = candidate.layoutMismatchCount(with: observed)
            if let current = best {
                if candidate.sameLayout(as: current.state) { return }
                if mismatch < current.mismatches {
                    secondBest = current.mismatches
                    best = (candidate, plies, mismatch)
                } else {
                    secondBest = min(secondBest, mismatch)
                }
            } else {
                best = (candidate, plies, mismatch)
            }
        }

        let firstPositions = pseudoLegalSuccessors(for: firstSide)
        for first in firstPositions {
            consider(first, plies: 1)
        }

        let secondSide: PieceSide = firstSide == .red ? .black : .red
        for first in firstPositions {
            for second in first.pseudoLegalSuccessors(for: secondSide) {
                consider(second, plies: 2)
            }
        }

        guard let winner = best,
              winner.mismatches <= maxMismatches,
              winner.mismatches < baseline,
              secondBest > winner.mismatches
        else { return nil }
        return winner
    }

    func layoutMismatchCount(with other: BoardState) -> Int {
        var count = 0
        for row in 0..<10 {
            for col in 0..<9 where self[col, row] != other[col, row] {
                count += 1
            }
        }
        return count
    }

    private func pseudoLegalSuccessors(for side: PieceSide) -> [BoardState] {
        pseudoLegalMoves(for: side).map(applying)
    }

    private func pseudoLegalMoves(for side: PieceSide) -> [UCIMove] {
        var results: [UCIMove] = []
        for fromRow in 0..<10 {
            for fromCol in 0..<9 {
                let from = BoardPosition(col: fromCol, row: fromRow)
                guard self[from]?.side == side else { continue }
                for toRow in 0..<10 {
                    for toCol in 0..<9 {
                        let to = BoardPosition(col: toCol, row: toRow)
                        let move = UCIMove(from: from, to: to)
                        guard isPseudoLegalMove(move, for: side) else { continue }
                        results.append(move)
                    }
                }
            }
        }
        return results
    }

    private func isPseudoLegalMove(_ move: UCIMove, for side: PieceSide) -> Bool {
        guard move.from.isValid,
              move.to.isValid,
              move.from != move.to,
              let movingPiece = self[move.from],
              movingPiece.side == side,
              self[move.to]?.side != side
        else { return false }
        return canPieceMove(movingPiece, from: move.from, to: move.to)
    }

    /// Validates a move against Chinese-chess movement, blocking, palace, river,
    /// horse-leg, cannon-screen, and self-check rules.
    func isLegalMove(_ move: UCIMove, for side: PieceSide) -> Bool {
        guard move.from.isValid,
              move.to.isValid,
              move.from != move.to,
              let movingPiece = self[move.from],
              movingPiece.side == side,
              self[move.to]?.side != side,
              canPieceMove(movingPiece, from: move.from, to: move.to)
        else { return false }

        var after = self
        after[move.to] = movingPiece
        after[move.from] = nil
        return !after.isKingInCheck(side: side)
    }

    private func canPieceMove(_ piece: Piece, from: BoardPosition, to: BoardPosition) -> Bool {
        let colDelta = to.col - from.col
        let rowDelta = to.row - from.row
        let absCol = abs(colDelta)
        let absRow = abs(rowDelta)

        switch piece.kind {
        case .king:
            if absCol + absRow == 1 {
                return isInsidePalace(to, for: piece.side)
            }
            // Flying generals may capture one another on an unobstructed file.
            return from.col == to.col &&
                self[to]?.kind == .king &&
                self[to]?.side != piece.side &&
                clearPath(from: from, to: to)

        case .advisor:
            return absCol == 1 && absRow == 1 && isInsidePalace(to, for: piece.side)

        case .bishop:
            guard absCol == 2, absRow == 2,
                  staysOnOwnSide(to, for: piece.side)
            else { return false }
            let eye = BoardPosition(col: from.col + colDelta / 2, row: from.row + rowDelta / 2)
            return self[eye] == nil

        case .knight:
            guard (absCol == 1 && absRow == 2) || (absCol == 2 && absRow == 1) else { return false }
            let leg: BoardPosition
            if absRow == 2 {
                leg = BoardPosition(col: from.col, row: from.row + rowDelta / 2)
            } else {
                leg = BoardPosition(col: from.col + colDelta / 2, row: from.row)
            }
            return self[leg] == nil

        case .rook:
            return (from.col == to.col || from.row == to.row) && clearPath(from: from, to: to)

        case .cannon:
            guard from.col == to.col || from.row == to.row else { return false }
            let blockers = blockingPieceCount(from: from, to: to)
            return self[to] == nil ? blockers == 0 : blockers == 1

        case .pawn:
            let forward = piece.side == .red ? -1 : 1
            if rowDelta == forward && colDelta == 0 { return true }
            return hasCrossedRiver(from, for: piece.side) && rowDelta == 0 && absCol == 1
        }
    }

    private func isKingInCheck(side: PieceSide) -> Bool {
        guard let kingPosition = kingPosition(for: side) else { return true }
        let opponent: PieceSide = side == .red ? .black : .red
        for row in 0..<10 {
            for col in 0..<9 {
                let position = BoardPosition(col: col, row: row)
                guard let piece = self[position], piece.side == opponent else { continue }
                if canPieceMove(piece, from: position, to: kingPosition) { return true }
            }
        }
        return false
    }

    private func kingPosition(for side: PieceSide) -> BoardPosition? {
        for row in 0..<10 {
            for col in 0..<9 where self[col, row] == Piece(kind: .king, side: side) {
                return BoardPosition(col: col, row: row)
            }
        }
        return nil
    }

    private func isInsidePalace(_ position: BoardPosition, for side: PieceSide) -> Bool {
        guard (3...5).contains(position.col) else { return false }
        return side == .red ? (7...9).contains(position.row) : (0...2).contains(position.row)
    }

    private func staysOnOwnSide(_ position: BoardPosition, for side: PieceSide) -> Bool {
        side == .red ? position.row >= 5 : position.row <= 4
    }

    private func hasCrossedRiver(_ position: BoardPosition, for side: PieceSide) -> Bool {
        side == .red ? position.row <= 4 : position.row >= 5
    }

    private func clearPath(from: BoardPosition, to: BoardPosition) -> Bool {
        blockingPieceCount(from: from, to: to) == 0
    }

    private func blockingPieceCount(from: BoardPosition, to: BoardPosition) -> Int {
        let colStep = (to.col - from.col).signum()
        let rowStep = (to.row - from.row).signum()
        var col = from.col + colStep
        var row = from.row + rowStep
        var count = 0
        while col != to.col || row != to.row {
            if self[col, row] != nil { count += 1 }
            col += colStep
            row += rowStep
        }
        return count
    }

    // MARK: Turn Inference

    /// Given the previous board state, infer whose turn it is NOW (after this state was reached).
    /// Returns nil if the transition is ambiguous or invalid.
    func inferredSideToMove(from previous: BoardState) -> PieceSide? {
        guard let move = previous.inferredMove(to: self),
              let movedPiece = previous[move.from]
        else { return nil }
        // The side that just moved is done; opponent moves next
        return movedPiece.side == .red ? .black : .red
    }
}

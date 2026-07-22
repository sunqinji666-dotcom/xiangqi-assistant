import Foundation

// MARK: - UCI → Standard Chinese Chess Notation
// Implements GB/T 14085 standard notation rules.
// E.g.  "h2e2"  →  "炮二平五"   (the lower Red cannon moves sideways)
//       "h0g2"  →  "马二进三"   (the lower Red horse advances)

enum ChineseNotation {

    // MARK: Public Entry

    static func convert(uci: String, state: BoardState) -> String {
        guard let move = UCIMove(uci: uci),
              let piece = state[move.from]
        else { return uci }

        let fromCol = move.from.col
        let fromRow = move.from.row
        let toCol = move.to.col
        let toRow = move.to.row

        let isRed = (piece.side == .red)

        // Column numbers from each side's perspective (1 = rightmost from their view)
        let fromColCN = isRed ? (9 - fromCol) : (fromCol + 1)
        let toColCN   = isRed ? (9 - toCol)   : (toCol + 1)

        // Disambiguation prefix for same-column same-type pieces
        let prefix = disambiguationPrefix(piece: piece, col: fromCol, row: fromRow,
                                          state: state, isRed: isRed)

        let pieceLabel = piece.kind.displayName(side: piece.side)
        let subject = prefix ?? "\(pieceLabel)\(cnDigit(fromColCN))"

        // Direction and destination
        let (direction, dest) = moveDescription(
            piece: piece, isRed: isRed,
            fromRow: fromRow, toRow: toRow,
            toColCN: toColCN
        )

        return "\(subject)\(direction)\(dest)"
    }

    // MARK: Move Description

    private static func moveDescription(
        piece: Piece, isRed: Bool,
        fromRow: Int, toRow: Int, toColCN: Int
    ) -> (direction: String, dest: String) {

        if fromRow == toRow {
            // Horizontal (sideways) move
            return ("平", cnDigit(toColCN))
        }

        // Vertical or diagonal move
        // For red: advancing = decreasing row (moving toward row 0 = black's side)
        // For black: advancing = increasing row (moving toward row 9 = red's side)
        let advancing = isRed ? (toRow < fromRow) : (toRow > fromRow)
        let direction = advancing ? "进" : "退"

        switch piece.kind {
        case .knight, .bishop, .advisor:
            // These pieces always state destination column, not distance
            return (direction, cnDigit(toColCN))
        default:
            // Rook, cannon, king, pawn → state number of rows moved
            return (direction, cnDigit(abs(toRow - fromRow)))
        }
    }

    // MARK: Same-Column Disambiguation

    /// Returns "前X", "后X", or "中X" prefix when multiple same-type pieces share a column.
    private static func disambiguationPrefix(
        piece: Piece, col: Int, row: Int,
        state: BoardState, isRed: Bool
    ) -> String? {

        // Collect all pieces of same type+side in this column
        var rows: [Int] = []
        for r in 0..<10 {
            if let p = state[col, r], p == piece { rows.append(r) }
        }
        guard rows.count >= 2 else { return nil }

        // Sort rows ascending (row 0 = top = black's side)
        rows.sort()

        let pieceName = piece.kind.displayName(side: piece.side)

        if rows.count == 2 {
            if isRed {
                // Red "前" = smaller row (closer to opponent = black's side)
                return row == rows[0] ? "前\(pieceName)" : "后\(pieceName)"
            } else {
                // Black "前" = larger row (closer to opponent = red's side)
                return row == rows[1] ? "前\(pieceName)" : "后\(pieceName)"
            }
        }

        if rows.count == 3 {
            // Three in a column (common with pawns)
            if isRed {
                if row == rows[0] { return "前\(pieceName)" }
                if row == rows[2] { return "后\(pieceName)" }
                return "中\(pieceName)"
            } else {
                if row == rows[2] { return "前\(pieceName)" }
                if row == rows[0] { return "后\(pieceName)" }
                return "中\(pieceName)"
            }
        }

        // 4 or 5 pawns in a column (extremely rare, fallback)
        return nil
    }

    /// Maps 1-9 to Chinese characters 一…九
    static func cnDigit(_ n: Int) -> String {
        let chars = ["一","二","三","四","五","六","七","八","九"]
        guard n >= 1 && n <= 9 else { return "\(n)" }
        return chars[n - 1]
    }
}

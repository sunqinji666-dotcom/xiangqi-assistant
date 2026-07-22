import Foundation

/// A Xiangqi move in UCCI/UCI coordinate notation (for example `h2e2`).
///
/// UCI rank 0 is Red's home rank, while BoardState row 0 is Black's home
/// rank.  Keeping the conversion here prevents UI, notation and auto-click
/// code from each accidentally interpreting a move upside-down.
struct UCIMove: Equatable {
    let from: BoardPosition
    let to: BoardPosition

    init(from: BoardPosition, to: BoardPosition) {
        self.from = from
        self.to = to
    }

    init?(uci: String) {
        let text = uci.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let chars = Array(text)
        guard chars.count >= 4,
              let fromCol = Self.column(chars[0]),
              let fromRow = Self.row(chars[1]),
              let toCol = Self.column(chars[2]),
              let toRow = Self.row(chars[3])
        else { return nil }

        from = BoardPosition(col: fromCol, row: 9 - fromRow)
        to = BoardPosition(col: toCol, row: 9 - toRow)
    }

    var uci: String {
        let files = Array("abcdefghi")
        guard from.isValid, to.isValid else { return "" }
        return "\(files[from.col])\(9 - from.row)\(files[to.col])\(9 - to.row)"
    }

    private static func column(_ character: Character) -> Int? {
        guard let scalar = character.unicodeScalars.first,
              scalar.value >= 97, scalar.value <= 105
        else { return nil }
        return Int(scalar.value - 97)
    }

    private static func row(_ character: Character) -> Int? {
        guard let value = character.wholeNumberValue, (0...9).contains(value) else {
            return nil
        }
        return value
    }
}

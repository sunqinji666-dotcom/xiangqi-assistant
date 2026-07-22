import SwiftUI

/// A small, human-readable board that mirrors the last recognized position.
/// The recommended move is highlighted so the user can follow it without
/// having to decode Chinese notation or UCI coordinates.
struct BoardPreviewView: View {
    @ObservedObject var vm: AssistantViewModel

    private let boardWidth: CGFloat = 270
    private let boardHeight: CGFloat = 300

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "checkerboard.rectangle")
                    .foregroundStyle(.orange)
                Text("局面预览")
                    .font(.caption.weight(.semibold))
                Spacer()
                if vm.lastAnalyzedBoard != nil {
                    Text("已识别")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                if let side = vm.recommendedSide {
                    Text(side == .red ? "红方走" : "黑方走")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(side == .red ? .red : .primary)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(red: 0.72, green: 0.48, blue: 0.25).opacity(0.95))

                if let capture = vm.diagnosticCapture, vm.lastAnalyzedBoard == nil {
                    Image(nsImage: capture)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else {
                    boardDrawing
                        .padding(12)
                }
            }
            .frame(width: boardWidth, height: boardHeight)
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.18), lineWidth: 1))

            Text("绿色箭头＝推荐走法")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: boardWidth + 24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    private var boardDrawing: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let dx = w / 8
            let dy = h / 9
            let state = vm.lastAnalyzedBoard
            let move = UCIMove(uci: vm.bestMove)
            let reversed = vm.previewIsReversed

            ZStack {
                // River band
                Rectangle()
                    .fill(Color.black.opacity(0.07))
                    .frame(width: w, height: dy)
                    .position(x: w / 2, y: dy * 4.5)

                Path { path in
                    for col in 0...8 {
                        path.move(to: CGPoint(x: CGFloat(col) * dx, y: 0))
                        path.addLine(to: CGPoint(x: CGFloat(col) * dx, y: h))
                    }
                    for row in 0...9 {
                        path.move(to: CGPoint(x: 0, y: CGFloat(row) * dy))
                        path.addLine(to: CGPoint(x: w, y: CGFloat(row) * dy))
                    }
                }
                .stroke(Color.black.opacity(0.55), lineWidth: 1)

                if let move {
                    moveArrow(from: point(for: move.from, dx: dx, dy: dy,
                                          reversed: reversed),
                              to: point(for: move.to, dx: dx, dy: dy,
                                        reversed: reversed))
                        .stroke(.green, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    Circle()
                        .stroke(.green, lineWidth: 3)
                        .frame(width: max(24, dx - 2), height: max(24, dy - 2))
                        .position(point(for: move.from, dx: dx, dy: dy,
                                        reversed: reversed))
                    Circle()
                        .fill(.green)
                        .frame(width: 9, height: 9)
                        .position(point(for: move.to, dx: dx, dy: dy,
                                        reversed: reversed))
                }

                // Palace diagonals
                Path { path in
                    path.move(to: CGPoint(x: 3 * dx, y: 0))
                    path.addLine(to: CGPoint(x: 5 * dx, y: 2 * dy))
                    path.move(to: CGPoint(x: 5 * dx, y: 0))
                    path.addLine(to: CGPoint(x: 3 * dx, y: 2 * dy))
                    path.move(to: CGPoint(x: 3 * dx, y: 7 * dy))
                    path.addLine(to: CGPoint(x: 5 * dx, y: 9 * dy))
                    path.move(to: CGPoint(x: 5 * dx, y: 7 * dy))
                    path.addLine(to: CGPoint(x: 3 * dx, y: 9 * dy))
                }
                .stroke(Color.black.opacity(0.55), lineWidth: 1)

                if let state {
                    ForEach(0..<10, id: \.self) { row in
                        ForEach(0..<9, id: \.self) { col in
                            if let piece = state[col, row] {
                                let isHighlighted = isHighlighted(col: col, row: row, move: move)
                                let pieceName = piece.kind.displayName(side: piece.side)
                                let pieceColor: Color = piece.side == .red ? .red : .black
                                let tokenWidth = max(22, dx - 4)
                                let borderColor: Color = isHighlighted ? .green : .black.opacity(0.5)
                                Text(pieceName)
                                    .font(.system(size: 18, weight: .bold, design: .serif))
                                    .foregroundStyle(pieceColor)
                                    .frame(width: tokenWidth, height: max(22, dy - 4))
                                    .background(Circle().fill(Color(red: 0.93, green: 0.73, blue: 0.38)))
                                    .overlay(Circle().stroke(borderColor, lineWidth: isHighlighted ? 3 : 1))
                                    .shadow(radius: 1)
                                    .position(point(for: BoardPosition(col: col, row: row),
                                                    dx: dx, dy: dy,
                                                    reversed: reversed))
                            }
                        }
                    }
                } else {
                    Text("等待识别棋局")
                        .font(.caption)
                        .foregroundStyle(.black.opacity(0.55))
                        .position(x: w / 2, y: h / 2)
                }
            }
        }
    }

    private func isHighlighted(col: Int, row: Int, move: UCIMove?) -> Bool {
        guard let move else { return false }
        return (move.from.col == col && move.from.row == row) ||
            (move.to.col == col && move.to.row == row)
    }

    private func point(
        for position: BoardPosition,
        dx: CGFloat,
        dy: CGFloat,
        reversed: Bool
    ) -> CGPoint {
        let col = reversed ? 8 - position.col : position.col
        let row = reversed ? 9 - position.row : position.row
        return CGPoint(x: CGFloat(col) * dx, y: CGFloat(row) * dy)
    }

    private func moveArrow(from: CGPoint, to: CGPoint) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        let angle = atan2(to.y - from.y, to.x - from.x)
        let head: CGFloat = 11
        path.move(to: to)
        path.addLine(to: CGPoint(x: to.x - head * cos(angle - .pi / 6), y: to.y - head * sin(angle - .pi / 6)))
        path.move(to: to)
        path.addLine(to: CGPoint(x: to.x - head * cos(angle + .pi / 6), y: to.y - head * sin(angle + .pi / 6)))
        return path
    }
}

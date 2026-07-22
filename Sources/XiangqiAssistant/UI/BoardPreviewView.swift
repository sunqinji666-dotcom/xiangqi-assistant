import SwiftUI

/// A small, human-readable board that mirrors the last recognized position.
/// The recommended move is highlighted so the user can follow it without
/// having to decode Chinese notation or UCI coordinates.
struct BoardPreviewView: View {
    @ObservedObject var vm: AssistantViewModel
    @State private var activeCorrection: BoardSquareCorrection?

    private let cardWidth: CGFloat = 300
    private let boardWidth: CGFloat = 270
    private let boardHeight: CGFloat = 300

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "checkerboard.rectangle")
                        .foregroundStyle(.orange)
                    Text("预览")
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
                    Button {
                        vm.onForceAnalyzePreview?()
                    } label: {
                        Text("强制")
                            .font(.caption2.weight(.bold))
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.yellow)
                    .disabled(vm.lastAnalyzedBoard == nil)
                    .help("立即以当前预览局面计算，不等待新截图或稳定帧")

                    Button {
                        vm.onStartAIReview?()
                    } label: {
                        Text("复核")
                            .font(.caption2.weight(.semibold))
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.green)
                    .disabled(vm.aiReviewPhase.isBusy)
                    .help("冻结当前棋盘并手动发送给千问视觉模型复核")

                    Button {
                        vm.onFlipBoard?()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("翻转")
                    .help("旋转局面预览和走法箭头，并在本轮分析中锁定方向")
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

                boardEditorPalette
            }

            if vm.aiReviewPhase != .idle {
                AIReviewOverlayView(vm: vm)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .padding(12)
        .frame(width: cardWidth, height: 456)
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
            // Never leave a purple arrow on a board that has already moved,
            // changed side-to-move, or no longer admits that exact move.  The
            // text strip can be cleared a rendering pass later than the board;
            // this local gate prevents a stale suggestion from looking like a
            // coordinate-mapping bug.
            let qwenMove = UCIMove(uci: vm.qwenAdviceMoveUCI).flatMap { candidate -> UCIMove? in
                guard vm.qwenAdvicePhase == .ready,
                      vm.qwenAdviceSide == vm.currentTurnSide,
                      let state,
                      state.isLegalMove(candidate, for: vm.currentTurnSide)
                else { return nil }
                return candidate
            }
            let reversed = vm.previewIsReversed

            ZStack {
                // River band
                Rectangle()
                    .fill(Color.black.opacity(0.07))
                    .frame(width: w, height: dy)
                    .position(x: w / 2, y: dy * 4.5)

                Path { path in
                    for col in 0...8 {
                        let x = CGFloat(col) * dx
                        if col == 0 || col == 8 {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: h))
                        } else {
                            // The inner files stop at both banks of the river.
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: 4 * dy))
                            path.move(to: CGPoint(x: x, y: 5 * dy))
                            path.addLine(to: CGPoint(x: x, y: h))
                        }
                    }
                    for row in 0...9 {
                        path.move(to: CGPoint(x: 0, y: CGFloat(row) * dy))
                        path.addLine(to: CGPoint(x: w, y: CGFloat(row) * dy))
                    }
                }
                .stroke(Color.black.opacity(0.55), lineWidth: 1)

                HStack {
                    Text("楚 河")
                    Spacer()
                    Text("汉 界")
                }
                .font(.system(size: 13, weight: .semibold, design: .serif))
                .foregroundStyle(Color.black.opacity(0.58))
                .padding(.horizontal, dx * 0.75)
                .frame(width: w)
                .position(x: w / 2, y: dy * 4.5)

                if let qwenMove, vm.qwenAdvicePhase == .ready {
                    moveArrow(from: point(for: qwenMove.from, dx: dx, dy: dy,
                                          reversed: reversed),
                              to: point(for: qwenMove.to, dx: dx, dy: dy,
                                        reversed: reversed))
                        .stroke(.purple, style: StrokeStyle(
                            lineWidth: 5,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: [8, 5]
                        ))
                    Circle()
                        .stroke(.purple, style: StrokeStyle(lineWidth: 3, dash: [4, 3]))
                        .frame(width: max(28, dx + 2), height: max(28, dy + 2))
                        .position(point(for: qwenMove.from, dx: dx, dy: dy,
                                        reversed: reversed))
                    Circle()
                        .stroke(.purple, lineWidth: 3)
                        .frame(width: max(24, dx - 2), height: max(24, dy - 2))
                        .position(point(for: qwenMove.to, dx: dx, dy: dy,
                                        reversed: reversed))
                }

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

                // Explicit endpoint labels make the direction unambiguous.
                // They use the same single display transform as the pieces,
                // so a reversed preview cannot rotate the arrow twice.
                if let qwenMove, vm.qwenAdvicePhase == .ready {
                    endpointBadge("起", color: .purple)
                        .position(badgePoint(
                            for: qwenMove.from,
                            dx: dx,
                            dy: dy,
                            reversed: reversed,
                            boardWidth: w,
                            boardHeight: h
                        ))
                    endpointBadge("到", color: .purple)
                        .position(badgePoint(
                            for: qwenMove.to,
                            dx: dx,
                            dy: dy,
                            reversed: reversed,
                            boardWidth: w,
                            boardHeight: h
                        ))
                }

                // Keep the interaction layer above the rendered pieces so
                // right-click works on occupied and empty intersections alike.
                if state != nil {
                    ForEach(0..<90, id: \.self) { index in
                        let position = BoardPosition(
                            col: index % 9,
                            row: index / 9
                        )
                        Color.clear
                            .frame(width: max(18, dx * 0.8),
                                   height: max(18, dy * 0.8))
                            .contentShape(Rectangle())
                            .position(point(for: position, dx: dx, dy: dy,
                                            reversed: reversed))
                            .onTapGesture {
                                guard let activeCorrection else { return }
                                vm.onCorrectBoardSquare?(position, activeCorrection)
                            }
                            .contextMenu {
                                correctionMenu(for: position)
                            }
                    }
                }
            }
        }
    }

    private var boardEditorPalette: some View {
        VStack(spacing: 4) {
            editorPieceRow(side: .red)
            editorPieceRow(side: .black)
            HStack(spacing: 14) {
                editorToolButton(
                    title: "擦棋",
                    systemImage: "eraser",
                    correction: .empty
                )
                editorToolButton(
                    title: "自动",
                    systemImage: "arrow.uturn.backward.circle",
                    correction: .followRecognition
                )
                Button {
                    activeCorrection = nil
                    vm.onForceAnalyzePreview?()
                } label: {
                    Label("完成并分析", systemImage: "bolt.circle.fill")
                        .foregroundStyle(
                            activeCorrection == nil ? Color.secondary : Color.green
                        )
                }
                .buttonStyle(.plain)
                .help("退出人工编辑，并强制以当前预览局面立即分析")
            }
            .font(.caption2)
            .frame(height: 18)
        }
        .frame(width: boardWidth)
        .help(editorHelpText)
    }

    private var editorHelpText: String {
        switch activeCorrection {
        case .piece(let piece):
            return "点击棋盘格放置\(piece.kind.displayName(side: piece.side))"
        case .empty:
            return "点击棋盘格擦除棋子"
        case .followRecognition:
            return "点击棋盘格取消人工修正，恢复截图识别"
        case nil:
            return "选择摆棋、擦棋或恢复自动，然后点击棋盘格"
        }
    }

    private func editorPieceRow(side: PieceSide) -> some View {
        HStack(spacing: 4) {
            Text(side == .red ? "红" : "黑")
                .font(.caption2.weight(.bold))
                .foregroundStyle(side == .red ? .red : .primary)
                .frame(width: 14)
            ForEach(PieceKind.allCases, id: \.self) { kind in
                let piece = Piece(kind: kind, side: side)
                let correction = BoardSquareCorrection.piece(piece)
                let isSelected = activeCorrection == correction
                Button {
                    activeCorrection = correction
                } label: {
                    Text(kind.displayName(side: side))
                        .font(.system(size: 11, weight: .bold, design: .serif))
                        .foregroundStyle(side == .red ? .red : .primary)
                        .frame(width: 25, height: 20)
                        .background(
                            Capsule().fill(
                                isSelected
                                    ? Color.green.opacity(0.42)
                                    : Color.black.opacity(0.16)
                            )
                        )
                        .overlay(
                            Capsule().stroke(
                                isSelected ? Color.green : Color.white.opacity(0.12),
                                lineWidth: isSelected ? 1.5 : 0.5
                            )
                        )
                }
                .buttonStyle(.plain)
                .help("选择\(side == .red ? "红方" : "黑方")\(kind.displayName(side: side))，然后点击棋盘格")
            }
        }
    }

    private func editorToolButton(
        title: String,
        systemImage: String,
        correction: BoardSquareCorrection
    ) -> some View {
        let isSelected = activeCorrection == correction
        return Button {
            activeCorrection = correction
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(isSelected ? .green : .primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func correctionMenu(for position: BoardPosition) -> some View {
        Button("恢复自动识别") {
            vm.onCorrectBoardSquare?(position, .followRecognition)
        }
        Button("清空这个位置") {
            vm.onCorrectBoardSquare?(position, .empty)
        }
        Divider()
        Menu("放置红方棋子") {
            correctionButtons(side: .red, position: position)
        }
        Menu("放置黑方棋子") {
            correctionButtons(side: .black, position: position)
        }
    }

    @ViewBuilder
    private func correctionButtons(
        side: PieceSide,
        position: BoardPosition
    ) -> some View {
        ForEach(PieceKind.allCases, id: \.self) { kind in
            Button(kind.displayName(side: side)) {
                vm.onCorrectBoardSquare?(
                    position,
                    .piece(Piece(kind: kind, side: side))
                )
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

    private func endpointBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .black))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1))
    }

    private func badgePoint(
        for position: BoardPosition,
        dx: CGFloat,
        dy: CGFloat,
        reversed: Bool,
        boardWidth: CGFloat,
        boardHeight: CGFloat
    ) -> CGPoint {
        let base = point(for: position, dx: dx, dy: dy, reversed: reversed)
        let xOffset: CGFloat = base.x > boardWidth - 18 ? -12 : 12
        let yOffset: CGFloat = base.y < 18 ? 12 : -12
        return CGPoint(
            x: min(max(8, base.x + xOffset), boardWidth - 8),
            y: min(max(8, base.y + yOffset), boardHeight - 8)
        )
    }
}

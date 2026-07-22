import SwiftUI
import AppKit

struct AIReviewOverlayView: View {
    @ObservedObject var vm: AssistantViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flashOpacity = 0.92

    var body: some View {
        VStack(spacing: 9) {
            header
            reviewContent
                .id(vm.aiReviewPhase)
                .transition(
                    .opacity.combined(
                        with: reduceMotion ? .identity : .scale(scale: 0.985)
                    )
                )
            footer
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
        .overlay {
            Color.white
                .opacity(vm.aiReviewPhase == .captured ? flashOpacity : 0)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
        }
        .onAppear(perform: animateFlashIfNeeded)
        .onChange(of: vm.aiReviewPhase) { _, phase in
            guard phase == .captured else { return }
            flashOpacity = 0.92
            animateFlashIfNeeded()
        }
        .animation(
            reduceMotion
                ? .linear(duration: 0.12)
                : .timingCurve(0.23, 1, 0.32, 1, duration: 0.22),
            value: vm.aiReviewPhase
        )
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles.rectangle.stack")
                .foregroundStyle(.orange)
            Text("千问 AI 复核")
                .font(.caption.weight(.semibold))
            Spacer()
            if let confidence = vm.aiReviewConfidence,
               vm.aiReviewPhase == .ready {
                Text("\(Int((confidence * 100).rounded()))%")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(confidence >= 0.8 ? .green : .yellow)
            }
        }
    }

    @ViewBuilder
    private var reviewContent: some View {
        switch vm.aiReviewPhase {
        case .captured, .sending, .reviewing:
            VStack(spacing: 8) {
                snapshot
                HStack(spacing: 7) {
                    if vm.aiReviewPhase != .captured {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "camera.fill")
                            .foregroundStyle(.orange)
                    }
                    Text(progressTitle)
                        .font(.caption.weight(.semibold))
                }
                Text(progressDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .ready:
            VStack(spacing: 7) {
                if let board = vm.aiReviewBoard {
                    AIReviewBoardCanvas(
                        board: board,
                        reversed: vm.previewIsReversed,
                        differences: vm.aiReviewDifferences
                    )
                    .frame(height: 292)
                }
                Text(resultSummary)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(vm.aiReviewDifferences.isEmpty ? .green : .orange)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if !vm.aiReviewMessage.isEmpty {
                    Text(vm.aiReviewMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }

        case .failed:
            VStack(spacing: 10) {
                snapshot
                    .opacity(0.55)
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(vm.aiReviewMessage)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

        case .idle:
            EmptyView()
        }
    }

    private var snapshot: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.black.opacity(0.22))
            if let image = vm.aiReviewSnapshot {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(5)
            } else {
                Image(systemName: "camera.viewfinder")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
        .frame(height: 276)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            Button(vm.aiReviewPhase.isBusy ? "取消复核" : "关闭") {
                vm.onDismissAIReview?()
            }
            .buttonStyle(.plain)
            .font(.caption2)
            .foregroundStyle(.secondary)

            Spacer()

            if vm.aiReviewPhase == .ready {
                Button {
                    vm.onApplyAIReview?()
                } label: {
                    Label(
                        vm.aiReviewDifferences.isEmpty
                            ? "与当前一致，无需应用"
                            : "应用到当前局面",
                        systemImage: "checkmark.circle.fill"
                    )
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.22), in: Capsule())
                        .overlay(Capsule().stroke(Color.green.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
                .disabled(vm.aiReviewDifferences.isEmpty)
            } else if vm.aiReviewPhase == .failed {
                Button {
                    vm.onStartAIReview?()
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            }
        }
        .frame(height: 25)
    }

    private var progressTitle: String {
        switch vm.aiReviewPhase {
        case .captured: return "已冻结当前棋盘"
        case .sending: return "正在发送给千问"
        case .reviewing: return "千问正在逐格复核"
        default: return ""
        }
    }

    private var progressDetail: String {
        switch vm.aiReviewPhase {
        case .captured: return "只发送上方这张棋盘裁图"
        case .sending: return "已加密连接复核服务"
        case .reviewing: return "通常需要几秒，不会改动当前局面"
        default: return ""
        }
    }

    private var resultSummary: String {
        if vm.aiReviewDifferences.isEmpty {
            return "千问与当前局面完全一致"
        }
        return "发现 \(vm.aiReviewDifferences.count) 个不同交叉点，红圈已标出；确认后再应用"
    }

    private func animateFlashIfNeeded() {
        guard vm.aiReviewPhase == .captured else { return }
        withAnimation(.easeOut(duration: reduceMotion ? 0.10 : 0.18)) {
            flashOpacity = 0
        }
    }
}

private struct AIReviewBoardCanvas: View {
    let board: BoardState
    let reversed: Bool
    let differences: Set<BoardPosition>

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let dx = width / 8
            let dy = height / 9

            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(red: 0.72, green: 0.48, blue: 0.25))

                Path { path in
                    for column in 0...8 {
                        let x = CGFloat(column) * dx
                        if column == 0 || column == 8 {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: height))
                        } else {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: 4 * dy))
                            path.move(to: CGPoint(x: x, y: 5 * dy))
                            path.addLine(to: CGPoint(x: x, y: height))
                        }
                    }
                    for row in 0...9 {
                        path.move(to: CGPoint(x: 0, y: CGFloat(row) * dy))
                        path.addLine(to: CGPoint(x: width, y: CGFloat(row) * dy))
                    }
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

                Text("楚 河                 汉 界")
                    .font(.system(size: 12, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.black.opacity(0.56))
                    .position(x: width / 2, y: dy * 4.5)

                ForEach(0..<90, id: \.self) { index in
                    let position = BoardPosition(col: index % 9, row: index / 9)
                    if let piece = board[position] {
                        let displayColumn = reversed ? 8 - position.col : position.col
                        let displayRow = reversed ? 9 - position.row : position.row
                        Text(piece.kind.displayName(side: piece.side))
                            .font(.system(size: 17, weight: .bold, design: .serif))
                            .foregroundStyle(piece.side == .red ? .red : .black)
                            .frame(width: max(22, dx - 4), height: max(22, dy - 4))
                            .background(
                                Circle().fill(Color(red: 0.93, green: 0.73, blue: 0.38))
                            )
                            .overlay(
                                Circle().stroke(
                                    differences.contains(position) ? Color.red : Color.black.opacity(0.5),
                                    lineWidth: differences.contains(position) ? 3 : 1
                                )
                            )
                            .position(
                                x: CGFloat(displayColumn) * dx,
                                y: CGFloat(displayRow) * dy
                            )
                    } else if differences.contains(position) {
                        let displayColumn = reversed ? 8 - position.col : position.col
                        let displayRow = reversed ? 9 - position.row : position.row
                        Circle()
                            .stroke(Color.red, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                            .frame(width: max(20, dx - 6), height: max(20, dy - 6))
                            .position(
                                x: CGFloat(displayColumn) * dx,
                                y: CGFloat(displayRow) * dy
                            )
                    }
                }
            }
        }
        // Xiangqi pieces are centered on the outermost intersections. Reserve
        // a token-radius margin so edge pieces stay inside the photo frame and
        // never overlap the result summary or Apply button below.
        .padding(13)
        .background(
            Color(red: 0.72, green: 0.48, blue: 0.25),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

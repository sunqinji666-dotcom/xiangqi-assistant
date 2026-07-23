import SwiftUI
import Combine
import AppKit

enum AnalysisMode: String, CaseIterable {
    case normal
    case aggressive
    case ultra

    var label: String {
        switch self {
        case .normal: return "稳健"
        case .aggressive: return "杀棋"
        case .ultra: return "超强"
        }
    }

    var icon: String {
        switch self {
        case .normal: return "shield.fill"
        case .aggressive: return "flame.fill"
        case .ultra: return "bolt.fill"
        }
    }

    var accent: Color {
        switch self {
        case .normal: return .secondary
        case .aggressive: return .orange
        case .ultra: return .yellow
        }
    }
}

enum BoardSquareCorrection: Equatable {
    case followRecognition
    case empty
    case piece(Piece)
}

enum AIReviewPhase: Equatable {
    case idle
    case captured
    case sending
    case reviewing
    case ready
    case failed

    var isBusy: Bool {
        self == .captured || self == .sending || self == .reviewing
    }
}

enum QwenAdvicePhase: Equatable {
    case idle
    case loading
    case ready
    case failed
}

// MARK: - View Model

@MainActor
class AssistantViewModel: ObservableObject {
    @Published var bestMove: String = "--"        // UCI move, e.g. "h2e2"
    @Published var bestMoveCN: String = "--"      // Chinese notation, e.g. "炮二平五"
    @Published var score: Int = 0                 // centipawns, normalized to Red's perspective
    /// Signed mate distance normalized to Red's perspective.
    @Published var mateIn: Int? = nil
    @Published var depth: Int = 0
    @Published var pv: [String] = []
    @Published var searchDetail: String = ""
    @Published var status: AssistantStatus = .idle
    @Published var isRunning: Bool = false
    @Published var errorMessage: String?
    @Published var isCalibrated: Bool = false
    @Published var calibrationMessage: String = ""

    // Window selection
    @Published var availableWindows: [(id: UInt32, title: String)] = []
    @Published var selectedWindowID: UInt32? = nil
    @Published var captureSourceUnavailable: Bool = false
    var windowTitle: String {
        if captureSourceUnavailable { return "目标窗口不可用" }
        return availableWindows.first { $0.id == selectedWindowID }?.title ?? "全屏"
    }

    @Published var lastAnalyzedBoard: BoardState? = nil
    /// Mirrors the source application's board orientation for the preview;
    /// engine coordinates remain canonical regardless of this display choice.
    @Published var previewIsReversed: Bool = false
    @Published var aiReviewPhase: AIReviewPhase = .idle
    @Published var aiReviewSnapshot: NSImage? = nil
    @Published var aiReviewBoard: BoardState? = nil
    @Published var aiReviewDifferences: Set<BoardPosition> = []
    @Published var aiReviewConfidence: Double? = nil
    @Published var aiReviewModelName: String = "qwen3.7-plus"
    @Published var aiReviewMessage: String = ""
    @Published var qwenAdvicePhase: QwenAdvicePhase = .idle
    @Published var qwenAdviceMoveUCI: String = ""
    @Published var qwenAdviceMoveCN: String = ""
    @Published var qwenAdviceReason: String = ""
    @Published var qwenAdvicePlan: String = ""
    @Published var qwenAdviceConfidence: Double? = nil
    @Published var qwenAdviceMessage: String = ""
    @Published var qwenAdviceCandidateRank: Int? = nil
    @Published var qwenAdviceCandidateCount: Int? = nil
    @Published var qwenAdviceScoreGapCentipawns: Int? = nil
    @Published var qwenAdviceAgreesWithGreen: Bool? = nil
    /// The side controlled by the user. Keep it across app relaunches so a
    /// Black player is never silently put back into Red mode after an update.
    @Published var playerSide: PieceSide = AssistantViewModel.savedPlayerSide {
        didSet {
            UserDefaults.standard.set(
                playerSide == .red ? "red" : "black",
                forKey: Self.playerSideDefaultsKey
            )
        }
    }
    @Published var recommendedSide: PieceSide? = nil
    /// The side that is actually due to move in the currently tracked game.
    /// It is deliberately separate from `playerSide`: a user can play Black
    /// while Red is due to move (and vice versa).
    @Published var currentTurnSide: PieceSide = AssistantViewModel.savedCurrentTurnSide {
        didSet {
            UserDefaults.standard.set(
                currentTurnSide == .red ? "red" : "black",
                forKey: Self.currentTurnSideDefaultsKey
            )
        }
    }
    @Published var analysisMode: AnalysisMode = AssistantViewModel.savedAnalysisMode {
        didSet {
            UserDefaults.standard.set(
                analysisMode.rawValue,
                forKey: Self.analysisModeDefaultsKey
            )
        }
    }
    var playerSideLabel: String { playerSide == .red ? "红方" : "黑方" }
    var currentTurnLabel: String { currentTurnSide == .red ? "红方" : "黑方" }

    // Callbacks wired by AppDelegate
    var onToggleAnalysis: (() -> Void)?
    var onCalibrate: (() -> Void)?
    var onWindowSelected: ((UInt32?) -> Void)?
    var onRefreshWindows: (() -> Void)?
    var onSelectBoard: (() -> Void)?
    var onClearBoard: (() -> Void)?
    var onPlayerSideChanged: ((PieceSide) -> Void)?
    var onTurnSideChanged: ((PieceSide) -> Void)?
    var onAnalysisModeChanged: ((AnalysisMode) -> Void)?
    var onResyncPosition: (() -> Void)?
    var onCorrectBoardSquare: ((BoardPosition, BoardSquareCorrection) -> Void)?
    var onFlipBoard: (() -> Void)?
    var onStartAIReview: (() -> Void)?
    var onApplyAIReview: (() -> Void)?
    var onDismissAIReview: (() -> Void)?
    var onForceAnalyzePreview: (() -> Void)?
    var onRequestQwenAdvice: (() -> Void)?
    @Published var hasBoardGeometry: Bool = false
    @Published var needsPositionResync: Bool = false
    /// Temporary on-panel capture diagnostic used when a board cannot be
    /// recognized. It stays inside the app and is never written or sent.
    @Published var diagnosticCapture: NSImage? = nil

    private static let playerSideDefaultsKey = "xiangqiAssistant.playerSide"
    private static let currentTurnSideDefaultsKey = "xiangqiAssistant.currentTurnSide"
    private static let analysisModeDefaultsKey = "xiangqiAssistant.analysisMode"
    private static var savedPlayerSide: PieceSide {
        UserDefaults.standard.string(forKey: playerSideDefaultsKey) == "black"
            ? .black
            : .red
    }
    private static var savedCurrentTurnSide: PieceSide {
        UserDefaults.standard.string(forKey: currentTurnSideDefaultsKey) == "black"
            ? .black
            : .red
    }
    private static var savedAnalysisMode: AnalysisMode {
        guard let rawValue = UserDefaults.standard.string(forKey: analysisModeDefaultsKey)
        else { return .ultra }
        return AnalysisMode(rawValue: rawValue) ?? .ultra
    }

    enum AssistantStatus {
        case idle, needsBoardSelection, capturing, analyzing, stable, unstable, error
        var color: Color {
            switch self {
            case .idle:      return .gray
            case .needsBoardSelection: return .orange
            case .capturing: return .yellow
            case .analyzing: return .blue
            case .stable:    return .green
            case .unstable:  return .orange
            case .error:     return .red
            }
        }
        var label: String {
            switch self {
            case .idle:      return "未启动"
            case .needsBoardSelection: return "请框选棋盘"
            case .capturing: return "识别中"
            case .analyzing: return "分析中"
            case .stable:    return "就绪"
            case .unstable:  return "识别不稳定"
            case .error:     return "错误"
            }
        }
    }

    var scoreText: String {
        if let mateIn {
            if mateIn > 0 { return "红方预计 \(mateIn) 步杀" }
            if mateIn < 0 { return "黑方预计 \(-mateIn) 步杀" }
            return score >= 0 ? "红方已形成绝杀" : "黑方已形成绝杀"
        }
        let abs = Swift.abs(score)
        let side = score > 0 ? "红" : (score < 0 ? "黑" : "")
        if abs == 0 { return "均势" }
        return "\(side)优 \(String(format: "%.1f", Double(abs) / 100.0)) 子"
    }

    var scoreBarFraction: Double {
        // Map ±500 centipawns to 0.0 – 1.0, center = 0.5
        let clamped = max(-500, min(500, score))
        return (Double(clamped) + 500) / 1000
    }
}

// MARK: - Main View

struct AssistantView: View {
    @ObservedObject var vm: AssistantViewModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                assistantCard
                BoardPreviewView(vm: vm)
            }
            qwenAdviceStrip
        }
        .padding(8)
        .colorScheme(.dark)
    }

    private var assistantCard: some View {
        ZStack {
            // Glassmorphism background
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )

            VStack(spacing: 0) {
                headerBar
                Divider().opacity(0.3)
                if !vm.isCalibrated {
                    calibrationBanner
                    Divider().opacity(0.3)
                }
                mainContent
                Divider().opacity(0.3)
                footerBar
            }
        }
        .frame(width: 300, height: 456)
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: Header

    private var headerBar: some View {
        HStack {
            // Status dot
            Circle()
                .fill(vm.status.color)
                .frame(width: 8, height: 8)
                .shadow(color: vm.status.color.opacity(0.8), radius: 4)

            Text(vm.status.label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Text("象棋助手")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            Spacer()

            // Toggle button
            Button {
                vm.onToggleAnalysis?()
            } label: {
                Image(systemName: vm.isRunning ? "pause.circle" : "play.circle")
                    .font(.title3)
                    .foregroundStyle(vm.isRunning ? .orange : .green)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Calibration Banner

    private var calibrationBanner: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.yellow)
                Text("首次使用需要校准")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            }
            Text("在象棋软件里开一局新棋（初始布局），然后点下方按钮")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if !vm.calibrationMessage.isEmpty {
                Text(vm.calibrationMessage)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 8) {
                Button {
                    vm.onCalibrate?()
                } label: {
                    Label("一键校准", systemImage: "camera.viewfinder")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.yellow.opacity(0.2))
                        .foregroundStyle(.yellow)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.yellow.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)

                // Manual board selection — most reliable when Vision fails
                Button {
                    vm.onSelectBoard?()
                } label: {
                    Label(vm.hasBoardGeometry ? "重新框选" : "手动框选棋盘",
                          systemImage: "selection.pin.in.corner")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(vm.hasBoardGeometry
                            ? Color.green.opacity(0.2)
                            : Color.blue.opacity(0.2))
                        .foregroundStyle(vm.hasBoardGeometry ? .green : .blue)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(
                            (vm.hasBoardGeometry ? Color.green : Color.blue).opacity(0.4),
                            lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    // MARK: Main Content

    private var mainContent: some View {
        VStack(spacing: 16) {
            // Best move display
            VStack(spacing: 4) {
                Text("最佳走法")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)

                Text(vm.bestMoveCN)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                Text(vm.bestMove)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospaced()

                if !vm.searchDetail.isEmpty {
                    Text(vm.searchDetail)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.yellow.opacity(0.8))
                }

            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)

            // Score bar
            VStack(spacing: 6) {
                HStack {
                    Text("红").font(.caption2).foregroundStyle(.red.opacity(0.8))
                    Spacer()
                    Text(vm.scoreText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("黑").font(.caption2).foregroundStyle(.primary.opacity(0.6))
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.15))
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(scoreBarGradient)
                            .frame(width: geo.size.width * vm.scoreBarFraction, height: 6)
                            .animation(.easeInOut(duration: 0.4), value: vm.scoreBarFraction)
                    }
                }
                .frame(height: 6)
            }

            // PV line (next moves)
            if !vm.pv.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("后续变化")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(vm.pv.prefix(5).joined(separator: " → "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospaced()
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: Footer

    private var footerBar: some View {
        VStack(spacing: 0) {
            // Window picker row
            HStack(spacing: 8) {
                VStack(spacing: 2) {
                    Label("我方", systemImage: "person.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                Menu {
                    Button("红方") {
                        vm.playerSide = .red
                        vm.onPlayerSideChanged?(.red)
                    }
                    Button("黑方") {
                        vm.playerSide = .black
                        vm.onPlayerSideChanged?(.black)
                    }
                } label: {
                        HStack(spacing: 3) {
                            Text(vm.playerSideLabel)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .foregroundStyle(.tertiary)
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(vm.playerSide == .red ? .red : .primary)
                        .frame(maxWidth: .infinity)
                }
                .menuStyle(.borderlessButton)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 2) {
                    Text("轮到")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                Menu {
                    Button("红方走") {
                        vm.currentTurnSide = .red
                        vm.onTurnSideChanged?(.red)
                    }
                    Button("黑方走") {
                        vm.currentTurnSide = .black
                        vm.onTurnSideChanged?(.black)
                    }
                } label: {
                        HStack(spacing: 3) {
                            Text(vm.currentTurnLabel)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .foregroundStyle(.tertiary)
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(vm.currentTurnSide == .red ? .red : .primary)
                        .frame(maxWidth: .infinity)
                }
                .menuStyle(.borderlessButton)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 2) {
                    Label("棋风", systemImage: vm.analysisMode.icon)
                        .font(.caption2)
                        .foregroundStyle(vm.analysisMode.accent)
                Menu {
                    Button("超强 · 最高胜率") {
                        vm.analysisMode = .ultra
                        vm.onAnalysisModeChanged?(.ultra)
                    }
                    Button("杀棋 · 主动进攻") {
                        vm.analysisMode = .aggressive
                        vm.onAnalysisModeChanged?(.aggressive)
                    }
                    Button("稳健 · 引擎最佳") {
                        vm.analysisMode = .normal
                        vm.onAnalysisModeChanged?(.normal)
                    }
                } label: {
                        HStack(spacing: 3) {
                            Text(vm.analysisMode.label)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .foregroundStyle(.tertiary)
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(vm.analysisMode.accent)
                        .frame(maxWidth: .infinity)
                }
                .menuStyle(.borderlessButton)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)

            HStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Menu {
                    Button("全屏捕获") { vm.onWindowSelected?(nil) }
                    Divider()
                    ForEach(vm.availableWindows, id: \.id) { win in
                        Button(win.title) { vm.onWindowSelected?(win.id) }
                    }
                    Divider()
                    Button("刷新窗口列表") { vm.onRefreshWindows?() }
                } label: {
                    Text(vm.windowTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    vm.onRefreshWindows?()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("刷新窗口列表")

                Button {
                    vm.onSelectBoard?()
                } label: {
                    Image(systemName: "selection.pin.in.corner")
                        .font(.caption.weight(.semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(vm.hasBoardGeometry ? .green : .blue)
                .help(vm.hasBoardGeometry ? "重新框选棋盘" : "手动框选棋盘")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            Divider().opacity(0.2)

            // Depth + error row
            HStack {
                Label("深度 \(vm.depth)", systemImage: "arrow.down.to.line")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if vm.needsPositionResync {
                    Button {
                        vm.onResyncPosition?()
                    } label: {
                        Label("重新同步", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.18))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("保留框选与识别设置，重新确认当前棋局")
                } else if let err = vm.errorMessage {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    // MARK: Qwen second opinion

    private var qwenAdviceStrip: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.purple.opacity(0.22))
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.purple)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("千问独立建议")
                        .font(.caption.weight(.semibold))
                    Text("第二路引擎验证的独立备选")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                    if let confidence = vm.qwenAdviceConfidence,
                       vm.qwenAdvicePhase == .ready {
                        Text("\(Int((confidence * 100).rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                switch vm.qwenAdvicePhase {
                case .idle:
                    Text("第二路本地引擎先筛选强着，千问可独立选择不同的紫色方案")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .loading:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("千问正在分析当前局面…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                case .ready:
                    HStack(spacing: 8) {
                        Text(vm.qwenAdviceMoveCN)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.purple)
                        Text(vm.qwenAdviceMoveUCI)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                        if let move = UCIMove(uci: vm.qwenAdviceMoveUCI) {
                            Text("起 \(move.uci.prefix(2)) → 到 \(move.uci.suffix(2))")
                                .font(.caption2.monospaced().weight(.semibold))
                                .foregroundStyle(.purple.opacity(0.85))
                        }
                        Text(vm.qwenAdviceReason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 7) {
                        if let rank = vm.qwenAdviceCandidateRank {
                            let total = vm.qwenAdviceCandidateCount ?? rank
                            Text("第二路引擎 #\(rank)/\(total)")
                        }
                        if vm.qwenAdviceAgreesWithGreen == true {
                            Text("与绿色一致")
                                .foregroundStyle(.green)
                        } else if vm.qwenAdviceAgreesWithGreen == false {
                            Text("紫色独立备选")
                                .foregroundStyle(.purple)
                        }
                        if let gap = vm.qwenAdviceScoreGapCentipawns {
                            Text(gap == 0 ? "评价并列" : "评价差 \(formatScoreGap(gap))")
                        }
                        Text(vm.qwenAdvicePlan)
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                case .failed:
                    Text(vm.qwenAdviceMessage)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                vm.onRequestQwenAdvice?()
            } label: {
                Label(
                    vm.qwenAdvicePhase == .ready ? "重新分析" : "问千问",
                    systemImage: "paperplane.fill"
                )
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Color.purple.opacity(0.20), in: Capsule())
                .overlay(Capsule().stroke(Color.purple.opacity(0.45), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.purple)
            .disabled(vm.qwenAdvicePhase == .loading || vm.lastAnalyzedBoard == nil)
        }
        .padding(.horizontal, 14)
        .frame(width: 610, height: 86)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.purple.opacity(0.28), lineWidth: 1)
        )
    }

    // MARK: Helpers

    private var scoreBarGradient: LinearGradient {
        LinearGradient(
            colors: [.red.opacity(0.8), .orange.opacity(0.6)],
            startPoint: .leading, endPoint: .trailing
        )
    }

    private func formatScoreGap(_ centipawns: Int) -> String {
        String(format: "%.2f兵", Double(max(0, centipawns)) / 100.0)
    }
}

// MARK: - Preview

#Preview {
    let vm = AssistantViewModel()
    vm.bestMove = "h2e2"
    vm.bestMoveCN = "炮二平五"
    vm.score = 35
    vm.depth = 18
    vm.status = .stable
    vm.pv = ["h2e2", "b9c7", "h0g2"]
    return AssistantView(vm: vm)
        .frame(width: 300)
        .padding()
        .background(Color.black.opacity(0.5))
}

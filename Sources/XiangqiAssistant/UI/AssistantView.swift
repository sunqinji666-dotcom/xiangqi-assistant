import SwiftUI
import Combine

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
    @Published var analysisMode: AnalysisMode = .ultra
    var playerSideLabel: String { playerSide == .red ? "红方" : "黑方" }

    // Callbacks wired by AppDelegate
    var onToggleAnalysis: (() -> Void)?
    var onCalibrate: (() -> Void)?
    var onWindowSelected: ((UInt32?) -> Void)?
    var onRefreshWindows: (() -> Void)?
    var onSelectBoard: (() -> Void)?
    var onClearBoard: (() -> Void)?
    var onPlayerSideChanged: ((PieceSide) -> Void)?
    var onAnalysisModeChanged: ((AnalysisMode) -> Void)?
    @Published var hasBoardGeometry: Bool = false
    /// Temporary on-panel capture diagnostic used when a board cannot be
    /// recognized. It stays inside the app and is never written or sent.
    @Published var diagnosticCapture: NSImage? = nil

    private static let playerSideDefaultsKey = "xiangqiAssistant.playerSide"
    private static var savedPlayerSide: PieceSide {
        UserDefaults.standard.string(forKey: playerSideDefaultsKey) == "black"
            ? .black
            : .red
    }

    enum AssistantStatus {
        case idle, capturing, analyzing, stable, unstable, error
        var color: Color {
            switch self {
            case .idle:      return .gray
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
        HStack(spacing: 10) {
            assistantCard
            BoardPreviewView(vm: vm)
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
        .frame(width: 300)
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
            HStack(spacing: 6) {
                Image(systemName: "person.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("我方")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                    Text(vm.playerSideLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .menuStyle(.borderlessButton)
                Spacer()

                Image(systemName: vm.analysisMode.icon)
                    .font(.caption2)
                    .foregroundStyle(vm.analysisMode.accent)
                Text("棋风")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                    Text(vm.analysisMode.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(vm.analysisMode.accent)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .menuStyle(.borderlessButton)
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
                if let err = vm.errorMessage {
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

    // MARK: Helpers

    private var scoreBarGradient: LinearGradient {
        LinearGradient(
            colors: [.red.opacity(0.8), .orange.opacity(0.6)],
            startPoint: .leading, endPoint: .trailing
        )
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

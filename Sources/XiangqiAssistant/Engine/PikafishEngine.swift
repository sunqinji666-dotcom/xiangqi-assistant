import Foundation

// MARK: - Data Types

struct EngineMove {
    let uci: String       // e.g. "h2e2"
    let score: Int        // centipawns from the side-to-move perspective
    /// Signed UCI mate distance from the side-to-move perspective. Positive
    /// means the root side can force mate; negative means it is being mated.
    let mateIn: Int?
    let depth: Int
    let pv: [String]      // principal variation
}

enum EngineSearchPhase: Equatable {
    case quick
    case deepening
    case final
}

struct EngineSearchUpdate {
    let phase: EngineSearchPhase
    let move: EngineMove
}

private struct ParsedEngineScore {
    let centipawns: Int
    let mateIn: Int?
}

/// A single-consumer mailbox with a real wall-clock timeout. Unlike racing an
/// AsyncStream iterator inside a task group, timing out or cancelling one wait
/// does not terminate the entire engine output channel.
final class EngineLineMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffered: [String] = []
    private var waiter: (id: UUID, continuation: CheckedContinuation<String, Error>)?
    private var terminalError: Error?

    func push(_ line: String) {
        var continuation: CheckedContinuation<String, Error>?
        lock.lock()
        if terminalError == nil {
            if let waiting = waiter {
                waiter = nil
                continuation = waiting.continuation
            } else {
                buffered.append(line)
            }
        }
        lock.unlock()
        continuation?.resume(returning: line)
    }

    func finish(_ error: Error) {
        var continuation: CheckedContinuation<String, Error>?
        lock.lock()
        if terminalError == nil {
            terminalError = error
            continuation = waiter?.continuation
            waiter = nil
        }
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    func next(timeout: TimeInterval) async throws -> String {
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            var immediate: Result<String, Error>?
            lock.lock()
            if !buffered.isEmpty {
                immediate = .success(buffered.removeFirst())
            } else if let terminalError {
                immediate = .failure(terminalError)
            } else if waiter != nil {
                immediate = .failure(EngineError.launchFailed("检测到并发读取引擎输出"))
            } else {
                waiter = (id, continuation)
            }
            lock.unlock()

            if let immediate {
                continuation.resume(with: immediate)
            } else {
                Task { [weak self] in
                    try? await Task.sleep(
                        nanoseconds: UInt64(max(0.001, timeout) * 1_000_000_000)
                    )
                    self?.expire(id: id)
                }
            }
        }
    }

    private func expire(id: UUID) {
        var continuation: CheckedContinuation<String, Error>?
        lock.lock()
        if waiter?.id == id {
            continuation = waiter?.continuation
            waiter = nil
        }
        lock.unlock()
        continuation?.resume(throwing: EngineError.timeout)
    }
}

/// FileHandle invokes its readability callback on a concurrent context. Keep
/// line assembly behind a tiny lock so the engine transport is data-race free.
private final class EngineLineDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private let mailbox: EngineLineMailbox

    init(mailbox: EngineLineMailbox) {
        self.mailbox = mailbox
    }

    func consume(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        buffer += chunk
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newline])
                .trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { lines.append(line) }
        }
        lock.unlock()
        for line in lines { mailbox.push(line) }
    }
}

enum EngineError: LocalizedError {
    case binaryNotFound
    case nnueNotFound
    case launchFailed(String)
    case timeout
    case noLegalMove

    var errorDescription: String? {
        switch self {
        case .binaryNotFound: return "找不到 pikafish-apple-silicon 引擎文件"
        case .nnueNotFound:   return "找不到 pikafish.nnue 权重文件"
        case .launchFailed(let msg): return "引擎启动失败: \(msg)"
        case .timeout:        return "引擎响应超时"
        case .noLegalMove:    return "当前局面没有合法走法"
        }
    }
}

// MARK: - Engine Actor

/// Thread-safe Pikafish UCI engine wrapper using a timed line mailbox for
/// non-blocking I/O.
actor PikafishEngine {

    // MARK: State
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var lineMailbox: EngineLineMailbox?
    private var isReady = false
    private var stopRequestedExternally = false

    // MARK: Lifecycle

    func start() async throws {
        if isReady, process?.isRunning == true { return }
        if process != nil { stop() }

        let engineURL = try Self.findBinary(named: "pikafish-apple-silicon")
        let nnueURL   = try Self.findBinary(named: "pikafish.nnue")

        // Ensure the binary is executable
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: engineURL.path
        )

        let p = Process()
        p.executableURL = engineURL
        p.currentDirectoryURL = nnueURL.deletingLastPathComponent()

        let stdin  = Pipe()
        let stdout = Pipe()
        p.standardInput  = stdin
        p.standardOutput = stdout
        p.standardError  = stdout

        let mailbox = EngineLineMailbox()
        p.terminationHandler = { process in
            mailbox.finish(EngineError.launchFailed(
                "引擎进程已退出（状态 \(process.terminationStatus)）"
            ))
        }

        try p.run()
        process     = p
        stdinHandle = stdin.fileHandleForWriting
        lineMailbox = mailbox

        // Attach after Process.run(): an empty pre-launch FileHandle callback
        // must not be mistaken for EOF. Pipe output produced before this point
        // remains buffered and is delivered immediately.
        let handle = stdout.fileHandleForReading
        stdoutHandle = handle
        let decoder = EngineLineDecoder(mailbox: mailbox)
        handle.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty {
                mailbox.finish(EngineError.launchFailed("引擎输出流已关闭"))
                fh.readabilityHandler = nil
            } else {
                decoder.consume(data)
            }
        }

        do {
            // UCI handshake
            send("uci")
            try await waitFor(token: "uciok", timeout: 5)
            send("setoption name EvalFile value \(nnueURL.path)")
            send("setoption name Threads value \(StrengthProfile.engineThreads)")
            send("setoption name Hash value \(StrengthProfile.hashMegabytes)")
            send("isready")
            try await waitFor(token: "readyok", timeout: 5)
            isReady = true
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        send("quit")
        if process?.isRunning == true {
            process?.terminate()
        }
        stdoutHandle?.readabilityHandler = nil
        stdinHandle = nil
        stdoutHandle = nil
        process = nil
        lineMailbox?.finish(EngineError.launchFailed("引擎已停止"))
        lineMailbox = nil
        isReady = false
        stopRequestedExternally = false
    }

    /// Recreate the subprocess and its output stream after an interrupted or
    /// unexpectedly closed analysis session.
    func restart() async throws {
        stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        try await start()
    }

    // MARK: Analysis

    func analyze(
        fen: String,
        movesFromStart: [String]? = nil,
        movetime: Int = 2000,
        searchMoves: [String]? = nil
    ) async throws -> EngineMove {
        guard isReady else { throw EngineError.launchFailed("引擎未就绪") }
        stopRequestedExternally = false
        send("stop")
        if let movesFromStart {
            let suffix = movesFromStart.isEmpty ? "" : " moves \(movesFromStart.joined(separator: " "))"
            send("position startpos\(suffix)")
        } else {
            send("position fen \(fen)")
        }
        if let searchMoves, !searchMoves.isEmpty {
            send("go searchmoves \(searchMoves.joined(separator: " ")) movetime \(movetime)")
        } else {
            send("go movetime \(movetime)")
        }
        return try await readBestMove(timeout: Double(movetime) / 1000.0 + 3.0)
    }

    /// Returns Pikafish's ordered MultiPV choices. This lets the UI offer an
    /// attacking personality while retaining the engine's objective safety net.
    func analyzeCandidates(
        fen: String,
        movesFromStart: [String]? = nil,
        movetime: Int = 2000,
        count: Int = 6,
        searchMoves: [String]? = nil
    ) async throws -> [EngineMove] {
        guard isReady else { throw EngineError.launchFailed("引擎未就绪") }
        stopRequestedExternally = false
        let pvCount = max(2, min(10, count))
        send("stop")
        if let movesFromStart {
            let suffix = movesFromStart.isEmpty ? "" : " moves \(movesFromStart.joined(separator: " "))"
            send("position startpos\(suffix)")
        } else {
            send("position fen \(fen)")
        }
        send("setoption name MultiPV value \(pvCount)")
        if let searchMoves, !searchMoves.isEmpty {
            send("go searchmoves \(searchMoves.joined(separator: " ")) movetime \(movetime)")
        } else {
            send("go movetime \(movetime)")
        }
        do {
            let moves = try await readCandidateMoves(
                timeout: Double(movetime) / 1000.0 + 3.0
            )
            send("setoption name MultiPV value 1")
            return moves
        } catch {
            send("setoption name MultiPV value 1")
            throw error
        }
    }

    /// Runs one uninterrupted single-PV search. It publishes a usable answer
    /// at the quick milestone, stops ordinary positions at the normal
    /// milestone, and lets tactically unstable positions use the full budget.
    /// Only one caller may consume engine output at a time; AppDelegate
    /// serializes replacements and waits for a cancelled search to drain its
    /// `bestmove` before starting another one.
    func analyzeAdaptive(
        fen: String,
        movesFromStart: [String]? = nil,
        quickTime: Int,
        normalTime: Int,
        complexTime: Int,
        onUpdate: @escaping (EngineSearchUpdate) -> Void
    ) async throws -> EngineMove {
        guard isReady else { throw EngineError.launchFailed("引擎未就绪") }
        stopRequestedExternally = false

        if let movesFromStart {
            let suffix = movesFromStart.isEmpty ? "" : " moves \(movesFromStart.joined(separator: " "))"
            send("position startpos\(suffix)")
        } else {
            send("position fen \(fen)")
        }
        send("setoption name MultiPV value 1")
        send("go movetime \(complexTime)")

        return try await withTaskCancellationHandler {
            try await readAdaptiveMove(
                quickTime: quickTime,
                normalTime: normalTime,
                complexTime: complexTime,
                onUpdate: onUpdate
            )
        } onCancel: {
            Task { await self.cancelCurrentSearch() }
        }
    }

    /// Requests a graceful stop. The active reader remains responsible for
    /// consuming the resulting `bestmove`, preventing stale UCI output from
    /// leaking into the next position.
    func cancelCurrentSearch() {
        stopRequestedExternally = true
        send("stop")
    }

    // MARK: Private I/O

    private func send(_ cmd: String) {
        guard let handle = stdinHandle else { return }
        guard let data = (cmd + "\n").data(using: .utf8) else { return }
        handle.write(data)
    }

    private func nextLine(timeout: TimeInterval) async throws -> String {
        guard let mailbox = lineMailbox else {
            throw EngineError.launchFailed("无输出流")
        }
        return try await mailbox.next(timeout: timeout)
    }

    private func waitFor(token: String, timeout: Double) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw EngineError.timeout }
            let line = try await nextLine(timeout: remaining)
            if line.contains(token) { return }
        }
    }

    /// Extracts a playable UCI token and treats the two UCI terminal sentinels
    /// as an explicit no-move result instead of allowing them to leak into the
    /// UI as malformed recommendations.
    private func bestMoveUCI(from line: String) throws -> String? {
        guard line.hasPrefix("bestmove") else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else {
            throw EngineError.launchFailed("引擎返回了不完整的 bestmove")
        }
        let token = String(parts[1])
        if token == "(none)" || token == "none" || token == "0000" {
            throw EngineError.noLegalMove
        }
        return token
    }

    private func readBestMove(timeout: Double) async throws -> EngineMove {
        var lastScore = 0
        var lastMate: Int?
        var lastDepth = 0
        var lastPV: [String] = []

        let searchDeadline = Date().addingTimeInterval(timeout)
        var drainDeadline: Date?
        while true {
            let now = Date()
            if drainDeadline == nil {
                if stopRequestedExternally {
                    // cancelCurrentSearch() already sent the UCI stop command.
                    drainDeadline = now.addingTimeInterval(2)
                } else if now >= searchDeadline {
                    send("stop")
                    drainDeadline = now.addingTimeInterval(2)
                }
            }

            let activeDeadline = drainDeadline ?? searchDeadline
            let remaining = activeDeadline.timeIntervalSinceNow
            guard remaining > 0 else { throw EngineError.timeout }

            let line: String
            do {
                line = try await nextLine(timeout: min(0.25, remaining))
            } catch EngineError.timeout {
                continue
            }

            if line.hasPrefix("info") {
                if let s = parseScore(from: line) {
                    lastScore = s.centipawns
                    lastMate = s.mateIn
                }
                if let d = parseDepth(from: line) { lastDepth = d }
                if let pv = parsePV(from: line)   { lastPV = pv }
            }
            if let bestMove = try bestMoveUCI(from: line) {
                return EngineMove(uci: bestMove,
                                  score: lastScore,
                                  mateIn: lastMate,
                                  depth: lastDepth,
                                  pv: lastPV)
            }
        }
    }

    private func readCandidateMoves(timeout: Double) async throws -> [EngineMove] {
        var latest: [Int: EngineMove] = [:]
        var finalBestMoveUCI: String?
        let searchDeadline = Date().addingTimeInterval(timeout)
        var drainDeadline: Date?
        while true {
            let now = Date()
            if drainDeadline == nil {
                if stopRequestedExternally {
                    drainDeadline = now.addingTimeInterval(2)
                } else if now >= searchDeadline {
                    send("stop")
                    drainDeadline = now.addingTimeInterval(2)
                }
            }

            let activeDeadline = drainDeadline ?? searchDeadline
            let remaining = activeDeadline.timeIntervalSinceNow
            guard remaining > 0 else { throw EngineError.timeout }

            let line: String
            do {
                line = try await nextLine(timeout: min(0.25, remaining))
            } catch EngineError.timeout {
                continue
            }

            if line.hasPrefix("info"),
               let pv = parsePV(from: line),
               let first = pv.first {
                let index = parseMultiPV(from: line) ?? 1
                let parsed = parseScore(from: line)
                latest[index] = EngineMove(
                    uci: first,
                    score: parsed?.centipawns ?? 0,
                    mateIn: parsed?.mateIn,
                    depth: parseDepth(from: line) ?? 0,
                    pv: pv
                )
            }
            if let parsedBestMove = try bestMoveUCI(from: line) {
                finalBestMoveUCI = parsedBestMove
                var ordered = latest.keys.sorted().compactMap { latest[$0] }
                if let finalBestMoveUCI,
                   let bestIndex = ordered.firstIndex(where: { $0.uci == finalBestMoveUCI }),
                   bestIndex != 0 {
                    let best = ordered.remove(at: bestIndex)
                    ordered.insert(best, at: 0)
                }
                if ordered.isEmpty, let finalBestMoveUCI {
                    ordered = [EngineMove(uci: finalBestMoveUCI, score: 0,
                                          mateIn: nil, depth: 0, pv: [])]
                }
                return ordered
            }
        }
    }

    private func readAdaptiveMove(
        quickTime: Int,
        normalTime: Int,
        complexTime: Int,
        onUpdate: @escaping (EngineSearchUpdate) -> Void
    ) async throws -> EngineMove {
        let startedAt = Date()
        var latest = EngineMove(uci: "", score: 0, mateIn: nil, depth: 0, pv: [])
        var quickPublished = false
        var deepeningPublished = false
        var regularDecisionMade = false
        var drainDeadline: Date?
        var cancelled = false
        var metrics = AdaptiveSearchPolicy.Metrics()

        while true {
            let now = Date()
            let elapsedMilliseconds = max(0, Int(now.timeIntervalSince(startedAt) * 1_000))

            if Task.isCancelled, drainDeadline == nil {
                cancelled = true
                send("stop")
                drainDeadline = now.addingTimeInterval(2)
            } else if stopRequestedExternally, drainDeadline == nil {
                // cancelCurrentSearch() already sent stop; keep reading until
                // bestmove so no stale line can contaminate the next position.
                drainDeadline = now.addingTimeInterval(2)
            }

            if !quickPublished,
               elapsedMilliseconds >= quickTime,
               !latest.uci.isEmpty {
                quickPublished = true
                onUpdate(EngineSearchUpdate(phase: .quick, move: latest))
            }

            if drainDeadline == nil,
               !regularDecisionMade,
               elapsedMilliseconds >= normalTime {
                regularDecisionMade = true
                if !latest.uci.isEmpty {
                    // Advance stability time even if Pikafish has not emitted a
                    // fresh info line exactly on the six-second boundary.
                    metrics.observe(move: latest, elapsedMilliseconds: elapsedMilliseconds)
                }
                if !latest.uci.isEmpty,
                   AdaptiveSearchPolicy.shouldExtend(metrics: metrics) {
                    if !deepeningPublished {
                        deepeningPublished = true
                        onUpdate(EngineSearchUpdate(phase: .deepening, move: latest))
                    }
                } else {
                    send("stop")
                    drainDeadline = now.addingTimeInterval(2)
                }
            }

            if drainDeadline == nil, elapsedMilliseconds >= complexTime {
                send("stop")
                drainDeadline = now.addingTimeInterval(2)
            }

            if let drainDeadline, drainDeadline <= now {
                // A missing bestmove means the UCI stream cannot be trusted for
                // the next position; the coordinator will restart the process.
                throw EngineError.timeout
            }

            let activeDeadline = drainDeadline
                ?? startedAt.addingTimeInterval(Double(complexTime) / 1_000.0)
            let remaining = max(0.001, activeDeadline.timeIntervalSinceNow)
            let line: String
            do {
                line = try await nextLine(timeout: min(0.25, remaining))
            } catch EngineError.timeout {
                continue
            }

            if line.hasPrefix("info"),
               let pv = parsePV(from: line),
               let first = pv.first {
                let parsed = parseScore(from: line)
                latest = EngineMove(
                    uci: first,
                    score: parsed?.centipawns ?? latest.score,
                    mateIn: parsed == nil ? latest.mateIn : parsed?.mateIn,
                    depth: parseDepth(from: line) ?? latest.depth,
                    pv: pv
                )
                metrics.observe(move: latest, elapsedMilliseconds: elapsedMilliseconds)
            }

            if let bestUCI = try bestMoveUCI(from: line) {
                if cancelled || Task.isCancelled { throw CancellationError() }
                if latest.uci != bestUCI {
                    latest = EngineMove(
                        uci: bestUCI,
                        score: latest.score,
                        mateIn: latest.mateIn,
                        depth: latest.depth,
                        pv: latest.pv.first == bestUCI ? latest.pv : [bestUCI]
                    )
                }
                guard !latest.uci.isEmpty else {
                    throw EngineError.launchFailed("引擎没有返回走法")
                }
                if !quickPublished {
                    onUpdate(EngineSearchUpdate(phase: .quick, move: latest))
                }
                onUpdate(EngineSearchUpdate(phase: .final, move: latest))
                return latest
            }
        }
    }

    // MARK: UCI Line Parsers

    nonisolated private func parseScore(from line: String) -> ParsedEngineScore? {
        if let r = line.range(of: "score cp ") {
            guard let score = Int(line[r.upperBound...].split(separator: " ").first ?? "") else {
                return nil
            }
            return ParsedEngineScore(centipawns: score, mateIn: nil)
        }
        if let r = line.range(of: "score mate "),
           let distance = Int(line[r.upperBound...].split(separator: " ").first ?? "") {
            let score = distance > 0 ? 100_000 - distance : -100_000 - distance
            return ParsedEngineScore(centipawns: score, mateIn: distance)
        }
        return nil
    }
    nonisolated private func parseDepth(from line: String) -> Int? {
        guard let r = line.range(of: "depth ") else { return nil }
        return Int(line[r.upperBound...].split(separator: " ").first ?? "")
    }
    nonisolated private func parsePV(from line: String) -> [String]? {
        guard let r = line.range(of: " pv ") else { return nil }
        return line[r.upperBound...].split(separator: " ").map(String.init)
    }
    nonisolated private func parseMultiPV(from line: String) -> Int? {
        guard let r = line.range(of: " multipv ") else { return nil }
        return Int(line[r.upperBound...].split(separator: " ").first ?? "")
    }

    // MARK: Path Resolution

    private static func findBinary(named name: String) throws -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Engine") { return url }
        if let url = Bundle.main.url(forResource: name, withExtension: nil) { return url }

        let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let direct = execDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XiangqiAssistant/Engine/\(name)")
        if FileManager.default.fileExists(atPath: support.path) { return support }

        throw name.hasSuffix(".nnue") ? EngineError.nnueNotFound : EngineError.binaryNotFound
    }
}

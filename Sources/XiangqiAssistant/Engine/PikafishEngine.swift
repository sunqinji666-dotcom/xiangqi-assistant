import Foundation

// MARK: - Data Types

struct EngineMove {
    let uci: String       // e.g. "h2e2"
    let score: Int        // centipawns from the side-to-move perspective
    let depth: Int
    let pv: [String]      // principal variation
}

enum EngineError: LocalizedError {
    case binaryNotFound
    case nnueNotFound
    case launchFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .binaryNotFound: return "找不到 pikafish-apple-silicon 引擎文件"
        case .nnueNotFound:   return "找不到 pikafish.nnue 权重文件"
        case .launchFailed(let msg): return "引擎启动失败: \(msg)"
        case .timeout:        return "引擎响应超时"
        }
    }
}

// MARK: - Engine Actor

/// Thread-safe Pikafish UCI engine wrapper using AsyncStream for non-blocking I/O.
actor PikafishEngine {

    // MARK: State
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var lineStream: AsyncStream<String>?
    private var lineContinuation: AsyncStream<String>.Continuation?
    private var isReady = false

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
        p.standardError  = Pipe()

        // Set up AsyncStream BEFORE launching the process
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String>(bufferingPolicy: .unbounded) { cont = $0 }
        lineStream = stream
        lineContinuation = cont

        // Wire stdout → AsyncStream using readabilityHandler (runs on a GCD thread)
        let handle = stdout.fileHandleForReading
        var buffer = ""
        handle.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            buffer += chunk
            // Yield complete lines
            while let nl = buffer.firstIndex(of: "\n") {
                let line = String(buffer[buffer.startIndex..<nl]).trimmingCharacters(in: .whitespaces)
                buffer.removeSubrange(buffer.startIndex...nl)
                if !line.isEmpty { cont.yield(line) }
            }
        }

        try p.run()
        process     = p
        stdinHandle = stdin.fileHandleForWriting

        // UCI handshake
        send("uci")
        try await waitFor(token: "uciok", timeout: 5)
        send("setoption name EvalFile value \(nnueURL.path)")
        send("setoption name Threads value \(StrengthProfile.engineThreads)")
        send("setoption name Hash value \(StrengthProfile.hashMegabytes)")
        send("isready")
        try await waitFor(token: "readyok", timeout: 5)

        isReady = true
    }

    func stop() {
        send("quit")
        if process?.isRunning == true {
            process?.terminate()
        }
        stdinHandle = nil
        process = nil
        lineContinuation?.finish()
        lineContinuation = nil
        lineStream = nil
        isReady = false
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
        count: Int = 6
    ) async throws -> [EngineMove] {
        guard isReady else { throw EngineError.launchFailed("引擎未就绪") }
        let pvCount = max(2, min(10, count))
        send("stop")
        if let movesFromStart {
            let suffix = movesFromStart.isEmpty ? "" : " moves \(movesFromStart.joined(separator: " "))"
            send("position startpos\(suffix)")
        } else {
            send("position fen \(fen)")
        }
        send("setoption name MultiPV value \(pvCount)")
        send("go movetime \(movetime)")
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

    // MARK: Private I/O

    private func send(_ cmd: String) {
        guard let handle = stdinHandle else { return }
        guard let data = (cmd + "\n").data(using: .utf8) else { return }
        handle.write(data)
    }

    private func nextLine() async throws -> String {
        guard let stream = lineStream else { throw EngineError.launchFailed("无输出流") }
        for await line in stream { return line }
        throw EngineError.launchFailed("引擎输出流已关闭")
    }

    private func waitFor(token: String, timeout: Double) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                // Token-reading task
                while true {
                    let line = try await self.nextLine()
                    if line.contains(token) { return }
                }
            }
            group.addTask {
                // Timeout task
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw EngineError.timeout
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func readBestMove(timeout: Double) async throws -> EngineMove {
        var lastScore = 0
        var lastDepth = 0
        var lastPV: [String] = []

        return try await withThrowingTaskGroup(of: EngineMove.self) { group in
            group.addTask {
                while true {
                    let line = try await self.nextLine()
                    if line.hasPrefix("info") {
                        if let s = self.parseScore(from: line) { lastScore = s }
                        if let d = self.parseDepth(from: line) { lastDepth = d }
                        if let pv = self.parsePV(from: line)   { lastPV = pv }
                    }
                    if line.hasPrefix("bestmove") {
                        let parts = line.split(separator: " ")
                        guard parts.count >= 2 else { continue }
                        return EngineMove(uci: String(parts[1]),
                                          score: lastScore,
                                          depth: lastDepth,
                                          pv: lastPV)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw EngineError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func readCandidateMoves(timeout: Double) async throws -> [EngineMove] {
        return try await withThrowingTaskGroup(of: [EngineMove].self) { group in
            group.addTask {
                var latest: [Int: EngineMove] = [:]
                var bestMoveUCI: String?
                while true {
                    let line = try await self.nextLine()
                    if line.hasPrefix("info"),
                       let pv = self.parsePV(from: line),
                       let first = pv.first {
                        let index = self.parseMultiPV(from: line) ?? 1
                        latest[index] = EngineMove(
                            uci: first,
                            score: self.parseScore(from: line) ?? 0,
                            depth: self.parseDepth(from: line) ?? 0,
                            pv: pv
                        )
                    }
                    if line.hasPrefix("bestmove") {
                        let parts = line.split(separator: " ")
                        if parts.count >= 2 { bestMoveUCI = String(parts[1]) }
                        var ordered = latest.keys.sorted().compactMap { latest[$0] }
                        if let bestMoveUCI,
                           let bestIndex = ordered.firstIndex(where: { $0.uci == bestMoveUCI }),
                           bestIndex != 0 {
                            let best = ordered.remove(at: bestIndex)
                            ordered.insert(best, at: 0)
                        }
                        if ordered.isEmpty, let bestMoveUCI {
                            ordered = [EngineMove(uci: bestMoveUCI, score: 0, depth: 0, pv: [])]
                        }
                        return ordered
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw EngineError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: UCI Line Parsers

    nonisolated private func parseScore(from line: String) -> Int? {
        if let r = line.range(of: "score cp ") {
            return Int(line[r.upperBound...].split(separator: " ").first ?? "")
        }
        if let r = line.range(of: "score mate "),
           let distance = Int(line[r.upperBound...].split(separator: " ").first ?? "") {
            return distance > 0 ? 100_000 - distance : -100_000 - distance
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

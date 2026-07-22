import Foundation

/// Resource and search budgets for the ultra-strength brain.
/// These values use about half of Jacksun's 10-core M1 Max while leaving
/// headroom for board recognition and the rest of macOS.
enum StrengthProfile {
    static let engineThreads = 5
    static let hashMegabytes = 512

    static let normalMoveTime = 2_000
    static let aggressiveMoveTime = 3_500
    static let aggressiveCandidates = 4
    static let ultraMoveTime = 6_000
    static let repetitionRecoveryMoveTime = 3_000
}

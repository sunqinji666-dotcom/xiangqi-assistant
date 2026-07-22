import Foundation

/// Resource and search budgets for the isolated strength experiment.
/// These values deliberately use about half of Jacksun's 10-core M1 Max,
/// leaving headroom for board recognition and the rest of macOS.
enum StrengthProfile {
    static let engineThreads = 5
    static let hashMegabytes = 512

    static let normalMoveTime = 2_000
    static let aggressiveMoveTime = 3_500
    static let aggressiveCandidates = 4
    static let quickAnswerTime = 2_000
    static let normalDeepTime = 6_000
    static let complexDeepTime = 15_000
    static let openingBookVerifyTime = 1_600
    static let openingBookCandidates = 4
    static let stableComparisonTime = 1_200
    static let stableScoreTolerance = 8
    static let openingBookTieTolerance = 5
    static let repetitionRecoveryMoveTime = 3_000
}

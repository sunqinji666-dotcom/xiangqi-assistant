import Foundation
import CoreGraphics

// MARK: - Calibration Manager
// Orchestrates the one-time calibration flow:
//   1. User opens their chess app and starts a NEW game (initial position)
//   2. User clicks "校准" in the floating panel
//   3. CalibrationManager captures a frame, detects the board, extracts cells,
//      then calls TemplateLibrary.calibrate() with the known initial layout.

@MainActor
class CalibrationManager: ObservableObject {

    enum CalibrationState {
        case notCalibrated
        case inProgress
        case success
        case failed(String)
    }

    @Published var state: CalibrationState = .notCalibrated

    private let captureManager: ScreenCaptureManager
    private let recognizer: BoardRecognizer
    private let library: TemplateLibrary

    init(captureManager: ScreenCaptureManager,
         recognizer: BoardRecognizer,
         library: TemplateLibrary) {
        self.captureManager = captureManager
        self.recognizer = recognizer
        self.library = library
        if library.isCalibrated { state = .success }
    }

    // MARK: Main Entry

    /// Call this when the user clicks "校准".
    /// The chess app must be showing the initial position at this moment.
    func performCalibration() async {
        state = .inProgress

        // 1. Capture the screen
        guard let image = await captureManager.captureFrame() else {
            state = .failed("屏幕截图失败，请检查屏幕录制权限")
            return
        }

        // 2. Locate and crop the board
        guard let (boardImage, cells) = await recognizer.extractBoardAndCells(from: image) else {
            state = .failed("未能找到棋盘。请确保棋盘完整显示在屏幕上，没有被其他窗口遮挡")
            return
        }

        // 3. Run calibration against the known initial position
        let knownState = BoardState.initialPosition()
        let success = library.calibrate(cells: cells, knownState: knownState)

        if success {
            state = .success
            print("[Calibration] ✅ 成功提取 \(knownState.pieceCount) 个棋子模板")
        } else {
            state = .failed("模板提取失败，格点图像可能质量太低")
        }
    }

    /// Reset calibration (user can redo it for a different chess app skin)
    func resetCalibration() {
        library.clearTemplates()
        state = .notCalibrated
    }
}

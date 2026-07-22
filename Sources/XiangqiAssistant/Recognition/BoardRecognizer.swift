import Foundation
import Vision
import CoreGraphics
import AppKit

// MARK: - Recognition Result

enum RecognitionStatus {
    case stable     // 连续帧一致，结果可信
    case pending    // 等待连续帧确认
    case unstable   // 前后帧差异过大，怀疑识别错误
    case invalid    // 合法性校验失败
}

struct RecognitionResult {
    let boardState: BoardState
    let boardRect: CGRect      // 棋盘在原图中的位置（normalized 0-1）
    let status: RecognitionStatus
    let confidence: Double     // 0.0 – 1.0
    /// True when the source application rendered Black's viewpoint at the
    /// bottom and the recognized layout was normalized for the engine.
    let isReversedForDisplay: Bool

    init(
        boardState: BoardState,
        boardRect: CGRect,
        status: RecognitionStatus,
        confidence: Double,
        isReversedForDisplay: Bool = false
    ) {
        self.boardState = boardState
        self.boardRect = boardRect
        self.status = status
        self.confidence = confidence
        self.isReversedForDisplay = isReversedForDisplay
    }
}

// MARK: - Board Recognizer

/// Detects the chess board in a CGImage and extracts piece positions.
/// Uses Vision for board location, then template matching for pieces.
class BoardRecognizer {

    // MARK: Configuration
    private let stableFramesRequired = 2
    private var recentResults: [BoardState] = []
    private let templateLibrary: TemplateLibrary
    private let theOneRecognizer: TheOneLayoutRecognizer?
    private let theOnePoseRecognizer: TheOnePoseRecognizer?
    private var calibratedBoardRect: CGRect?
    /// XQWizard has a stable two-column layout: board at left, score sheet at
    /// right. Its surrounding window chrome confuses generic locators.
    var preferredWindowBoardRect: CGRect?

    /// When set, Vision detection is skipped entirely — all recognition uses
    /// these fixed screen coordinates. Set by the drag-to-select calibrator.
    var boardGeometry: BoardGeometry?

    /// The window frame for the current capture source. Provided by AppDelegate
    /// so BoardRecognizer can convert screen coords to image coords.
    var captureWindowFrame: CGRect?

    init(library: TemplateLibrary? = nil) {
        self.templateLibrary = library ?? TemplateLibrary.load()
        // AppDelegate applies geometry only after it has matched the saved
        // rectangle to the selected capture source. Loading the legacy global
        // file here could briefly apply another application's crop.
        self.boardGeometry = nil
        self.theOneRecognizer = TheOneLayoutRecognizer()
        self.theOnePoseRecognizer = TheOnePoseRecognizer()
    }

    /// The bundled full-board model does not need the legacy per-piece
    /// template calibration step.
    var usesTheOneModel: Bool { theOneRecognizer != nil }

    /// Clear only observations learned from the previous capture source. The
    /// ONNX models, templates, thresholds, and saved compatible geometry are
    /// deliberately left untouched.
    func resetCaptureSourceState() {
        recentResults.removeAll(keepingCapacity: true)
        calibratedBoardRect = nil
        preferredWindowBoardRect = nil
        captureWindowFrame = nil
    }

    // MARK: Main Entry

    func recognize(image: CGImage) async -> RecognitionResult? {
        let boardRect: CGRect

        if let preferred = preferredWindowBoardRect {
            boardRect = preferred
        } else if let geo = boardGeometry,
           let windowFrame = captureWindowFrame,
           windowFrame.width > 0,
           let rect = geo.normalizedBoardRectIfValid(windowFrame: windowFrame) {
            // A selected window gives us a stable coordinate system. Prefer
            // its relative rectangle during startup and animation frames.
            boardRect = rect
        } else if let geo = boardGeometry,
                  let rect = geo.normalizedFullScreenRect() {
            // A manual selection is authoritative.  The old branch order ran
            // the pose model first, so a perfectly framed board still drifted
            // by a few pixels on every frame.
            boardRect = rect
        } else if captureWindowFrame != nil, let locked = calibratedBoardRect {
            // SCWindow screenshots keep the same normalized content geometry.
            // Once a valid board has established the crop, keep it locked so
            // move highlights and animations cannot move the crop.
            boardRect = locked
        } else if let autoRect = theOnePoseRecognizer?.boardRect(in: image) {
            boardRect = autoRect
        } else if let locked = calibratedBoardRect {
            boardRect = locked
        } else {
            guard let detected = await detectBoardRect(in: image) else { return nil }
            boardRect = detected
        }

        // Step 2: Crop and normalize the board region
        guard let boardImage = crop(image: image, to: boardRect) else {
            return nil
        }

        // Step 3: Prefer TheOne1006's full-board classifier. It recognizes the
        // complete 10x9 layout and red/black piece classes together, avoiding
        // the old per-cell Vision/template failure mode.
        if let model = theOneRecognizer,
           let prediction = model.recognize(boardImage: boardImage) {
            var chosenPrediction = prediction
            var chosenRect = boardRect

            // A saved rectangle is a useful anchor, not a permanent truth.
            // Responsive chess clients move/resize the board when sidebars or
            // the window size changes. If the pose locator finds a different
            // crop that also produces a structurally valid board, compare the
            // two complete-board predictions and use the stronger one.
            if boardGeometry != nil,
               let poseRect = theOnePoseRecognizer?.boardRect(in: image),
               rectDistance(poseRect, boardRect) > 0.01,
               let poseImage = crop(image: image, to: poseRect),
               let posePrediction = model.recognize(boardImage: poseImage),
               posePrediction.state.isValid,
               (!prediction.state.isValid
                    || (!posePrediction.state.sameLayout(as: prediction.state)
                        && posePrediction.confidence > prediction.confidence)) {
                chosenPrediction = posePrediction
                chosenRect = poseRect
            }

            let state = chosenPrediction.state
            if state.isValid {
                if captureWindowFrame != nil && boardGeometry == nil {
                    calibratedBoardRect = chosenRect
                }
                // TheOne's classifier returns the complete 90-point position.
                // A valid full-board prediction is passed to the session-level
                // tracker, which validates it against the last trusted board.
                recentResults.removeAll(keepingCapacity: true)
                recentResults.append(state)
                return RecognitionResult(
                    boardState: state,
                    boardRect: chosenRect,
                    status: .stable,
                    confidence: chosenPrediction.confidence,
                    isReversedForDisplay: chosenPrediction.wasReversed
                )
            }

            // A fixed crop can become stale after the game window is resized.
            // Retry pose localization before returning the invalid observation.
            if let poseRect = theOnePoseRecognizer?.boardRect(in: image),
               rectDistance(poseRect, boardRect) > 0.01,
               let poseImage = crop(image: image, to: poseRect),
               let retry = model.recognize(boardImage: poseImage),
               retry.state.isValid {
                if captureWindowFrame != nil && boardGeometry == nil {
                    calibratedBoardRect = poseRect
                }
                recentResults.removeAll(keepingCapacity: true)
                recentResults.append(retry.state)
                return RecognitionResult(boardState: retry.state, boardRect: poseRect,
                                         status: .stable, confidence: retry.confidence,
                                         isReversedForDisplay: retry.wasReversed)
            }

            // The pose model is fast, but XQWizard's surrounding wood frame,
            // score panel and blue last-move markers can make it lock onto a
            // non-board rectangle. When its classification is invalid, run
            // the geometrical rectangle detector as an independent second
            // locator and keep it only if the full-board model validates the
            // resulting Xiangqi position.
            if let visionRect = await detectBoardRect(in: image),
               rectDistance(visionRect, boardRect) > 0.01,
               let visionImage = crop(image: image, to: visionRect),
               let retry = model.recognize(boardImage: visionImage),
               retry.state.isValid {
                if captureWindowFrame != nil && boardGeometry == nil {
                    calibratedBoardRect = visionRect
                }
                recentResults.removeAll(keepingCapacity: true)
                recentResults.append(retry.state)
                return RecognitionResult(boardState: retry.state, boardRect: visionRect,
                                         status: .stable, confidence: retry.confidence,
                                         isReversedForDisplay: retry.wasReversed)
            }

            // Keep the raw 90-point observation.  The outer tracker can often
            // repair one or two highlighted/misclassified intersections by
            // matching it against legal successors of the trusted position.
            return RecognitionResult(boardState: state, boardRect: boardRect,
                                     status: .invalid, confidence: prediction.confidence,
                                     isReversedForDisplay: prediction.wasReversed)
        }

        // If a saved window-relative rectangle is stale (window moved or the
        // selector was made on a different display), retry once with the
        // model's own pose estimate before falling back to cell templates.
        // This keeps startup from being reported as unstable just because the
        // persisted rectangle no longer matches the current capture.
        if let model = theOneRecognizer,
           let poseRect = theOnePoseRecognizer?.boardRect(in: image),
           rectDistance(poseRect, boardRect) > 0.01,
           let poseImage = crop(image: image, to: poseRect),
           let prediction = model.recognize(boardImage: poseImage) {
            let state = prediction.state
            if state.isValid {
                recentResults.removeAll(keepingCapacity: true)
                recentResults.append(state)
                return RecognitionResult(boardState: state, boardRect: poseRect,
                                         status: .stable, confidence: prediction.confidence,
                                         isReversedForDisplay: prediction.wasReversed)
            }
        }

        // Fallback: legacy template path.
        // Step 4: Extract cell images (9 cols × 10 rows)
        let cells = extractCells(from: boardImage)

        // Step 5: Classify each cell
        let state = classifyCells(cells)

        // Step 6: Validity check
        guard state.isValid else {
            return RecognitionResult(
                boardState: state,
                boardRect: boardRect,
                status: .invalid,
                confidence: 0.0
            )
        }

        // Step 7: Temporal stability filter
        recentResults.append(state)
        if recentResults.count > stableFramesRequired {
            recentResults.removeFirst()
        }

        let status = determineStatus(current: state)
        let confidence = status == .stable ? 0.95 : 0.5

        return RecognitionResult(
            boardState: state,
            boardRect: boardRect,
            status: status,
            confidence: confidence
        )
    }

    // MARK: Board Detection (Vision)

    private func detectBoardRect(in image: CGImage) async -> CGRect? {
        return await withCheckedContinuation { continuation in
            let request = VNDetectRectanglesRequest { request, error in
                guard error == nil,
                      let results = request.results as? [VNRectangleObservation],
                      let best = results
                        .filter({
                            // Chinese chess board: 9 cols × 10 rows → aspect ≈ 0.9
                            // Reject anything clearly not a board shape
                            let aspect = $0.boundingBox.width / max($0.boundingBox.height, 0.0001)
                            return aspect >= 0.55 && aspect <= 1.20
                        })
                        .max(by: {
                            // Score = closeness to 9:10 ratio  ×  area
                            // This beats choosing by area alone (which picks the app window)
                            let targetAspect: CGFloat = 9.0 / 10.0
                            func score(_ obs: VNRectangleObservation) -> CGFloat {
                                let aspect = obs.boundingBox.width / max(obs.boundingBox.height, 0.0001)
                                let diff = abs(aspect - targetAspect) / targetAspect
                                let shapeFactor = max(0, 1 - diff * 4) // drops to 0 at 25% off target
                                return shapeFactor * obs.boundingBox.area
                            }
                            return score($0) < score($1)
                        })
                else {
                    continuation.resume(returning: nil)
                    return
                }
                // Vision returns normalized coords (0-1), y flipped
                let bb = best.boundingBox
                let flipped = CGRect(
                    x: bb.origin.x,
                    y: 1 - bb.origin.y - bb.height,
                    width: bb.width,
                    height: bb.height
                )
                continuation.resume(returning: flipped)
            }
            // Expect a roughly square board
            request.minimumAspectRatio = 0.7
            request.maximumAspectRatio = 1.3
            request.minimumSize = 0.1
            request.maximumObservations = 10

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
        }
    }

    // MARK: Cell Extraction

    private func crop(image: CGImage, to normalized: CGRect) -> CGImage? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let pixel = CGRect(
            x: normalized.minX * w,
            y: normalized.minY * h,
            width: normalized.width * w,
            height: normalized.height * h
        )
        return image.cropping(to: pixel)
    }


    private func extractCells(from boardImage: CGImage) -> [[CGImage?]] {
        let w = CGFloat(boardImage.width)
        let h = CGFloat(boardImage.height)
        // Xiangqi pieces sit on the 9×10 intersections, including the edges.
        // Using w/9 and h/10 puts every sample half a square away from the
        // actual intersection and is especially damaging for the edge rooks.
        let stepX = w / 8
        let stepY = h / 9
        let radius = min(stepX, stepY) * 0.36

        var cells: [[CGImage?]] = []
        for row in 0..<10 {
            var rowCells: [CGImage?] = []
            for col in 0..<9 {
                let cx = stepX * CGFloat(col)
                let cy = stepY * CGFloat(row)
                let rawRect = CGRect(
                    x: cx - radius, y: cy - radius,
                    width: radius * 2, height: radius * 2
                )
                rowCells.append(boardImage.cropping(to: rawRect.intersection(CGRect(x: 0, y: 0, width: w, height: h))))
            }
            cells.append(rowCells)
        }
        return cells
    }

    // MARK: Piece Classification

    private func classifyCells(_ cells: [[CGImage?]]) -> BoardState {
        var state = BoardState()
        for row in 0..<10 {
            for col in 0..<9 {
                guard let cell = cells[row][col] else { continue }
                state[col, row] = templateLibrary.classify(cell: cell)
            }
        }
        return state
    }

    // MARK: Temporal Stability

    private func determineStatus(current: BoardState) -> RecognitionStatus {
        guard recentResults.count >= stableFramesRequired else { return .pending }

        let allSame = recentResults.allSatisfy { $0 == current }
        if allSame { return .stable }

        // A real move changes at most two intersections.  The pose model can
        // move the crop by a few pixels between frames, so do not call that
        // visual jitter an unstable/abnormal position.
        if let prev = recentResults.dropLast().last {
            let delta = countDifferences(a: prev, b: current)
            if delta <= 2 || prev.isPlausibleSingleMove(to: current) {
                return .pending
            }
        }

        // Keep sampling until the same complete position is observed twice.
        // This avoids skipping a valid opponent move merely because one frame
        // was captured during an animation.
        return .pending
    }

    private func countDifferences(a: BoardState, b: BoardState) -> Int {
        var count = 0
        for row in 0..<10 {
            for col in 0..<9 {
                if a[col, row] != b[col, row] { count += 1 }
            }
        }
        return count
    }

    private func rectDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY),
            abs(a.width - b.width), abs(a.height - b.height))
    }

}

// MARK: - Public Calibration Helper

extension BoardRecognizer {
    /// Used by CalibrationManager: use the manually stored board geometry when
    /// available; otherwise fall back to Vision for first-time setup.
    func extractBoardAndCells(from image: CGImage) async -> (CGImage, [[CGImage?]])? {
        let boardRect: CGRect
        if let geo = boardGeometry,
           let windowFrame = captureWindowFrame,
           windowFrame.width > 0,
           let rect = geo.normalizedBoardRectIfValid(windowFrame: windowFrame) {
            boardRect = rect
        } else if let geo = boardGeometry,
                  let rect = geo.normalizedFullScreenRect() {
            boardRect = rect
        } else {
            guard let detected = await detectBoardRect(in: image) else { return nil }
            boardRect = detected
        }
        guard let boardImage = crop(image: image, to: boardRect) else { return nil }
        calibratedBoardRect = boardRect
        let cells = extractCells(from: boardImage)
        return (boardImage, cells)
    }
}

// MARK: - Helper

private extension CGRect {
    var area: CGFloat { width * height }
}

private extension BoardGeometry {
    func normalizedBoardRectIfValid(windowFrame: CGRect) -> CGRect? {
        let r = normalizedBoardRect(imageSize: .zero, windowFrame: windowFrame)
        guard r.minX >= 0, r.minY >= 0, r.maxX <= 1, r.maxY <= 1 else { return nil }
        return r
    }
}

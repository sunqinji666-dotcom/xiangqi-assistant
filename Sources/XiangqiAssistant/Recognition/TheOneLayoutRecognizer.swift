import Foundation
import CoreGraphics
import AppKit
import OnnxRuntimeBindings

/// TheOne1006's 10x9, 16-class Xiangqi layout model.
/// The model classifies the complete aligned board in one pass instead of
/// trying to read individual Chinese characters with generic Vision OCR.
final class TheOneLayoutRecognizer {
    private let env: ORTEnv
    private let session: ORTSession

    private let labels = [".", "x", "K", "A", "B", "N", "R", "C", "P",
                          "k", "a", "b", "n", "r", "c", "p"]

    init?() {
        let candidates = [
            Bundle.main.url(forResource: "layout_recognition", withExtension: "onnx"),
            Bundle.main.url(forResource: "layout_recognition", withExtension: "onnx",
                            subdirectory: "Recognition/TheOne1006")
        ].compactMap { $0 }
        guard let modelURL = candidates.first else { return nil }

        do {
            env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(2)
            if ORTIsCoreMLExecutionProviderAvailable() {
                let coreML = ORTCoreMLExecutionProviderOptions()
                coreML.enableOnSubgraphs = true
                // Some ONNX operators in this model are not supported by the
                // Core ML execution provider on every macOS release.  That
                // must not disable the recognizer; CPU execution is reliable
                // and still fast enough for one board per analysis frame.
                try? options.appendCoreMLExecutionProvider(with: coreML)
            }
            session = try ORTSession(env: env, modelPath: modelURL.path,
                                     sessionOptions: options)
        } catch {
            return nil
        }
    }

    func recognize(
        boardImage: CGImage
    ) -> (state: BoardState, confidence: Double, wasReversed: Bool)? {
        guard let data = makeInput(from: boardImage) else { return nil }

        do {
            let input = try ORTValue(tensorData: data,
                                     elementType: ORTTensorElementDataType.float,
                                     shape: [1, 3, 280, 315])
            let outputs = try session.run(withInputs: ["input": input],
                                           outputNames: ["output"],
                                           runOptions: nil)
            guard let output = outputs["output"] else { return nil }
            let tensor = try output.tensorData()

            let tensorData = tensor as Data
            let values = tensorData.withUnsafeBytes { raw -> [Float] in
                Array(raw.bindMemory(to: Float.self))
            }
            guard values.count >= 90 * 16 else { return nil }

            var state = BoardState()
            var totalConfidence = 0.0
            for index in 0..<90 {
                let start = index * 16
                let slice = values[start..<(start + 16)]
                let ranked = slice.enumerated()
                    .map { (offset: $0.offset, score: $0.element) }
                    .sorted { $0.score > $1.score }
                guard let best = ranked.first else {
                    return nil
                }
                totalConfidence += Double(best.score)
                apply(label: labels[best.offset], to: &state,
                      col: index % 9, row: index / 9)
            }
            // Do not turn an impossible raw observation into a superficially
            // legal board here.  A move marker can make the model keep the
            // old square, misread the new square's colour, and then choose a
            // low-confidence "repair" that deletes an unrelated real piece.
            // The session tracker has the last trusted position and can score
            // this raw observation against legal one/two-ply successors.  It
            // is therefore the only layer allowed to repair a moving game.
            let canonical = state.canonicalOrientation()
            return (
                canonical.state,
                totalConfidence / 90.0,
                canonical.wasReversed
            )
        } catch {
            return nil
        }
    }

    private func apply(label: String, to state: inout BoardState, col: Int, row: Int) {
        state[col, row] = piece(for: label)
    }

    private func piece(for label: String) -> Piece? {
        switch label {
        case "K": return Piece(kind: .king, side: .red)
        case "A": return Piece(kind: .advisor, side: .red)
        case "B": return Piece(kind: .bishop, side: .red)
        case "N": return Piece(kind: .knight, side: .red)
        case "R": return Piece(kind: .rook, side: .red)
        case "C": return Piece(kind: .cannon, side: .red)
        case "P": return Piece(kind: .pawn, side: .red)
        case "k": return Piece(kind: .king, side: .black)
        case "a": return Piece(kind: .advisor, side: .black)
        case "b": return Piece(kind: .bishop, side: .black)
        case "n": return Piece(kind: .knight, side: .black)
        case "r": return Piece(kind: .rook, side: .black)
        case "c": return Piece(kind: .cannon, side: .black)
        case "p": return Piece(kind: .pawn, side: .black)
        default: return nil
        }
    }

    private func makeInput(from image: CGImage) -> NSMutableData? {
        let width = 315
        let height = 280
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let mean: [Float] = [123.675, 116.28, 103.53]
        let std: [Float] = [58.395, 57.12, 57.375]
        var values = [Float](repeating: 0, count: 3 * width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = (y * width + x) * 4
                let dst = y * width + x
                values[dst] = (Float(pixels[p]) - mean[0]) / std[0]
                values[width * height + dst] = (Float(pixels[p + 1]) - mean[1]) / std[1]
                values[2 * width * height + dst] = (Float(pixels[p + 2]) - mean[2]) / std[2]
            }
        }
        return values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
    }
}

import Foundation
import Accelerate
import CoreGraphics

// MARK: - Template Library
// Stores one grayscale float-array template per Piece type.
// Calibration extracts templates from a known initial-position screenshot.
// Templates are persisted to ~/Library/Application Support/XiangqiAssistant/Templates/.

class TemplateLibrary {

    // MARK: Constants
    static let imageSize = 48                   // resize every cell to 48×48
    // The board texture is not flat wood: grain and grid lines create a
    // sizeable grayscale deviation even on empty intersections. Treat those
    // patches as background more aggressively, and require a stronger NCC
    // match before calling an empty patch a piece.
    private static let matchThreshold: Float = 0.78
    private static let emptyStdThreshold: Float = 0.12

    private static let templateDir: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XiangqiAssistant/Templates")
    }()

    // MARK: State
    private var templates: [Piece: [Float]] = [:]
    var isCalibrated: Bool { !templates.isEmpty }

    // MARK: Load

    static func load() -> TemplateLibrary {
        let lib = TemplateLibrary()
        lib.loadFromDisk()
        return lib
    }

    // MARK: Calibrate
    // Feed it the 10×9 cell images and the known ground-truth BoardState.
    // It averages multiple samples of the same piece type and saves to disk.

    func calibrate(cells: [[CGImage?]], knownState: BoardState) -> Bool {
        var samples: [Piece: [[Float]]] = [:]

        for row in 0..<10 {
            for col in 0..<9 {
                guard let piece = knownState[col, row],
                      let cell = cells[row][col],
                      let pixels = Self.toGrayscaleFloats(cell) else { continue }
                samples[piece, default: []].append(pixels)
            }
        }

        guard !samples.isEmpty else { return false }

        templates = [:]
        for (piece, pixelArrays) in samples {
            let n = pixelArrays[0].count
            var avg = [Float](repeating: 0, count: n)
            for px in pixelArrays {
                vDSP_vadd(avg, 1, px, 1, &avg, 1, vDSP_Length(n))
            }
            var divisor = Float(pixelArrays.count)
            vDSP_vsdiv(avg, 1, &divisor, &avg, 1, vDSP_Length(n))
            templates[piece] = avg
        }

        saveToDisk()
        return true
    }

    // MARK: Classify

    func classify(cell: CGImage) -> Piece? {
        guard isCalibrated,
              let pixels = Self.toGrayscaleFloats(cell) else { return nil }
        guard !isBoardBackground(pixels) else { return nil }

        var bestPiece: Piece?
        var bestScore: Float = Self.matchThreshold

        for (piece, tmpl) in templates {
            let score = ncc(pixels, tmpl)
            if score > bestScore {
                bestScore = score
                bestPiece = piece
            }
        }
        return bestPiece
    }

    // MARK: Disk persistence

    func clearTemplates() {
        templates = [:]
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: Self.templateDir, includingPropertiesForKeys: nil) {
            files.forEach { try? fm.removeItem(at: $0) }
        }
    }

    func saveToDisk() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.templateDir, withIntermediateDirectories: true)
        for (piece, pixels) in templates {
            let url = Self.templateDir.appendingPathComponent(filename(for: piece))
            let data = pixels.withUnsafeBytes { Data($0) }
            try? data.write(to: url)
        }
    }

    private func loadFromDisk() {
        for side in [PieceSide.red, .black] {
            for kind in PieceKind.allCases {
                let piece = Piece(kind: kind, side: side)
                let url = Self.templateDir.appendingPathComponent(filename(for: piece))
                guard let data = try? Data(contentsOf: url) else { continue }
                let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                guard !floats.isEmpty else { continue }
                templates[piece] = floats
            }
        }
    }

    private func filename(for piece: Piece) -> String {
        "\(piece.side == .red ? "r" : "b")_\(piece.kind.rawValue).bin"
    }

    // MARK: Empty-cell detection
    // If std-dev of pixel values is below threshold the cell is blank board background.

    private func isBoardBackground(_ pixels: [Float]) -> Bool {
        let n = vDSP_Length(pixels.count)
        var mean: Float = 0
        vDSP_meanv(pixels, 1, &mean, n)
        var variance: Float = 0
        var negMean = -mean
        var centered = [Float](repeating: 0, count: pixels.count)
        vDSP_vsadd(pixels, 1, &negMean, &centered, 1, n)
        vDSP_svesq(centered, 1, &variance, n)
        let std = sqrt(variance / Float(pixels.count))
        return std < Self.emptyStdThreshold
    }

    // MARK: Pixel utilities

    static func toGrayscaleFloats(_ image: CGImage) -> [Float]? {
        let size = imageSize
        var pixels = [UInt8](repeating: 0, count: size * size)
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &pixels,
            width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size,
            space: space,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
        return pixels.map { Float($0) / 255.0 }
    }
}

// MARK: - Normalised Cross-Correlation (vDSP)

private func ncc(_ a: [Float], _ b: [Float]) -> Float {
    let n = vDSP_Length(a.count)
    guard a.count == b.count, a.count > 0 else { return 0 }

    // Subtract means
    var meanA: Float = 0, meanB: Float = 0
    vDSP_meanv(a, 1, &meanA, n)
    vDSP_meanv(b, 1, &meanB, n)

    var negMeanA = -meanA, negMeanB = -meanB
    var ca = [Float](repeating: 0, count: a.count)
    var cb = [Float](repeating: 0, count: b.count)
    vDSP_vsadd(a, 1, &negMeanA, &ca, 1, n)
    vDSP_vsadd(b, 1, &negMeanB, &cb, 1, n)

    // Dot product
    var dot: Float = 0
    vDSP_dotpr(ca, 1, cb, 1, &dot, n)

    // Sum of squares
    var ssA: Float = 0, ssB: Float = 0
    vDSP_svesq(ca, 1, &ssA, n)
    vDSP_svesq(cb, 1, &ssB, n)

    let denom = sqrt(ssA * ssB)
    guard denom > 1e-6 else { return 0 }
    return dot / denom
}

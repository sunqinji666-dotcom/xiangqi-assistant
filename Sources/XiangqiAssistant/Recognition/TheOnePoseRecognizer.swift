import Foundation
import CoreGraphics
import OnnxRuntimeBindings

/// TheOne1006's four-corner board locator. It lets the board move or resize
/// without invalidating the manually selected screen rectangle.
final class TheOnePoseRecognizer {
    private let env: ORTEnv
    private let session: ORTSession

    init?() {
        let candidates = [
            Bundle.main.url(forResource: "pose", withExtension: "onnx"),
            Bundle.main.url(forResource: "pose", withExtension: "onnx",
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
                try? options.appendCoreMLExecutionProvider(with: coreML)
            }
            session = try ORTSession(env: env, modelPath: modelURL.path,
                                     sessionOptions: options)
        } catch {
            return nil
        }
    }

    func boardRect(in image: CGImage) -> CGRect? {
        let width = 256
        let height = 256
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

        do {
            let data = values.withUnsafeBytes {
                NSMutableData(bytes: $0.baseAddress!, length: $0.count)
            }
            let input = try ORTValue(tensorData: data,
                                     elementType: ORTTensorElementDataType.float,
                                     shape: [1, 3, 256, 256])
            let outputs = try session.run(withInputs: ["input": input],
                                          outputNames: ["simcc_x", "simcc_y"],
                                          runOptions: nil)
            guard let xValue = outputs["simcc_x"], let yValue = outputs["simcc_y"] else {
                return nil
            }
            let xData = try xValue.tensorData() as Data
            let yData = try yValue.tensorData() as Data
            let x = xData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let y = yData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard x.count >= 4 * 512, y.count >= 4 * 512 else { return nil }

            var points: [CGPoint] = []
            var confidence = 0.0
            for i in 0..<4 {
                let xs = x[(i * 512)..<(i * 512 + 512)]
                let ys = y[(i * 512)..<(i * 512 + 512)]
                guard let xBest = xs.enumerated().max(by: { $0.element < $1.element }),
                      let yBest = ys.enumerated().max(by: { $0.element < $1.element }) else {
                    return nil
                }
                points.append(CGPoint(x: CGFloat(xBest.offset) / 2,
                                      y: CGFloat(yBest.offset) / 2))
                confidence += Double(sqrt(max(0, xBest.element * yBest.element)))
            }
            guard confidence / 4.0 > 0.15 else { return nil }

            let imageWidth = CGFloat(image.width)
            let imageHeight = CGFloat(image.height)
            let minX = points.map(\.x).min()! / 256 * imageWidth
            let maxX = points.map(\.x).max()! / 256 * imageWidth
            let minY = points.map(\.y).min()! / 256 * imageHeight
            let maxY = points.map(\.y).max()! / 256 * imageHeight
            let padX = (maxX - minX) * 0.06
            let padY = (maxY - minY) * 0.06
            let rect = CGRect(x: max(0, minX - padX),
                              y: max(0, minY - padY),
                              width: min(imageWidth, maxX + padX) - max(0, minX - padX),
                              height: min(imageHeight, maxY + padY) - max(0, minY - padY))
            var normalized = CGRect(x: rect.minX / imageWidth,
                                    y: rect.minY / imageHeight,
                                    width: rect.width / imageWidth,
                                    height: rect.height / imageHeight)
            // The pose model is consistently a few pixels left of the final
            // layout model on XQWizard captures.  That clipped the rightmost
            // file and duplicated its pieces into neighbouring rows.  A small
            // content-relative bias keeps both edge files equally centred.
            let horizontalBias = min(0.008, max(0, 1 - normalized.maxX))
            normalized.origin.x += horizontalBias
            // Compare the real pixel dimensions. Comparing normalized width
            // and height made the answer depend on the containing window's
            // aspect ratio, so a perfectly normal board inside a wide game
            // window was incorrectly rejected as “too narrow”.
            let aspect = rect.width / max(rect.height, 0.001)
            guard aspect > 0.65, aspect < 1.15 else { return nil }
            return normalized
        } catch {
            return nil
        }
    }
}

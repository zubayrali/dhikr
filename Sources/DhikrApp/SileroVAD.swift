import CoreML
import Foundation
import DhikrCore

/// Streaming Silero VAD (16kHz) behind the DhikrCore VADScoring seam.
///
/// Official streaming contract (snakers4/silero-vad v6.x, verified against
/// ONNX and Sabbih's production pipeline): every 512-sample frame is scored as
/// a 576-sample input consisting of the previous 64 samples of context plus the
/// new frame. The recurrent state is one tensor [2,1,128] = (h,c), threaded
/// through every call. Both context and state must reset at session boundaries.
final class SileroVAD: VADScoring, @unchecked Sendable {

    enum SileroVADError: Error, CustomStringConvertible {
        case modelMissing(String)
        case predictionFailed(String)

        var description: String {
            switch self {
            case .modelMissing(let path): return "Silero VAD model not found at \(path)"
            case .predictionFailed(let message): return "Silero VAD prediction failed: \(message)"
            }
        }
    }

    static let frameSamples = 512
    static let contextSamples = 64
    static let inputSamples = frameSamples + contextSamples
    static let stateElementCount = 2 * 128

    private let model: MLModel
    private let inputArray: MLMultiArray
    private let stateArray: MLMultiArray
    private let inputProvider: MLDictionaryFeatureProvider

    private var context = [Float](repeating: 0, count: SileroVAD.contextSamples)
    private var state = [Float](repeating: 0, count: SileroVAD.stateElementCount)
    private var didLogPredictionError = false

    init(modelURL: URL) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw SileroVADError.modelMissing(modelURL.path)
        }
        let configuration = MLModelConfiguration()
        // The graph is tiny and dispatch-bound; CPU avoids offload latency and
        // keeps behavior deterministic across machines. Measured ~0.08ms/frame.
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        inputArray = try MLMultiArray(shape: [1, NSNumber(value: Self.inputSamples)], dataType: .float32)
        stateArray = try MLMultiArray(shape: [2, 1, 128], dataType: .float32)
        inputProvider = try MLDictionaryFeatureProvider(dictionary: [
            "input": MLFeatureValue(multiArray: inputArray),
            "state_in": MLFeatureValue(multiArray: stateArray),
        ])
    }

    convenience init(modelsDir: URL) throws {
        try self.init(modelURL: modelsDir.appendingPathComponent("SileroVAD.mlmodelc"))
    }

    static func bundled() throws -> SileroVAD {
        guard let resources = Bundle.main.resourceURL else {
            throw SileroVADError.modelMissing("app bundle resources")
        }
        return try SileroVAD(modelsDir: resources.appendingPathComponent("Models"))
    }

    /// Streaming state is session-scoped. Without this reset, the tail end of
    /// one recitation leaks into the first frames of the next session.
    func reset() {
        context.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        state.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
    }

    /// Score one 512-sample frame. The protocol fixes the frame size; short input
    /// is zero-padded rather than treated as a programmer fatal error because a
    /// partial flush must never take down live capture.
    func score(frame: [Float]) -> Float {
        let inputPointer = floatPointer(inputArray)

        for i in 0..<Self.contextSamples {
            inputPointer[i] = context[i]
        }
        for i in 0..<Self.frameSamples {
            inputPointer[Self.contextSamples + i] = i < frame.count ? frame[i] : 0
        }

        let stateInputPointer = floatPointer(stateArray)
        state.withUnsafeBufferPointer { source in
            stateInputPointer.update(from: source.baseAddress!, count: Self.stateElementCount)
        }

        // CoreML prediction output objects are autoreleased ObjC objects. A
        // 10-minute session is ~19k predictions; without an explicit drain the
        // IOSurface-backed output buffers accumulate until CoreML aborts the
        // process (observed in the long-session replay). Copy everything we need
        // into Swift storage inside the pool and return only a Float.
        return autoreleasepool { () -> Float in
            let prediction: MLFeatureProvider
            do {
                prediction = try model.prediction(from: inputProvider)
            } catch {
                if !didLogPredictionError {
                    NSLog("Silero VAD prediction failed: \(error.localizedDescription)")
                    didLogPredictionError = true
                }
                return 0
            }

            guard let outputArray = prediction.featureValue(for: "output")?.multiArrayValue,
                  let nextStateArray = prediction.featureValue(for: "stateN")?.multiArrayValue else {
                if !didLogPredictionError {
                    NSLog("Silero VAD prediction missing output/stateN features")
                    didLogPredictionError = true
                }
                return 0
            }

            let nextStatePointer = floatPointer(nextStateArray)
            for i in 0..<Self.stateElementCount {
                state[i] = nextStatePointer[i]
            }

            // The next context is the tail of the exact model input — for a full
            // frame, simply the last 64 samples of the newly scored audio.
            for i in 0..<Self.contextSamples {
                context[i] = inputPointer[Self.inputSamples - Self.contextSamples + i]
            }

            let probability = floatPointer(outputArray)[0]
            return min(1, max(0, probability))
        }
    }
}

private func floatPointer(_ array: MLMultiArray) -> UnsafeMutablePointer<Float> {
    array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
}

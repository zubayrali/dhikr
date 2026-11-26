import CoreML
import Foundation
import DhikrCore

/// On-device Arabic ASR: Nawah-60M parakeet-TDT on CoreML/ANE.
/// Adapted from the proven eval pipeline (eval/nawah-coreml/swift-cli/main.swift) —
/// segments arrive pre-cut to <=15s by the SpeechSegmenter, so no chunking here.
/// All calls are serialized by the recognizer's inference chain; models are not thread-safe.
final class NawahCoreMLTranscriber: SegmentTranscriber, @unchecked Sendable {

    enum TranscriberError: Error, CustomStringConvertible {
        case modelsMissing(String)
        case segmentTooLong(Int)
        var description: String {
            switch self {
            case .modelsMissing(let d): return "Model artifacts not found in \(d)"
            case .segmentTooLong(let n): return "segment \(n) samples exceeds preprocessor window"
            }
        }
    }

    private let preprocessor: MLModel
    private let encoder: MLModel
    private let fused: MLModel
    private let vocab: [Int: String]

    // persistent buffers (reused across calls — serialized access only)
    private let audioArr: MLMultiArray
    private let audioLenArr: MLMultiArray
    private let melLenArr: MLMultiArray
    private let targetsArr: MLMultiArray
    private let targetLenArr: MLMultiArray
    private let hInArr: MLMultiArray
    private let cInArr: MLMultiArray
    private let encStepArr: MLMultiArray
    private let fusedIn: MLDictionaryFeatureProvider

    static let windowSamples = 240240

    init(modelsDir: URL) throws {
        func load(_ name: String) throws -> MLModel {
            let url = modelsDir.appendingPathComponent("\(name).mlmodelc")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw TranscriberError.modelsMissing(modelsDir.path)
            }
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .cpuAndNeuralEngine
            return try MLModel(contentsOf: url, configuration: cfg)
        }
        preprocessor = try load("Preprocessor")
        encoder = try load("Encoder")
        fused = try load("DecoderJoint")

        let vocabURL = modelsDir.appendingPathComponent("parakeet_vocab.json")
        let vocabData = try Data(contentsOf: vocabURL)
        let vocabRaw = try JSONSerialization.jsonObject(with: vocabData) as! [String: String]
        var v: [Int: String] = [:]
        for (k, val) in vocabRaw { v[Int(k)!] = val }
        vocab = v

        audioArr = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples)], dataType: .float32)
        audioLenArr = try MLMultiArray(shape: [1], dataType: .int32)
        melLenArr = try MLMultiArray(shape: [1], dataType: .int32)
        targetsArr = try MLMultiArray(shape: [1, 1], dataType: .int32)
        targetLenArr = try MLMultiArray(shape: [1], dataType: .int32)
        hInArr = try MLMultiArray(shape: [2, 1, 320], dataType: .float32)
        cInArr = try MLMultiArray(shape: [2, 1, 320], dataType: .float32)
        encStepArr = try MLMultiArray(shape: [1, 384, 1], dataType: .float32)
        intPtr(targetLenArr)[0] = 1
        fusedIn = try MLDictionaryFeatureProvider(dictionary: [
            "targets": MLFeatureValue(multiArray: targetsArr),
            "target_length": MLFeatureValue(multiArray: targetLenArr),
            "h_in": MLFeatureValue(multiArray: hInArr),
            "c_in": MLFeatureValue(multiArray: cInArr),
            "encoder_step": MLFeatureValue(multiArray: encStepArr),
        ])
    }

    /// Default location: models inside the app bundle Resources.
    static func bundled() throws -> NawahCoreMLTranscriber {
        let dir = Bundle.main.resourceURL!.appendingPathComponent("Models")
        return try NawahCoreMLTranscriber(modelsDir: dir)
    }

    func transcribe(samples: [Float]) async throws -> String {
        guard samples.count <= Self.windowSamples - 256 else {
            throw TranscriberError.segmentTooLong(samples.count)
        }
        return try transcribeSync(samples: samples)
    }

    private func transcribeSync(samples: [Float]) throws -> String {
        // pack audio with kaldi reflection fill
        let audioBufPtr = floatPtr(audioArr)
        let L = samples.count
        audioBufPtr.assign(repeating: 0, count: Self.windowSamples)
        for i in 0..<L { audioBufPtr[i] = samples[i] }
        let depth = min(256, L, Self.windowSamples - L)
        for k in 0..<depth { audioBufPtr[L + k] = samples[L - 1 - k] }
        intPtr(audioLenArr)[0] = Int32(L)

        // preprocessor → mel
        let ppIn = try MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: audioArr),
            "audio_length": MLFeatureValue(multiArray: audioLenArr),
        ])
        let ppOut = try preprocessor.prediction(from: ppIn)
        let melArr = ppOut.featureValue(for: "mel")!.multiArrayValue!
        let melLen = ppOut.featureValue(for: "mel_length")!.multiArrayValue!
        intPtr(melLenArr)[0] = intPtr(melLen)[0]

        // encoder → frames
        let encIn = try MLDictionaryFeatureProvider(dictionary: [
            "mel": MLFeatureValue(multiArray: melArr),
            "mel_length": MLFeatureValue(multiArray: melLenArr),
        ])
        let encOut = try encoder.prediction(from: encIn)
        let encArr = encOut.featureValue(for: "encoder")!.multiArrayValue!
        let encLenArrV = encOut.featureValue(for: "encoder_length")!.multiArrayValue!
        let T = Int(intPtr(encLenArrV)[0])

        // transpose [1, 384, 188] → contiguous per-frame rows (padded strides!)
        let encPtr = floatPtr(encArr)
        let strideC = encArr.strides[1].intValue
        let strideT = encArr.strides[2].intValue
        var frames = [Float](repeating: 0, count: 188 * 384)
        for t in 0..<188 {
            for ch in 0..<384 {
                frames[t * 384 + ch] = encPtr[ch * strideC + t * strideT]
            }
        }

        // greedy TDT decode
        var token: Int32 = 0
        var hState = [Float](repeating: 0, count: 640)
        var cState = [Float](repeating: 0, count: 640)
        var outIds: [Int] = []
        var t = 0
        var sym = 0
        var steps = 0
        let hInP = floatPtr(hInArr), cInP = floatPtr(cInArr)
        let encStepP = floatPtr(encStepArr)
        let targetsP = intPtr(targetsArr)

        while t < T {
            targetsP[0] = token
            hState.withUnsafeBufferPointer { src in hInP.assign(from: src.baseAddress!, count: 640) }
            cState.withUnsafeBufferPointer { src in cInP.assign(from: src.baseAddress!, count: 640) }
            frames.withUnsafeBufferPointer { src in encStepP.assign(from: src.baseAddress! + t * 384, count: 384) }

            let stepOut = try fused.prediction(from: fusedIn)
            let k = Int(intPtr(stepOut.featureValue(for: "token_id")!.multiArrayValue!)[0])
            let d = Int(intPtr(stepOut.featureValue(for: "duration")!.multiArrayValue!)[0])

            if k == 0 {
                t += max(d, 1)
                sym = 0
            } else {
                outIds.append(k)
                let hOutP = floatPtr(stepOut.featureValue(for: "h_out")!.multiArrayValue!)
                let cOutP = floatPtr(stepOut.featureValue(for: "c_out")!.multiArrayValue!)
                for i in 0..<640 { hState[i] = hOutP[i]; cState[i] = cOutP[i] }
                token = Int32(k)
                sym += 1
                t += d
                if d == 0 && sym >= 10 {
                    t += 1
                    sym = 0
                }
            }
            steps += 1
            if steps > 5000 { break }
        }

        // detokenize: concatenate pieces, ▁ → space
        var text = ""
        for id in outIds where id != 0 {
            text += vocab[id] ?? ""
        }
        return text.replacingOccurrences(of: "▁", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

private func floatPtr(_ arr: MLMultiArray) -> UnsafeMutablePointer<Float> {
    arr.dataPointer.bindMemory(to: Float.self, capacity: arr.count)
}

private func intPtr(_ arr: MLMultiArray) -> UnsafeMutablePointer<Int32> {
    arr.dataPointer.bindMemory(to: Int32.self, capacity: arr.count)
}

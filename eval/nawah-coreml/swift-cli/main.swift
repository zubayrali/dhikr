// nawah-asr — end-to-end Arabic ASR proof: CoreML Nawah-ASR-60M-Max-Arabic greedy TDT decode.
//
// Usage:
//   nawah-asr <wav-file> [--models <dir>] [--fp32] [--json] [--max-seconds 14]
//
// Pipeline: WAV -> quietest-point chunking (<= maxSeconds) -> Preprocessor.mlmodelc (kaldi fbank)
//           -> Encoder.mlmodelc (FastConformer, fixed 15 s window, length-masked)
//           -> greedy TDT loop with DecoderJoint.mlmodelc (fused LSTM predictor + joiner decision)
//           -> BPE pieces joined, U+2581 replaced by space.
//
// Build: swiftc -O -o nawah-asr main.swift -framework CoreML -framework Accelerate
import CoreML
import Foundation
import Accelerate

// MARK: - Configuration

struct Config {
    var wavPath: String = ""
    var modelsDir: String = "../build/compiled"
    var useFp32Encoder: Bool = false
    var jsonOut: Bool = false
    var maxSeconds: Double = 14.0
}

func parseArgs() -> Config {
    var cfg = Config()
    var args = CommandLine.arguments.dropFirst()
    while let arg = args.popFirst() {
        switch arg {
        case "--models": cfg.modelsDir = args.popFirst() ?? cfg.modelsDir
        case "--fp32": cfg.useFp32Encoder = true
        case "--json": cfg.jsonOut = true
        case "--max-seconds": cfg.maxSeconds = Double(args.popFirst() ?? "14") ?? 14.0
        default:
            if !arg.hasPrefix("--") { cfg.wavPath = arg }
        }
    }
    return cfg
}

// MARK: - WAV loading

enum WavError: Error, CustomStringConvertible {
    case notRiff, noFmt, noData, unsupported(String), badRate(Int)
    var description: String {
        switch self {
        case .notRiff: return "not a RIFF/WAVE file"
        case .noFmt: return "no fmt chunk"
        case .noData: return "no data chunk"
        case .unsupported(let s): return "unsupported: \(s)"
        case .badRate(let r): return "sample rate \(r) != 16000 (no resampling in this CLI)"
        }
    }
}

/// Minimal WAV reader: PCM int16/int32 and IEEE float32, mono or stereo (downmixed). Returns float32 in [-1, 1].
func loadWav(_ path: String) throws -> [Float] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.count > 44, data.prefix(4).elementsEqual([0x52, 0x49, 0x46, 0x46]) else { throw WavError.notRiff }
    var offset = 12
    var audioFormat: UInt16 = 0, channels: UInt16 = 0, bitsPerSample: UInt16 = 0
    var sampleRate: UInt32 = 0
    var dataRange: Range<Int>?
    var sawFmt = false
    while offset + 8 <= data.count {
        let chunkId = data[offset..<(offset + 4)]
        let chunkSize = Int(readU32(data, offset + 4))
        let bodyStart = offset + 8
        if chunkId.elementsEqual([0x66, 0x6D, 0x74, 0x20]) { // "fmt "
            audioFormat = readU16(data, bodyStart)
            channels = readU16(data, bodyStart + 2)
            sampleRate = readU32(data, bodyStart + 4)
            bitsPerSample = readU16(data, bodyStart + 14)
            sawFmt = true
        } else if chunkId.elementsEqual([0x64, 0x61, 0x74, 0x61]) { // "data"
            dataRange = bodyStart..<min(bodyStart + chunkSize, data.count)
        }
        offset = bodyStart + chunkSize + (chunkSize & 1)
    }
    guard sawFmt else { throw WavError.noFmt }
    guard let range = dataRange else { throw WavError.noData }
    guard sampleRate == 16000 else { throw WavError.badRate(Int(sampleRate)) }

    let ch = Int(channels)
    var frames: [Float]
    switch (audioFormat, bitsPerSample) {
    case (1, 16):
        let n = (range.upperBound - range.lowerBound) / 2
        frames = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            let p = raw.baseAddress!.advanced(by: range.lowerBound).bindMemory(to: Int16.self, capacity: n)
            for i in 0..<n { frames[i] = Float(p[i]) / 32768.0 }
        }
    case (1, 32):
        let n = (range.upperBound - range.lowerBound) / 4
        frames = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            let p = raw.baseAddress!.advanced(by: range.lowerBound).bindMemory(to: Int32.self, capacity: n)
            for i in 0..<n { frames[i] = Float(p[i]) / 2147483648.0 }
        }
    case (3, 32):
        let n = (range.upperBound - range.lowerBound) / 4
        frames = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            let p = raw.baseAddress!.advanced(by: range.lowerBound).bindMemory(to: Float.self, capacity: n)
            for i in 0..<n { frames[i] = p[i] }
        }
    default:
        throw WavError.unsupported("format \(audioFormat)/\(bitsPerSample)bit")
    }
    if ch == 2 {
        let n = frames.count / 2
        var mono = [Float](repeating: 0, count: n)
        for i in 0..<n { mono[i] = 0.5 * (frames[2 * i] + frames[2 * i + 1]) }
        return mono
    } else if ch != 1 {
        throw WavError.unsupported("\(ch) channels")
    }
    return frames
}

func readU16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[o]) | (UInt16(d[o + 1]) << 8) }
func readU32(_ d: Data, _ o: Int) -> UInt32 {
    UInt32(d[o]) | (UInt32(d[o + 1]) << 8) | (UInt32(d[o + 2]) << 16) | (UInt32(d[o + 3]) << 24)
}

// MARK: - Segmentation (quietest-point chunking)

/// Split audio into chunks of at most maxSeconds at the quietest available points.
/// RMS per 512-sample frame, smoothed over 5 frames; split search in [pos+4s, pos+maxSeconds].
func chunkAudio(_ samples: [Float], maxSeconds: Double) -> [(Int, Int)] {
    let maxLen = Int(maxSeconds * 16000)
    if samples.count <= maxLen { return [(0, samples.count)] }
    let frameLen = 512
    let nFrames = samples.count / frameLen
    guard nFrames > 0 else { return [(0, samples.count)] }
    var rms = [Float](repeating: 0, count: nFrames)
    samples.withUnsafeBufferPointer { buf in
        for f in 0..<nFrames {
            var sq: Float = 0
            vDSP_measqv(buf.baseAddress! + f * frameLen, 1, &sq, vDSP_Length(frameLen))
            rms[f] = sqrtf(sq)
        }
    }
    // 5-frame moving average smoothing
    var smooth = [Float](repeating: 0, count: nFrames)
    for f in 0..<nFrames {
        var s: Float = 0
        var n = 0
        for k in -2...2 {
            let j = f + k
            if j >= 0 && j < nFrames { s += rms[j]; n += 1 }
        }
        smooth[f] = s / Float(n)
    }

    var chunks: [(Int, Int)] = []
    var pos = 0
    while samples.count - pos > maxLen {
        let searchStartFrame = min((pos + 4 * 16000) / frameLen, nFrames - 1)
        let searchEndFrame = min((pos + maxLen) / frameLen, nFrames)
        var bestFrame = searchStartFrame
        var bestVal: Float = .greatestFiniteMagnitude
        if searchStartFrame < searchEndFrame {
            for f in searchStartFrame..<searchEndFrame where smooth[f] < bestVal {
                bestVal = smooth[f]
                bestFrame = f
            }
        }
        var split = bestFrame * frameLen + frameLen / 2
        if split <= pos + 16000 { split = pos + maxLen } // ensure progress
        chunks.append((pos, min(split, samples.count)))
        pos = split
    }
    if pos < samples.count { chunks.append((pos, samples.count)) }
    return chunks
}

// MARK: - Audio packing (kaldi reflection fill)

/// Copy segment into the fixed preprocessor buffer with kaldi snip_edges=False-style
/// reflection: buf[L+k] = seg[L-1-k] for k in [0, min(256, L, 240240-L)).
func packAudio(_ seg: UnsafeBufferPointer<Float>, into buf: UnsafeMutableBufferPointer<Float>) -> Int {
    let L = seg.count
    buf.baseAddress!.assign(repeating: 0, count: buf.count)
    for i in 0..<L { buf[i] = seg[i] }
    let depth = min(256, L, buf.count - L)
    for k in 0..<depth { buf[L + k] = seg[L - 1 - k] }
    return L
}

// MARK: - CoreML helpers

func makeFloatArray(_ shape: [NSNumber]) -> MLMultiArray {
    try! MLMultiArray(shape: shape, dataType: .float32)
}

func floatPtr(_ arr: MLMultiArray) -> UnsafeMutablePointer<Float> {
    arr.dataPointer.bindMemory(to: Float.self, capacity: arr.count)
}

func intPtr(_ arr: MLMultiArray) -> UnsafeMutablePointer<Int32> {
    arr.dataPointer.bindMemory(to: Int32.self, capacity: arr.count)
}

// MARK: - Main pipeline

func main() {
    let cfg = parseArgs()
    guard !cfg.wavPath.isEmpty else {
        FileHandle.standardError.write("usage: nawah-asr <wav-file> [--models dir] [--fp32] [--json] [--max-seconds 14]\n".data(using: .utf8)!)
        exit(2)
    }
    let samples: [Float]
    do {
        samples = try loadWav(cfg.wavPath)
    } catch {
        FileHandle.standardError.write("error loading wav: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    let audioSeconds = Double(samples.count) / 16000.0

    let tLoad0 = CFAbsoluteTimeGetCurrent()
    let dir = cfg.modelsDir
    let mlcfg = MLModelConfiguration()
    mlcfg.computeUnits = .cpuAndNeuralEngine

    let ppURL = URL(fileURLWithPath: "\(dir)/Preprocessor.mlmodelc")
    let encURL = URL(fileURLWithPath: cfg.useFp32Encoder ? "\(dir)/Encoder_fp32.mlmodelc" : "\(dir)/Encoder.mlmodelc")
    let fusedURL = URL(fileURLWithPath: "\(dir)/DecoderJoint.mlmodelc")
    do {
        // Preprocessor is CPU-only territory but fine either way; keep default units.
        let preprocessor = try MLModel(contentsOf: ppURL, configuration: mlcfg)
        let encoder = try MLModel(contentsOf: encURL, configuration: mlcfg)
        let fused = try MLModel(contentsOf: fusedURL, configuration: mlcfg)
        let loadMs = (CFAbsoluteTimeGetCurrent() - tLoad0) * 1000

        // vocab
        let vocabData = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/../parakeet_vocab.json"))
        let vocabRaw = try JSONSerialization.jsonObject(with: vocabData) as! [String: String]
        var vocab: [Int: String] = [:]
        for (k, v) in vocabRaw { vocab[Int(k)!] = v }

        // persistent buffers / arrays
        let audioArr = makeFloatArray([1, 240240])
        let audioLenArr = try! MLMultiArray(shape: [1], dataType: .int32)
        let melLenArr = try! MLMultiArray(shape: [1], dataType: .int32)
        let targetsArr = try! MLMultiArray(shape: [1, 1], dataType: .int32)
        let targetLenArr = try! MLMultiArray(shape: [1], dataType: .int32)
        let hInArr = makeFloatArray([2, 1, 320])
        let cInArr = makeFloatArray([2, 1, 320])
        let encStepArr = makeFloatArray([1, 384, 1])
        intPtr(targetLenArr)[0] = 1

        let audioBufPtr = floatPtr(audioArr)
        let audioBuf = UnsafeMutableBufferPointer(start: audioBufPtr, count: 240240)

        // segmentation
        let chunks = chunkAudio(samples, maxSeconds: cfg.maxSeconds)

        var fullTextParts: [String] = []
        var totalInferMs: Double = 0
        var segmentReports: [[String: Any]] = []

        for (ci, chunk) in chunks.enumerated() {
            let (cstart, cend) = chunk
            let segLen = cend - cstart
            let t0 = CFAbsoluteTimeGetCurrent()

            // ---- pack audio
            var segCopy = [Float](repeating: 0, count: segLen)
            samples.withUnsafeBufferPointer { src in
                for i in 0..<segLen { segCopy[i] = src[cstart + i] }
            }
            let L = segCopy.withUnsafeBufferPointer { packAudio($0, into: audioBuf) }
            intPtr(audioLenArr)[0] = Int32(L)

            // ---- preprocessor
            let ppIn = try! MLDictionaryFeatureProvider(dictionary: [
                "audio_signal": MLFeatureValue(multiArray: audioArr),
                "audio_length": MLFeatureValue(multiArray: audioLenArr),
            ])
            let ppOut = try preprocessor.prediction(from: ppIn)
            let melArr = ppOut.featureValue(for: "mel")!.multiArrayValue!
            let melLen = ppOut.featureValue(for: "mel_length")!.multiArrayValue!
            intPtr(melLenArr)[0] = intPtr(melLen)[0]

            // ---- encoder
            let encIn = try! MLDictionaryFeatureProvider(dictionary: [
                "mel": MLFeatureValue(multiArray: melArr),
                "mel_length": MLFeatureValue(multiArray: melLenArr),
            ])
            let encOut = try encoder.prediction(from: encIn)
            let encArr = encOut.featureValue(for: "encoder")!.multiArrayValue!
            let encLenArrV = encOut.featureValue(for: "encoder_length")!.multiArrayValue!
            let T = Int(intPtr(encLenArrV)[0])

            // transpose encoder output [1, 384, 188] -> frames [188][384] contiguous rows.
            // NB: CoreML multiarrays use padded strides (e.g. channel stride 192 != 188),
            // so indexing must go through the actual strides.
            let encPtr = floatPtr(encArr)
            let strideC = encArr.strides[1].intValue
            let strideT = encArr.strides[2].intValue
            var frames = [Float](repeating: 0, count: 188 * 384)
            for t in 0..<188 {
                for ch in 0..<384 {
                    frames[t * 384 + ch] = encPtr[ch * strideC + t * strideT]
                }
            }

            // ---- greedy TDT decode with fused decoder+joint
            var token: Int32 = 0 // blank
            var hState = [Float](repeating: 0, count: 640)
            var cState = [Float](repeating: 0, count: 640)
            var outIds: [Int] = []
            var t = 0
            var sym = 0
            var steps = 0
            let hInP = floatPtr(hInArr), cInP = floatPtr(cInArr)
            let encStepP = floatPtr(encStepArr)
            let targetsP = intPtr(targetsArr)

            let fusedIn = try! MLDictionaryFeatureProvider(dictionary: [
                "targets": MLFeatureValue(multiArray: targetsArr),
                "target_length": MLFeatureValue(multiArray: targetLenArr),
                "h_in": MLFeatureValue(multiArray: hInArr),
                "c_in": MLFeatureValue(multiArray: cInArr),
                "encoder_step": MLFeatureValue(multiArray: encStepArr),
            ])

            while t < T {
                targetsP[0] = token
                hState.withUnsafeBufferPointer { src in hInP.assign(from: src.baseAddress!, count: 640) }
                cState.withUnsafeBufferPointer { src in cInP.assign(from: src.baseAddress!, count: 640) }
                frames.withUnsafeBufferPointer { src in encStepP.assign(from: src.baseAddress! + t * 384, count: 384) }

                let stepOut = try fused.prediction(from: fusedIn)
                let tidArr = stepOut.featureValue(for: "token_id")!.multiArrayValue!
                let durArr = stepOut.featureValue(for: "duration")!.multiArrayValue!
                let k = Int(intPtr(tidArr)[0])
                let d = Int(intPtr(durArr)[0])

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

            // ---- detokenize
            var text = ""
            for id in outIds where id != 0 {
                text += vocab[id] ?? ""
            }
            text = text.replacingOccurrences(of: "▁", with: " ")
            text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)

            let dtMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            totalInferMs += dtMs
            if !text.isEmpty { fullTextParts.append(text) }
            segmentReports.append([
                "index": ci,
                "start_sample": cstart,
                "end_sample": cend,
                "seconds": Double(segLen) / 16000.0,
                "enc_frames": T,
                "decode_steps": steps,
                "tokens": outIds.count,
                "time_ms": dtMs,
                "text": text,
            ])
        }

        let transcript = fullTextParts.joined(separator: " ")
        let rtf = totalInferMs / 1000.0 / audioSeconds

        if cfg.jsonOut {
            let report: [String: Any] = [
                "file": cfg.wavPath,
                "audio_seconds": audioSeconds,
                "segments": segmentReports,
                "model_load_ms": loadMs,
                "total_inference_ms": totalInferMs,
                "rtf": rtf,
                "transcript": transcript,
            ]
            let jsonData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(data: jsonData, encoding: .utf8)!)
        } else {
            print(transcript)
            FileHandle.standardError.write(
                String(format: "# %.2fs audio, %d segment(s), inference %.1fms, RTF %.4f (%.0fx realtime), load %.0fms\n",
                       audioSeconds, chunks.count, totalInferMs, rtf, 1.0 / max(rtf, 1e-9), loadMs)
                    .data(using: .utf8)!)
        }
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

main()

import AVFoundation
import CoreMedia
import CoreAudio

/// Microphone capture producing 16 kHz mono Float32 PCM buffers.
///
/// Uses AVCaptureSession rather than AVAudioEngine: engine taps silently never
/// fire on some Bluetooth devices, config-change resets crash or loop, and the
/// engine binds to whatever device was default at start. AVCaptureSession is the
/// proven path in production voice apps — stable across device classes, benign
/// lifecycle, no exception-throwing reset semantics.
///
/// Device binding is EXPLICIT (VoiceInk pattern): the caller passes the target
/// device UID resolved through CoreAudio by AudioDeviceManager, and capture binds
/// to exactly that device — never blindly to whatever AVFoundation calls default.
/// Device switching is driven externally via switchDevice(); the rebuild debounce
/// RESCHEDULES rather than dropping, so a burst of handoff events can never leave
/// capture permanently bound to a stale device.
public final class AudioCapture: @unchecked Sendable {

    public enum CaptureError: Error {
        case noInputDevice
        case sessionSetupFailed(String)
    }

    private let callback: @Sendable (AVAudioPCMBuffer) -> Void
    private let delegate: CaptureDelegate
    private let queue = DispatchQueue(label: "dhikr.audio.capture")

    private var session: AVCaptureSession?
    private var running = false
    /// name of the input device capture is currently bound to — for UI display
    public private(set) var currentDeviceName: String = ""
    /// uid capture is currently bound to (or asked to bind to)
    public private(set) var currentDeviceUID: String?
    public var onDeviceChange: (@Sendable (String) -> Void)?
    private var restartWorkItem: DispatchWorkItem?
    private var lastRestartAt = Date.distantPast
    /// latest requested target — a switch that arrives during a throttle window
    /// is retried with this value rather than dropped
    private var pendingUID: String??

    public init(callback: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.callback = callback
        self.delegate = CaptureDelegate(callback: callback)
    }

    public static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    // MARK: - lifecycle

    /// Start capture bound to the given CoreAudio device UID; nil binds the system default.
    public func start(deviceUID: String? = nil) throws {
        pendingUID = deviceUID
        try buildAndStartSession(deviceUID: deviceUID)
        running = true
    }

    public func stop() {
        running = false
        restartWorkItem?.cancel()
        queue.sync {
            session?.stopRunning()
            session = nil
        }
    }

    /// Re-bind capture to a different device mid-stream. Debounced: Bluetooth
    /// handoffs fire bursts of events, and binding during HFP negotiation captures
    /// pitch-shifted garbage — the settle delay lets the device finish transitioning.
    /// Unlike the previous throttled version, a switch that arrives inside the
    /// minimum-interval window is RETRIED, never dropped.
    public func switchDevice(uid: String?) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.pendingUID = uid
            if uid == self.currentDeviceUID, self.session != nil { return }
            self.restartWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.performSwitch()
            }
            self.restartWorkItem = item
            // 2s settle: BT devices renegotiate HFP for ~1-2s after becoming default
            self.queue.asyncAfter(deadline: .now() + 2.0, execute: item)
        }
    }

    private func performSwitch() {
        guard running else { return }
        guard let uid = pendingUID else { return }
        if uid == currentDeviceUID, session != nil { return }
        let sinceLast = Date().timeIntervalSince(lastRestartAt)
        guard sinceLast > 3 else {
            // inside the minimum rebuild interval — RETRY after the window closes
            // instead of dropping the switch (the old bug: capture stuck forever)
            let retry = DispatchWorkItem { [weak self] in self?.performSwitch() }
            restartWorkItem = retry
            queue.asyncAfter(deadline: .now() + (3.5 - sinceLast), execute: retry)
            return
        }
        lastRestartAt = Date()
        session?.stopRunning()
        session = nil
        try? buildAndStartSession(deviceUID: uid)
    }

    // MARK: - session construction

    /// Resolve the AVCaptureDevice for a CoreAudio UID. AVCaptureDevice.uniqueID
    /// IS the CoreAudio device UID on macOS — the bridge between the two layers.
    private func resolveDevice(uid: String?) -> AVCaptureDevice? {
        if let uid {
            // modern DiscoverySession covers continuity/externals; the legacy
            // devices(for:) list covers everything else — union dedupes by uniqueID
            var byID: [String: AVCaptureDevice] = [:]
            for d in AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio, position: .unspecified).devices { byID[d.uniqueID] = d }
            for d in AVCaptureDevice.devices(for: .audio) { byID[d.uniqueID] = d }
            if let exact = byID[uid] { return exact }
        }
        return AVCaptureDevice.default(for: .audio)
    }

    private func buildAndStartSession(deviceUID: String?) throws {
        guard let device = resolveDevice(uid: deviceUID) else {
            throw CaptureError.noInputDevice
        }
        currentDeviceUID = device.uniqueID
        if currentDeviceName != device.localizedName {
            currentDeviceName = device.localizedName
            onDeviceChange?(device.localizedName)
        }
        let session = AVCaptureSession()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CaptureError.sessionSetupFailed("cannot add input")
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(delegate, queue: queue)
        guard session.canAddOutput(output) else {
            throw CaptureError.sessionSetupFailed("cannot add output")
        }
        session.addOutput(output)
        session.commitConfiguration()

        self.session = session
        // startRunning is blocking-ish; call on the capture queue to avoid stalling callers
        queue.async { session.startRunning() }
    }
}

// MARK: - sample buffer delegate

/// Receives CMSampleBuffers on the capture queue, converts to 16kHz mono float32
/// AVAudioPCMBuffers, forwards to the pipeline callback. Rebuilds its converter
/// if the input format changes (device switch mid-stream).
final class CaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let callback: @Sendable (AVAudioPCMBuffer) -> Void
    private var converter: AVAudioConverter?
    private var converterSourceRate: Double = 0
    private var converterSourceChannels: UInt32 = 0

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    init(callback: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.callback = callback
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pcm = Self.makePCMBuffer(from: sampleBuffer) else { return }

        if pcm.format.sampleRate == 16000, pcm.format.channelCount == 1,
           pcm.format.commonFormat == .pcmFormatFloat32 {
            callback(pcm)
            return
        }

        if converter == nil || converterSourceRate != pcm.format.sampleRate
            || converterSourceChannels != pcm.format.channelCount {
            converter = AVAudioConverter(from: pcm.format, to: targetFormat)
            converterSourceRate = pcm.format.sampleRate
            converterSourceChannels = pcm.format.channelCount
        }
        guard let converter else { return }

        let ratio = 16000.0 / pcm.format.sampleRate
        let capacity = AVAudioFrameCount((Double(pcm.frameLength) * ratio).rounded(.up) + 64)
        guard capacity > 0, let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return pcm
        }
        if error == nil, out.frameLength > 0 {
            callback(out)
        }
    }

    /// CMSampleBuffer → AVAudioPCMBuffer, copying sample data.
    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
        else { return nil }
        guard let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return buffer
    }
}

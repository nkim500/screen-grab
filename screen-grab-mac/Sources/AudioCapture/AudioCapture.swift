import Foundation
import AVFoundation

public protocol AudioCaptureDelegate: AnyObject {
    /// 0.0–1.0 RMS, throttled to ~30Hz.
    func audioCaptureDidUpdateLevel(_ level: Float)
    func audioCapture(didFail err: AudioCaptureError)
    /// Fires once at the 50s warning. `remainingMs` will be ~10000.
    func audioCaptureWillCapAt(remainingMs: Int)
}

/// Captures mic audio while held, converts to 16kHz mono Float32 PCM, emits
/// per-buffer audio-level callbacks for the HUD meter. Thread-safe for use
/// from the main queue. Internal buffer access is serialized.
public final class AudioCapture {
    public weak var delegate: AudioCaptureDelegate?
    public private(set) var isRecording = false

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let bufferLock = NSLock()
    private var startedAt: DispatchTime?
    private let throttle = AudioLevelThrottle(windowMs: 33)
    private var capWarningFired = false
    private var capTimer: DispatchSourceTimer?
    // Holds the sink so we can detach it cleanly on stop(). Re-attaching the
    // same instance across start/stop cycles works, but holding the reference
    // keeps the lifecycle obvious.
    private var sinkNode: AVAudioSinkNode?
    // Per-session tap counter — surfaces the "tap fires once then dies"
    // failure mode in the log without needing to inspect bytes after the fact.
    private var tapCount: Int = 0

    public static let maxDurationMs = 60_000
    public static let warnAtMs = 50_000

    public init() {}

    /// Begins capture. Caller must have already requested + been granted
    /// microphone permission via `AVCaptureDevice.requestAccess(for: .audio)`.
    /// Idempotent: calling start while already recording is a no-op.
    public func start() throws {
        if isRecording { return }
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized: break
        case .notDetermined, .denied, .restricted:
            throw AudioCaptureError.permissionDenied
        @unknown default:
            throw AudioCaptureError.permissionDenied
        }
        bufferLock.lock()
        samples.removeAll(keepingCapacity: true)
        bufferLock.unlock()
        capWarningFired = false
        tapCount = 0

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.deviceUnavailable
        }
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.deviceUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outFormat) else {
            throw AudioCaptureError.deviceUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.tapCount += 1
            self?.handleInputBuffer(buffer, outFormat: outFormat)
        }

        // macOS AVAudioEngine only keeps pulling from inputNode when something
        // downstream consumes the audio. Previous fix routed through
        // mainMixerNode at outputVolume=0, but that silently stalls when the
        // system output device isn't usable for any reason (headphones
        // disconnected, BT renegotiating, no default output set) and the tap
        // fires exactly once before going quiet. AVAudioSinkNode is the
        // documented "consume audio without rendering it" sink — independent
        // of the system output, so the input keeps pulling regardless.
        let sink = AVAudioSinkNode { _, _, _ in
            // Receive blocks from the chain; we don't need the data here
            // because the tap on inputNode already captures it. Returning
            // noErr keeps the graph running.
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: inputFormat)
        self.sinkNode = sink

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            engine.disconnectNodeOutput(input)
            engine.detach(sink)
            self.sinkNode = nil
            throw AudioCaptureError.engineFailed(error)
        }

        isRecording = true
        startedAt = DispatchTime.now()
        scheduleCapTimer()
        // Format details surface device-level surprises (channel count != 1,
        // sample rate mismatch with what converter expects, etc.) at start
        // time rather than as a confusing silent buffer at stop time.
        NSLog("[screen-grab][audio] start sr=16000 ch=1 inputSr=\(inputFormat.sampleRate) inputCh=\(inputFormat.channelCount)")
    }

    public func stop() -> AudioBuffer {
        guard isRecording else {
            return .empty
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.disconnectNodeOutput(engine.inputNode)
        engine.stop()
        if let sink = sinkNode {
            engine.detach(sink)
            sinkNode = nil
        }
        capTimer?.cancel()
        capTimer = nil
        isRecording = false

        bufferLock.lock()
        let snapshot = samples
        bufferLock.unlock()

        let durationMs: Int
        if let start = startedAt {
            durationMs = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        } else {
            durationMs = 0
        }
        // RMS on the captured buffer: separates "audio is empty/silent" (wrong
        // input device, mic muted) from "audio has signal but Apple Speech VAD
        // rejected it." Float32 PCM in [-1, 1]; voice ~0.02–0.2, silence < 0.001.
        var sumSq: Float = 0
        for s in snapshot { sumSq += s * s }
        let rms = snapshot.isEmpty ? 0 : sqrt(sumSq / Float(snapshot.count))
        NSLog("[screen-grab][audio] stop bytes=\(snapshot.count * 4) durationMs=\(durationMs) rms=\(String(format: "%.4f", rms)) taps=\(tapCount)")
        startedAt = nil
        return AudioBuffer(samples: snapshot, durationMs: durationMs)
    }

    // MARK: - Internals

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer, outFormat: AVAudioFormat) {
        guard let converter = converter else { return }

        let outCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * outFormat.sampleRate / buffer.format.sampleRate + 1
        )
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            return
        }

        var error: NSError?
        var consumed = false
        // Use .noDataNow (not .endOfStream) on the drain side. The converter's
        // resampler is stateful across calls — `.endOfStream` flushes its
        // internal filter and puts it in a terminal state, after which the
        // next 30+ tap callbacks all return zero output frames (matching the
        // taps=35 bytes=6400 footprint we saw in the log). `.noDataNow`
        // tells the converter "no more input this instant" without ending
        // the stream, so it keeps producing output on subsequent buffers.
        converter.convert(to: outBuffer, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let err = error {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.audioCapture(didFail: .engineFailed(err))
            }
            return
        }
        guard let channelData = outBuffer.floatChannelData?[0] else { return }
        let count = Int(outBuffer.frameLength)
        let appended = Array(UnsafeBufferPointer(start: channelData, count: count))

        bufferLock.lock()
        samples.append(contentsOf: appended)
        bufferLock.unlock()

        // RMS for level
        var sum: Float = 0
        for s in appended { sum += s * s }
        let rms = appended.isEmpty ? 0 : sqrt(sum / Float(appended.count))
        let level = min(1.0, rms * 6) // light gain so quiet speech still moves the bar

        let now = DispatchTime.now()
        if throttle.shouldEmit(at: now) {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.audioCaptureDidUpdateLevel(level)
            }
        }
    }

    private func scheduleCapTimer() {
        capTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(Self.warnAtMs), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isRecording, !self.capWarningFired else { return }
            self.capWarningFired = true
            self.delegate?.audioCaptureWillCapAt(remainingMs: Self.maxDurationMs - Self.warnAtMs)
            // After the warning, schedule the hard-cap stop.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.maxDurationMs - Self.warnAtMs)) { [weak self] in
                guard let self = self, self.isRecording else { return }
                _ = self.stop()
            }
        }
        timer.resume()
        capTimer = timer
    }
}

/// Decoupled from AudioCapture so it's unit-testable without spinning up
/// AVAudioEngine.
public final class AudioLevelThrottle {
    private let windowNs: UInt64
    private var lastEmit: DispatchTime?
    public init(windowMs: Int) {
        self.windowNs = UInt64(windowMs) * 1_000_000
    }
    public func shouldEmit(at now: DispatchTime) -> Bool {
        if let last = lastEmit, now.uptimeNanoseconds - last.uptimeNanoseconds < windowNs {
            return false
        }
        lastEmit = now
        return true
    }
}

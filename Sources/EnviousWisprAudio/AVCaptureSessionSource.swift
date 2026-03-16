@preconcurrency import AVFoundation
import EnviousWisprCore
import CoreAudio

/// AVCaptureSession-based audio capture source. Avoids BT A2DP→SCO codec switch by
/// capturing from the built-in microphone via AVCaptureSession, which on macOS does NOT
/// trigger Bluetooth audio route changes (AVAudioSession is API_UNAVAILABLE(macos)).
///
/// The framework handles sample rate conversion internally when audioSettings is set
/// to request 16kHz mono Float32 — no manual AVAudioConverter needed.
///
/// Used when BT headphones are connected as output. The engine source (AVAudioEngineSource)
/// is used when no BT output is active (supports voice processing/noise suppression).
@MainActor
final class AVCaptureSessionSource: AudioInputSource {

    // MARK: - AudioInputSource callbacks

    var onSamples: (@Sendable (_ samples: [Float], _ audioLevel: Float) -> Void)?
    var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onInterrupted: (() -> Void)?

    // MARK: - State

    private(set) var isCapturing = false
    var isRunning: Bool { session?.isRunning ?? false }

    // MARK: - Private state

    private var session: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var delegate: CaptureDelegate?
    private var interruptionObservers: [NSObjectProtocol] = []

    /// 16kHz mono Float32 format — matches ASR backend requirements.
    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    // MARK: - Lifecycle

    func prepare() async throws {
        // Find the built-in microphone by transport type — NOT AVCaptureDevice.default(for: .audio)
        // which follows the system default and may return a BT device.
        let builtInMic = findBuiltInMicrophone()
        guard let mic = builtInMic else {
            throw AudioError.formatCreationFailed
        }

        let captureSession = AVCaptureSession()

        let input = try AVCaptureDeviceInput(device: mic)
        guard captureSession.canAddInput(input) else {
            throw AudioError.formatCreationFailed
        }
        captureSession.addInput(input)

        let output = AVCaptureAudioDataOutput()
        // Request 16kHz mono Float32 directly — macOS-only API.
        // The framework handles sample rate conversion internally.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true
        ]

        guard captureSession.canAddOutput(output) else {
            throw AudioError.formatCreationFailed
        }
        captureSession.addOutput(output)

        self.session = captureSession
        self.audioOutput = output

        // Register interruption observers
        registerInterruptionObservers(for: captureSession)

        // Start the session — this does NOT trigger BT route changes on macOS.
        // IMPORTANT: startRunning() is a blocking call that Apple says must not run on main thread.
        // Dispatch to background and await completion.
        let started = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInteractive).async {
                captureSession.startRunning()
                cont.resume(returning: captureSession.isRunning)
            }
        }

        guard started else {
            throw AudioError.formatCreationFailed
        }

        AudioCaptureManager.btRouteLog("AVCaptureSessionSource: prepared with \(mic.localizedName) (uid=\(mic.uniqueID))")
    }

    func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
        guard let output = audioOutput else {
            throw AudioError.formatCreationFailed
        }

        // Capture callbacks on @MainActor before entering AsyncStream closure (which may not be isolated)
        let samplesCallback = onSamples
        let bufferCallback = onBufferCaptured

        let captureDelegate = CaptureDelegate(
            onSamples: samplesCallback,
            onBufferCaptured: bufferCallback,
            targetFormat: Self.targetFormat
        )
        self.delegate = captureDelegate

        let queue = DispatchQueue(label: "com.enviouswispr.capture-session", qos: .userInteractive)
        output.setSampleBufferDelegate(captureDelegate, queue: queue)

        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            captureDelegate.continuation = continuation
        }

        isCapturing = true
        return stream
    }

    func stop() async -> [Float] {
        // Clear delegate BEFORE stopping — prevents callbacks after stop.
        audioOutput?.setSampleBufferDelegate(nil, queue: nil)

        session?.stopRunning()

        isCapturing = false
        removeInterruptionObservers()

        // Source does not own samples — manager accumulates via onSamples callback.
        delegate = nil
        return []
    }

    func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool {
        // AVCaptureSession has no codec-switch problem — format is immediately stable.
        return true
    }

    func abortPrepare() {
        guard session?.isRunning == true, !isCapturing else { return }
        session?.stopRunning()
        removeInterruptionObservers()
    }

    func rebuild() {
        audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
        session = nil
        audioOutput = nil
        delegate = nil
        removeInterruptionObservers()
    }

    // MARK: - Private: Device Discovery

    /// Find the built-in microphone via CoreAudio transport type.
    /// Does NOT use AVCaptureDevice.default(for: .audio) which follows system default
    /// and may return BT devices.
    private func findBuiltInMicrophone() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )

        // Match by CoreAudio transport type — the most reliable way to identify built-in mic.
        for device in discovery.devices {
            if let audioDeviceID = AudioDeviceEnumerator.deviceID(forUID: device.uniqueID) {
                let transport = AudioDeviceEnumerator.transportType(for: audioDeviceID)
                if transport == kAudioDeviceTransportTypeBuiltIn {
                    return device
                }
            }
        }

        // Fallback: match by name (less reliable but covers edge cases)
        AudioCaptureManager.btRouteLog("findBuiltInMicrophone: CoreAudio transport lookup found no built-in device, trying name fallback")
        for device in discovery.devices {
            let name = device.localizedName.lowercased()
            if name.contains("built-in") || name.contains("macbook") {
                return device
            }
        }

        return nil
    }

    // MARK: - Private: Interruption Handling

    private func registerInterruptionObservers(for session: AVCaptureSession) {
        let wasInterrupted = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.onInterrupted?()
        }

        let runtimeError = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.onInterrupted?()
        }

        interruptionObservers = [wasInterrupted, runtimeError]
    }

    private func removeInterruptionObservers() {
        for observer in interruptionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        interruptionObservers = []
    }
}

// MARK: - Capture Delegate

/// Handles AVCaptureAudioDataOutput sample buffer delivery on a serial dispatch queue.
/// Extracts Float32 samples from CMSampleBuffer and forwards via callbacks.
private final class CaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {

    private let onSamples: (@Sendable (_ samples: [Float], _ audioLevel: Float) -> Void)?
    private let onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Set after init by the AsyncStream closure.
    var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private let targetFormat: AVAudioFormat

    /// Track whether first buffer format has been validated.
    private var formatValidated = false
    /// If true, format was wrong — drop all subsequent buffers.
    private var formatMismatch = false

    init(
        onSamples: (@Sendable (_ samples: [Float], _ audioLevel: Float) -> Void)?,
        onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?,
        targetFormat: AVAudioFormat
    ) {
        self.onSamples = onSamples
        self.onBufferCaptured = onBufferCaptured
        self.targetFormat = targetFormat
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !formatMismatch else { return }  // Format was wrong — drop all buffers
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return }

        // Format validation gate — debug assert, release log + fail safe
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)!.pointee
        if !formatValidated {
            let actualRate = asbd.mSampleRate
            let actualChannels = asbd.mChannelsPerFrame
            AudioCaptureManager.btRouteLog("AVCaptureSessionSource first buffer: \(actualRate)Hz/\(actualChannels)ch, bits=\(asbd.mBitsPerChannel), float=\(asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0)")

            #if DEBUG
            assert(actualRate == 16000 && actualChannels == 1,
                   "AVCaptureSession format mismatch: \(actualRate)Hz/\(actualChannels)ch — expected 16000Hz/1ch")
            #endif

            formatValidated = true  // Set regardless of match — log once, not on every buffer
            if actualRate != 16000 || actualChannels != 1 {
                AudioCaptureManager.btRouteLog("FORMAT MISMATCH: expected 16000Hz/1ch, got \(actualRate)Hz/\(actualChannels)ch — dropping all buffers")
                formatMismatch = true
                return
            }
        }

        // Extract Float32 samples from CMSampleBuffer
        let frameCount = numSamples

        let audioFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Copy PCM data from CMSampleBuffer into AVAudioPCMBuffer
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return }

        // Calculate audio level (RMS)
        let level = AudioBufferProcessor.calculateRMS(pcmBuffer)

        // Extract [Float] samples
        if let channelData = pcmBuffer.floatChannelData {
            let samples = Array(UnsafeBufferPointer(
                start: channelData[0],
                count: frameCount
            ))
            onSamples?(samples, level)
        }

        // Forward buffer to streaming ASR
        onBufferCaptured?(pcmBuffer)

        // Yield to stream consumers
        continuation?.yield(pcmBuffer)
    }
}

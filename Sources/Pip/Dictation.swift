import AVFoundation
import Foundation
import Observation

#if canImport(FluidAudio)
import FluidAudio
#endif

public enum DictationSetupPhase: Equatable {
    case idle
    case downloading
    case compiling
    case loading
    case ready
    case failed
}

/// Captures a short hold-to-talk recording and returns its local transcription.
///
/// `prepare()` is deliberately separate from `start()`: it is the only method
/// allowed to download the optional Parakeet model, and should only be called
/// from the explicit voice setup action.
@MainActor
@Observable
public final class DictationService {
    public private(set) var isRecording = false
    public private(set) var isTranscribing = false
    public private(set) var isPreparing = false
    public private(set) var isReady = false
    public private(set) var hasCachedModel = false
    public private(set) var setupPhase: DictationSetupPhase = .idle
    /// Nil means FluidAudio has not reported a measured fraction yet.
    public private(set) var downloadProgress: Double?
    public private(set) var downloadedFiles: Int?
    public private(set) var totalFiles: Int?
    public private(set) var status = "Voice dictation is not set up."
    public private(set) var error: String?

    private let capture = DictationCapture()
    /// Increments for every capture lifecycle so a late transcription result
    /// cannot populate the prompt after Escape or a newer recording.
    private var interactionGeneration = 0

    #if canImport(FluidAudio)
    private var recognizer: AsrManager?
    #endif

    public init() {}

    /// Updates the cache indicator without loading a model or contacting the
    /// network. Call this when rendering the guided setup state.
    @discardableResult
    public func refreshCachedModelAvailability() -> Bool {
        #if canImport(FluidAudio)
        let cacheDirectory = AsrModels.defaultCacheDirectory(for: .v3)
        let available = AsrModels.modelsExist(at: cacheDirectory, version: .v3)
        hasCachedModel = available
        return available
        #else
        hasCachedModel = false
        return false
        #endif
    }

    /// Loads a previously downloaded Parakeet v3 model. This never requests
    /// microphone access and never downloads anything, so it is safe to call
    /// during app launch to restore dictation readiness.
    public func loadCachedModel() async throws {
        guard !isPreparing, !isRecording, !isTranscribing else {
            throw DictationError.busy
        }

        #if canImport(FluidAudio)
        if recognizer != nil {
            isReady = true
            hasCachedModel = true
            setupPhase = .ready
            return
        }

        error = nil
        isPreparing = true
        setupPhase = .loading
        downloadProgress = nil
        downloadedFiles = nil
        totalFiles = nil
        status = "Loading on-device dictation…"
        defer { isPreparing = false }

        let cacheDirectory = AsrModels.defaultCacheDirectory(for: .v3)
        guard AsrModels.modelsExist(at: cacheDirectory, version: .v3) else {
            hasCachedModel = false
            isReady = false
            setupPhase = .idle
            status = "Download dictation in setup to use it."
            throw DictationError.noCachedModel
        }

        do {
            let models = try await AsrModels.load(
                from: cacheDirectory,
                version: .v3,
                progressHandler: makeProgressHandler()
            )
            recognizer = AsrManager(config: .default, models: models)
            hasCachedModel = true
            isReady = true
            setupPhase = .ready
            status = "Dictation is ready."
        } catch {
            isReady = false
            setupPhase = .failed
            status = "Could not load cached dictation."
            self.error = error.localizedDescription
            throw error
        }
        #else
        hasCachedModel = false
        isReady = false
        throw DictationError.backendNotLinked
        #endif
    }

    /// Requests microphone permission and downloads/loads the multilingual
    /// Parakeet v3 model when it is not already present.
    public func prepare() async throws {
        guard !isPreparing else { return }
        guard !isRecording, !isTranscribing else {
            throw DictationError.busy
        }

        error = nil
        isPreparing = true
        downloadProgress = nil
        downloadedFiles = nil
        totalFiles = nil
        defer { isPreparing = false }

        guard await requestMicrophoneAccess() else {
            status = "Microphone access is required for dictation."
            setupPhase = .failed
            error = DictationError.microphonePermissionDenied.localizedDescription
            throw DictationError.microphonePermissionDenied
        }

        #if canImport(FluidAudio)
        do {
            let cacheDirectory = AsrModels.defaultCacheDirectory(for: .v3)
            let models: AsrModels
            if AsrModels.modelsExist(at: cacheDirectory, version: .v3) {
                hasCachedModel = true
                setupPhase = .loading
                status = "Loading downloaded dictation…"
                models = try await AsrModels.load(
                    from: cacheDirectory,
                    version: .v3,
                    progressHandler: makeProgressHandler()
                )
            } else {
                hasCachedModel = false
                setupPhase = .downloading
                status = "Downloading Parakeet dictation…"
                let downloadedDirectory = try await AsrModels.download(
                    version: .v3,
                    progressHandler: makeProgressHandler()
                )
                setupPhase = .loading
                status = "Loading Parakeet dictation…"
                models = try await AsrModels.load(
                    from: downloadedDirectory,
                    version: .v3,
                    progressHandler: makeProgressHandler()
                )
            }
            recognizer = AsrManager(config: .default, models: models)
            hasCachedModel = true
            isReady = true
            setupPhase = .ready
            downloadProgress = 1
            status = "Dictation is ready."
        } catch {
            isReady = false
            setupPhase = .failed
            status = "Could not prepare dictation."
            self.error = error.localizedDescription
            throw error
        }
        #else
        isReady = false
        setupPhase = .failed
        status = "On-device dictation is unavailable in this build."
        throw DictationError.backendNotLinked
        #endif
    }

    /// Begins capture. This never downloads a model; call `prepare()` first.
    public func start() async throws {
        guard !isRecording, !isTranscribing else { throw DictationError.busy }
        guard isReady else { throw DictationError.notPrepared }
        guard await requestMicrophoneAccess() else {
            status = "Microphone access is required for dictation."
            throw DictationError.microphonePermissionDenied
        }

        error = nil
        do {
            try capture.start()
            interactionGeneration &+= 1
            isRecording = true
            status = "Listening…"
        } catch {
            status = "Could not start recording."
            self.error = error.localizedDescription
            throw error
        }
    }

    /// Stops capture and transcribes the completed clip. A tap, cancellation,
    /// or silence returns an empty string instead of asking the model to invent
    /// a transcript.
    public func finish() async throws -> String {
        guard isRecording else { return "" }
        isRecording = false
        let recording = capture.stop()
        let generation = interactionGeneration

        guard recording.hasSpeechCandidate else {
            status = "No speech detected."
            return ""
        }

        #if canImport(FluidAudio)
        guard let recognizer else { throw DictationError.notPrepared }
        isTranscribing = true
        status = "Transcribing…"
        defer { isTranscribing = false }

        do {
            var decoderState = TdtDecoderState.make(decoderLayers: await recognizer.decoderLayerCount)
            let result = try await recognizer.transcribe(recording.samples, decoderState: &decoderState)
            guard generation == interactionGeneration else { return "" }
            let transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            status = transcript.isEmpty ? "No speech detected." : "Dictation complete."
            return transcript
        } catch {
            guard generation == interactionGeneration else { return "" }
            status = "Could not transcribe that recording."
            self.error = error.localizedDescription
            throw error
        }
        #else
        throw DictationError.backendNotLinked
        #endif
    }

    /// Stops immediately, discards all captured samples, and leaves the prompt
    /// untouched. This is the Escape action while a push-to-talk key is held.
    public func cancel() {
        interactionGeneration &+= 1
        capture.cancel()
        isRecording = false
        isTranscribing = false
        error = nil
        status = isReady ? "Dictation cancelled." : "Voice dictation is not set up."
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    #if canImport(FluidAudio)
    private func makeProgressHandler() -> ProgressHandler {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.receive(progress)
            }
        }
    }

    private func receive(_ progress: DownloadProgress) {
        guard isPreparing else { return }
        downloadProgress = min(max(progress.fractionCompleted, 0), 1)
        switch progress.phase {
        case .listing:
            setupPhase = .downloading
            status = "Finding Parakeet files…"
            downloadedFiles = nil
            totalFiles = nil
        case .downloading(let completedFiles, let totalFiles):
            setupPhase = .downloading
            self.downloadedFiles = completedFiles
            self.totalFiles = totalFiles
            status = "Downloading Parakeet dictation…"
        case .compiling(let modelName):
            setupPhase = .compiling
            downloadedFiles = nil
            totalFiles = nil
            status = "Preparing \(modelName)…"
        }
    }
    #endif
}

public enum DictationError: LocalizedError {
    case busy
    case notPrepared
    case noCachedModel
    case microphonePermissionDenied
    case backendNotLinked
    case audioFormatUnavailable

    public var errorDescription: String? {
        switch self {
        case .busy: return "Dictation is already active."
        case .notPrepared: return "Set up on-device dictation before recording."
        case .noCachedModel: return "No downloaded dictation model is available."
        case .microphonePermissionDenied: return "Allow microphone access in System Settings to use dictation."
        case .backendNotLinked: return "This build does not include the on-device dictation backend."
        case .audioFormatUnavailable: return "The microphone format could not be converted for dictation."
        }
    }
}

private final class DictationCapture: @unchecked Sendable {
    private static let sampleRate = 16_000.0

    private let engine = AVAudioEngine()
    private let samples = LockedSamples()
    private var inputNode: AVAudioInputNode?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    func start() throws {
        cancel()
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.sampleRate,
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw DictationError.audioFormatUnavailable
        }

        self.inputNode = input
        self.outputFormat = outputFormat
        self.converter = converter
        samples.reset()

        input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            self?.appendConverted(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() -> DictationRecording {
        inputNode?.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        inputNode = nil
        converter = nil
        outputFormat = nil
        return samples.take()
    }

    func cancel() {
        inputNode?.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        engine.reset()
        inputNode = nil
        converter = nil
        outputFormat = nil
        samples.reset()
    }

    private func appendConverted(_ input: AVAudioPCMBuffer) {
        guard let converter, let outputFormat else { return }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(max(1, (Double(input.frameLength) * ratio).rounded(.up) + 32))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var suppliedInput = false
        var conversionError: NSError?
        _ = converter.convert(to: output, error: &conversionError) { _, status in
            guard !suppliedInput else {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return input
        }
        guard conversionError == nil,
              output.frameLength > 0,
              let channels = output.floatChannelData
        else { return }
        samples.append(channels[0], count: Int(output.frameLength))
    }

    struct DictationRecording {
        let samples: [Float]

        var hasSpeechCandidate: Bool {
            DictationSpeechGate.hasSpeechCandidate(samples: samples)
        }
    }

    private final class LockedSamples: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Float] = []

        func append(_ pointer: UnsafePointer<Float>, count: Int) {
            guard count > 0 else { return }
            lock.lock()
            storage.append(contentsOf: UnsafeBufferPointer(start: pointer, count: count))
            lock.unlock()
        }

        func take() -> DictationRecording {
            lock.lock()
            let result = DictationRecording(samples: storage)
            storage.removeAll(keepingCapacity: false)
            lock.unlock()
            return result
        }

        func reset() {
            lock.lock()
            storage.removeAll(keepingCapacity: false)
            lock.unlock()
        }
    }
}

/// A pre-inference gate for accidental taps and silent recordings. Keeping it
/// separate makes this safety behavior testable without invoking hardware or a
/// transcription model.
enum DictationSpeechGate {
    static let minimumSpeechSamples = 4_800 // 300 ms at 16 kHz.
    static let minimumRMS: Float = 0.003

    static func hasSpeechCandidate(samples: [Float]) -> Bool {
        guard samples.count >= minimumSpeechSamples else { return false }
        let energy = samples.reduce(Float.zero) { $0 + ($1 * $1) } / Float(samples.count)
        return energy.squareRoot() >= minimumRMS
    }
}

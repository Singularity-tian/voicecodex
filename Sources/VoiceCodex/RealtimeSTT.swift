import AVFoundation
import Foundation

enum SpeechFailure: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

/// One press-and-hold recording. Audio stays in memory and is streamed to Soniox.
@MainActor
final class RealtimeSTT {
    var onTranscript: ((String, Bool) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onStatus: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    private var microphone: SpeechMicrophone?
    private var connection: SonioxConnection?
    private var generation = UUID()
    private var finishing = false

    func start(apiKey: String) async throws {
        cancel()
        let token = UUID()
        generation = token
        finishing = false
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechFailure.message("请先配置 Soniox API Key。")
        }
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .audio)
        default: authorized = false
        }
        guard generation == token else { throw CancellationError() }
        guard authorized else {
            throw SpeechFailure.message("请在系统设置 → 隐私与安全性 → 麦克风中允许 VoiceCodex。")
        }
        guard !finishing else {
            throw SpeechFailure.message("录音已结束，请按住快捷键重新说话。")
        }

        let stream = SonioxConnection()
        stream.onTranscript = { [weak self] text, final in
            guard let self, self.generation == token else { return }
            self.onTranscript?(text, final)
        }
        stream.onFailure = { [weak self] error in
            guard let self, self.generation == token else { return }
            self.stopCapture()
            self.onStatus?(error.localizedDescription)
            self.onError?(error)
        }
        connection = stream
        let microphone = SpeechMicrophone()
        self.microphone = microphone
        let sink = stream.audioSink
        do {
            // Capture immediately while the WebSocket connects; its ordered queue
            // preserves words spoken during connection establishment.
            try microphone.start(onAudio: { data in
                if case .dropped = sink.yield(data) {
                    Task { @MainActor [weak stream] in
                        stream?.fail(SpeechFailure.message("语音网络发送过慢，请检查网络后重试。"))
                    }
                }
            }, onLevel: { [weak self] level in
                Task { @MainActor in
                    guard let self, self.generation == token, !self.finishing else { return }
                    self.onLevel?(level)
                }
            }, onError: { [weak stream] in
                Task { @MainActor in
                    stream?.fail(SpeechFailure.message("麦克风音频转换失败，请重新录音。"))
                }
            })
            onStatus?("正在连接云端，已开始录音…")
            try await stream.start(apiKey: apiKey)
            guard generation == token else { throw CancellationError() }
            if !finishing { onStatus?("正在聆听… 松开快捷键执行") }
        } catch {
            microphone.stop()
            stream.cancel()
            throw error
        }
    }

    /// Stop immediately on key release, including while start() awaits the network.
    /// The queued audio is retained for the connection to finish sending.
    func stopCapture() {
        finishing = true
        microphone?.stop()
        onLevel?(0)
    }

    func finish() async throws -> String {
        stopCapture()
        guard let connection else {
            throw SpeechFailure.message("录音尚未开始，请按住快捷键重新说话。")
        }
        onStatus?("正在完成识别…")
        return try await connection.finish()
    }

    func cancel() {
        generation = UUID()
        microphone?.stop()
        microphone = nil
        connection?.cancel()
        connection = nil
        onLevel?(0)
    }
}

/// A single writer drains an ordered PCM queue. The end marker is sent only after
/// every captured buffer, including buffers queued before the connection opened.
@MainActor
final class SonioxConnection {
    static let model = "stt-rt-v5"
    let audioSink: AsyncStream<Data>.Continuation
    var onTranscript: ((String, Bool) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let audioStream: AsyncStream<Data>
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var writer: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var transcript = SonioxTranscript()
    private var isFinishing = false
    private var completion: Result<String, Error>?
    private var waiter: CheckedContinuation<String, Error>?

    init() {
        // At the normal 10–20 ms tap size this holds several seconds of initial
        // connection latency. Overflow fails the recording instead of losing words.
        var continuation: AsyncStream<Data>.Continuation!
        audioStream = AsyncStream(bufferingPolicy: .bufferingOldest(1_000)) { continuation = $0 }
        audioSink = continuation
    }

    func start(apiKey: String) async throws {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config)
        self.session = session
        let url = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
        let socket = session.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, self.completion == nil else { return }
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: throw SpeechFailure.message("云端返回了无法识别的语音消息。")
                    }
                    let finished = try self.transcript.ingest(data)
                    self.onTranscript?(self.transcript.text, false)
                    if finished {
                        guard self.isFinishing else {
                            throw SpeechFailure.message("语音连接提前结束，请重新录音。")
                        }
                        let text = self.transcript.confirmedText
                        guard !text.isEmpty else {
                            throw SpeechFailure.message("没有识别到语音，请按住快捷键重新说话。")
                        }
                        self.onTranscript?(text, true)
                        self.complete(.success(text))
                        return
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(Self.safeError(error))
            }
        }

        do {
            let configuration: [String: Any] = [
                "api_key": apiKey,
                "model": Self.model,
                "audio_format": "pcm_s16le",
                "sample_rate": 16_000,
                "num_channels": 1,
                "language_hints": ["zh", "en"],
                "enable_endpoint_detection": true,
                "context": ["terms": ["Codex", "GitHub", "README", "worktree", "Swift", "Persom"]],
            ]
            let json = try JSONSerialization.data(withJSONObject: configuration)
            try await socket.send(.string(String(decoding: json, as: UTF8.self)))
            if let completion { _ = try completion.get(); return }
            writer = Task { [weak self, audioStream] in
                do {
                    for await pcm in audioStream {
                        try Task.checkCancellation()
                        try await socket.send(.data(pcm))
                    }
                    try Task.checkCancellation()
                    // Soniox documents an empty text or binary frame as EOF.
                    try await socket.send(.string(""))
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.fail(Self.safeError(error))
                }
            }
        } catch {
            let safe = Self.safeError(error)
            fail(safe)
            throw safe
        }
    }

    func finish() async throws -> String {
        if let completion { return try completion.get() }
        guard !isFinishing else { throw SpeechFailure.message("正在完成上一段语音，请稍候。") }
        isFinishing = true
        audioSink.finish()
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) }
            catch { return }
            self?.fail(SpeechFailure.message("云端识别超时，指令没有执行。请检查网络后重试。"))
        }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func cancel() {
        if completion == nil { complete(.failure(CancellationError())) }
    }

    func fail(_ error: Error) {
        guard completion == nil else { return }
        complete(.failure(error))
        onFailure?(error)
    }

    private func complete(_ result: Result<String, Error>) {
        guard completion == nil else { return }
        completion = result
        audioSink.finish()
        writer?.cancel()
        reader?.cancel()
        deadline?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        waiter?.resume(with: result)
        waiter = nil
    }

    private static func safeError(_ error: Error) -> Error {
        if error is SpeechFailure || error is CancellationError { return error }
        // Provider responses and network descriptions must never echo credentials.
        return SpeechFailure.message("无法连接云端语音服务，指令没有执行。请检查网络与 API Key 后重试。")
    }
}

/// Final tokens arrive once; each update replaces the previous provisional tail.
struct SonioxTranscript {
    private var confirmed = ""
    private var provisional = ""
    var text: String { (confirmed + provisional).trimmingCharacters(in: .whitespacesAndNewlines) }
    var confirmedText: String { confirmed.trimmingCharacters(in: .whitespacesAndNewlines) }

    mutating func ingest(_ data: Data) throws -> Bool {
        struct Response: Decodable {
            struct Token: Decodable { let text: String; let is_final: Bool }
            let tokens: [Token]?
            let finished: Bool?
            let error_code: Int?
        }
        let result: Response
        do { result = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw SpeechFailure.message("无法读取云端识别结果，请重新录音。") }
        if let code = result.error_code {
            switch code {
            case 401: throw SpeechFailure.message("Soniox API Key 无效或已过期，请更新配置。")
            case 402: throw SpeechFailure.message("Soniox 余额或用量额度不足，请检查账户。")
            case 429: throw SpeechFailure.message("Soniox 请求过于频繁，请稍后重试。")
            default: throw SpeechFailure.message("Soniox 识别失败（\(code)），指令没有执行。")
            }
        }
        if let tokens = result.tokens {
            provisional = ""
            for token in tokens where token.text != "<end>" && token.text != "<fin>" {
                if token.is_final { confirmed += token.text }
                else { provisional += token.text }
            }
        }
        return result.finished == true
    }
}

/// The tap processes buffers synchronously, before AVAudioEngine reuses storage.
/// A lock makes stop() a barrier: no captured chunk can overtake the EOF marker.
final class SpeechMicrophone {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var active = false
    private var hasTap = false
    private var lastLevel = Date.distantPast

    func start(onAudio: @escaping (Data) -> Void, onLevel: @escaping (Float) -> Void,
               onError: @escaping () -> Void) throws {
        _ = engine.mainMixerNode
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechFailure.message("没有可用的麦克风，请检查输入设备。")
        }
        lock.lock(); active = true; lock.unlock()
        input.installTap(onBus: 0, bufferSize: 960, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.active else { return }
            autoreleasepool {
                guard let (data, level) = Self.encode(buffer) else {
                    self.active = false
                    onError()
                    return
                }
                onAudio(data)
                if Date().timeIntervalSince(self.lastLevel) >= 0.05 {
                    self.lastLevel = Date()
                    onLevel(level)
                }
            }
        }
        hasTap = true
        engine.prepare()
        do { try engine.start() }
        catch {
            stop()
            throw SpeechFailure.message("麦克风启动失败，请检查系统音频输入设置。")
        }
    }

    func stop() {
        lock.lock(); active = false; lock.unlock()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        engine.stop()
    }

    /// Internal so offline tests can exercise the real conversion without opening a microphone.
    static func encode(_ source: AVAudioPCMBuffer) -> (Data, Float)? {
        let frames = Int(source.frameLength)
        guard frames > 0, let channels = source.floatChannelData,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: source.format.sampleRate,
                                             channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: source.frameLength),
              let values = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = source.frameLength
        let count = Int(source.format.channelCount)
        var energy: Float = 0
        for i in 0..<frames {
            var value: Float = 0
            for channel in 0..<count {
                value += source.format.isInterleaved ? channels[0][i * count + channel] : channels[channel][i]
            }
            values[i] = value / Float(count)
            energy += values[i] * values[i]
        }
        let level = min(1, sqrt(energy / Float(frames)) * 5)
        let output: AVAudioPCMBuffer
        if abs(monoFormat.sampleRate - 16_000) < 1 {
            output = mono
        } else {
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                            channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: monoFormat, to: target),
                  let converted = AVAudioPCMBuffer(pcmFormat: target,
                    frameCapacity: AVAudioFrameCount(ceil(Double(frames) * 16_000 / monoFormat.sampleRate) + 32))
            else { return nil }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                if supplied { state.pointee = .endOfStream; return nil }
                supplied = true
                state.pointee = .haveData
                return mono
            }
            guard status != .error, error == nil, converted.frameLength > 0 else { return nil }
            output = converted
        }
        guard let samples = output.floatChannelData?[0] else { return nil }
        var data = Data(count: Int(output.frameLength) * 2)
        data.withUnsafeMutableBytes { bytes in
            let integers = bytes.bindMemory(to: Int16.self)
            for i in 0..<Int(output.frameLength) {
                integers[i] = Int16(max(-1, min(1, samples[i])) * Float(Int16.max)).littleEndian
            }
        }
        return (data, level)
    }
}

// Shared media boundary: keep this file identical in eucaly and AltView.
// Foundation/AVFoundation only so the transport can also be used by a tvOS host.
import Foundation
@preconcurrency import AVFoundation
import HaishinKit
import SRTHaishinKit
import Security
import LocalAuthentication
import VideoToolbox

nonisolated struct SRTMediaSettings: Codable, Equatable, Sendable {
    var host = ""
    var port = 10000
    var frameRate = 60
    var latency = 80
    var bitRate = 20_000_000
    var isValid: Bool {
        !host.isEmpty && host.utf8.count <= 253 && !host.contains(where: { $0.isWhitespace })
            && (1...65535).contains(port) && [50, 60].contains(frameRate)
            && (20...1000).contains(latency) && (2_000_000...80_000_000).contains(bitRate)
            && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }
    }
    static func validPassphrase(_ value: String) -> Bool {
        (10...79).contains(value.utf8.count)
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }
    }
    func url(passphrase: String, listening: Bool = false) throws -> URL {
        guard (listening ? (1...65535).contains(port) && (20...1000).contains(latency) : isValid),
              Self.validPassphrase(passphrase) else { throw SRTMediaError.invalidSettings }
        // libsrt options here are in milliseconds (not ffmpeg's microseconds).
        var parts = URLComponents()
        parts.scheme = "srt"; parts.host = listening ? "0.0.0.0" : host; parts.port = port
        parts.queryItems = [URLQueryItem(name: "mode", value: listening ? "listener" : "caller"),
            .init(name: "transtype", value: "live"), .init(name: "latency", value: String(latency)),
            .init(name: "passphrase", value: passphrase), .init(name: "pbkeylen", value: "16"),
            .init(name: "enforcedencryption", value: "true"),
            .init(name: "conntimeo", value: "3000"), .init(name: "peeridletimeo", value: "3000")]
        guard let url = parts.url else { throw SRTMediaError.invalidSettings }; return url
    }
}

nonisolated enum SRTMediaError: LocalizedError {
    case invalidSettings, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidSettings: return "Check the address, port and passphrase (10–79 letters, numbers, - or _)."
        case .keychain(let status): return "The media passphrase could not be saved or read in Keychain (\(status))."
        }
    }
}

actor SRTMediaSecrets {
    static let shared = SRTMediaSecrets()
    func read(_ account: String) throws -> String? {
        var query = base(account); query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SRTMediaError.keychain(status)
        }
        return value
    }
    func save(_ value: String, account: String) throws {
        guard SRTMediaSettings.validPassphrase(value) else { throw SRTMediaError.invalidSettings }
        let query = base(account)
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SRTMediaError.keychain(status) }
    }
    private func base(_ account: String) -> [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "eucalyMedia").srt",
         kSecAttrAccount as String: account,
         kSecUseAuthenticationContext as String: context]
    }
}

// Capture/audio callbacks can outpace an actor. One consumer, one replaceable
// video frame and a bounded audio queue prevent a task per sample from piling up.
nonisolated final class SRTMediaIngest: @unchecked Sendable {
    enum Sample: @unchecked Sendable { case video(CMSampleBuffer), audio(AVAudioPCMBuffer, AVAudioTime) }
    private let lock = NSLock()
    private var video: CMSampleBuffer?
    private var audio: [(AVAudioPCMBuffer, AVAudioTime)] = []
    private var active = true
    private let signal: AsyncStream<Void>.Continuation
    let signals: AsyncStream<Void>
    init() {
        var continuation: AsyncStream<Void>.Continuation!
        signals = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        signal = continuation
    }
    func offer(_ sample: Sample) {
        lock.lock()
        if active {
            switch sample {
            case .video(let frame): video = frame
            case .audio(let buffer, let time):
                if audio.count >= 8 { audio.removeFirst() }
                audio.append((buffer, time))
            }
            signal.yield(())
        }
        lock.unlock()
    }
    func drain() -> [Sample] {
        lock.lock(); defer { lock.unlock() }
        var samples = audio.map { Sample.audio($0.0, $0.1) }; audio.removeAll(keepingCapacity: true)
        if let video { samples.append(.video(video)); self.video = nil }
        return samples
    }
    func finish() {
        lock.lock(); active = false; video = nil; audio.removeAll(); signal.finish(); lock.unlock()
    }
}

/// A session owns a connection. Closing it also retires all queued source data.
/// MPEG-TS with H.264/AAC keeps the receiver independent of eucaly's model/UI.
actor SRTMediaSession {
    let connection = SRTConnection()
    let stream: SRTStream
    private var ingestTask: Task<Void, Never>?
    init() { stream = SRTStream(connection: connection) }
    func publish(settings: SRTMediaSettings, passphrase: String, ingest: SRTMediaIngest) async throws {
        try await stream.setVideoSettings(.init(videoSize: .init(width: 1920, height: 1080),
            bitRate: settings.bitRate, profileLevel: kVTProfileLevel_H264_High_AutoLevel as String,
            scalingMode: .letterbox, maxKeyFrameIntervalDuration: 1, allowFrameReordering: false,
            dataRateLimits: nil, isLowLatencyRateControlEnabled: true,
            isHardwareAcceleratedEnabled: true, expectedFrameRate: Double(settings.frameRate)))
        try await stream.setAudioSettings(.init(bitRate: 192_000, sampleRate: 48000))
        await stream.setVideoInputBufferCounts(1)
        await stream.setExpectedMedias([.video, .audio])
        try await connection.connect(settings.url(passphrase: passphrase))
        await stream.publish()
        ingestTask = Task { [stream] in
            for await _ in ingest.signals {
                guard !Task.isCancelled else { break }
                for sample in ingest.drain() {
                    switch sample {
                    case .video(let buffer): await stream.append(buffer)
                    case .audio(let buffer, let when): await stream.append(buffer, when: when)
                    }
                }
            }
        }
    }
    func receive(settings: SRTMediaSettings, passphrase: String, output: some StreamOutput) async throws {
        await stream.addOutput(output)
        try await connection.connect(settings.url(passphrase: passphrase, listening: true))
        await stream.play()
    }
    func isConnected() async -> Bool { await connection.connected }
    func close() async {
        ingestTask?.cancel(); ingestTask = nil
        await stream.close(); await connection.close()
    }
}

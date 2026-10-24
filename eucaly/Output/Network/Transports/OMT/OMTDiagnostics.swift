import Foundation

/// Vendor totals for the first connected OMT video-subscribed channel. These
/// generic bidirectional counters can include metadata and received media;
/// ordinary receiver control metadata does not count as received media. They
/// are not socket completions or delivery. Channel changes can reset them;
/// with no video channel the SDK returns zero-valued totals.
nonisolated struct OMTVideoSDKStatistics: Codable, Sendable {
    var framesEnqueued: Int64
    var framesDropped: Int64 // Send pool/oversize or incoming-media pool rejection; metadata send included.
    var bytesEnqueued: Int64
    var codecMilliseconds: Int64 // SDK encoder time; not GPU composition time.
    var zeroReturnCalls: UInt64 // Sender-lifetime; also counts no subscribers.
    var isValid: Bool { [framesEnqueued, framesDropped, bytesEnqueued, codecMilliseconds].allSatisfy { $0 >= 0 } }
}

/// First connected AUDIO channel's generic totals; resets on channel changes.
/// Drops include send pool/oversize and incoming-media pool rejection; channel
/// metadata sends share these counters. Ordinary receiver metadata is consumed
/// before the incoming-media drop branch. Bytes may include channel metadata.
/// Sender-lifetime return totals sum all channels: positive is not all-client
/// acceptance or wire delivery, and zero is valid without an audio subscriber.
nonisolated struct OMTAudioSDKStatistics: Codable, Sendable {
    var framesEnqueued: Int64
    var framesDropped: Int64
    var bytesEnqueued: Int64
    var sendCalls: UInt64
    var zeroReturnCalls: UInt64
    var positiveReturnCalls: UInt64
    var bytesReturned: UInt64
    var isValid: Bool { [framesEnqueued, framesDropped, bytesEnqueued].allSatisfy { $0 >= 0 } }
}

/// One synchronous SDK call, paired before the video owner's next call. Neither
/// a positive return nor a channel-counter change proves wire delivery. Previous
/// statistics belong to the previous video call; channel identity is unavailable.
nonisolated struct OMTVideoSDKCallObservation: Codable, Sendable {
    var generation: UUID
    var contentEpoch: UInt64
    var callIndex: UInt64
    var timecode: Int64
    var startedNanoseconds: UInt64
    var finishedNanoseconds: UInt64
    var format: NetworkVideoPixelFormat
    var rawByteCount: Int
    var returnedBytes: Int32
    var connectionsAfter: Int
    var previousConnections: Int?
    var previousTimecode: Int64?
    var previousStatistics: OMTVideoSDKStatistics?
    var statistics: OMTVideoSDKStatistics

    // These are observations, not a rejection classification. Connections can
    // be audio-only, handshaking or concurrently closing; counters can switch
    // channels and include metadata, so no global monotonicity is assumed.
    var zeroReturnWithConnectionContext: Bool {
        returnedBytes == 0 && (connectionsAfter > 0 || (previousConnections ?? 0) > 0)
    }
    var observedDropCounterIncrease: Bool {
        guard let previousStatistics else { return false }
        return statistics.framesDropped > previousStatistics.framesDropped
    }
    var isValid: Bool {
        callIndex > 0 && timecode >= 0 && startedNanoseconds > 0
            && finishedNanoseconds >= startedNanoseconds && rawByteCount == format.byteCount
            && connectionsAfter >= 0 && (previousConnections.map { $0 >= 0 } ?? true)
            && (previousTimecode.map { $0 >= 0 && $0 < timecode } ?? true)
            && statistics.isValid && (previousStatistics?.isValid ?? true)
    }
}

/// DEBUG/opt-in only at the producer. Separate bounded sets keep a counter
/// increase after ordinary handshake zeros, and survive later peer-off calls.
/// No images, encoded payloads, process pointers or unbounded history are kept.
nonisolated struct OMTVideoSDKDiagnostics: Codable, Sendable {
    static let retainedPerSet = 4
    var lastCall: OMTVideoSDKCallObservation?
    var firstZeroReturnsWithConnections: [OMTVideoSDKCallObservation] = []
    var recentZeroReturnsWithConnections: [OMTVideoSDKCallObservation] = []
    var firstDropCounterIncreases: [OMTVideoSDKCallObservation] = []
    var recentDropCounterIncreases: [OMTVideoSDKCallObservation] = []

    mutating func record(_ call: OMTVideoSDKCallObservation) {
        lastCall = call
        if call.zeroReturnWithConnectionContext {
            if firstZeroReturnsWithConnections.count < Self.retainedPerSet {
                firstZeroReturnsWithConnections.append(call)
            }
            recentZeroReturnsWithConnections.append(call)
            if recentZeroReturnsWithConnections.count > Self.retainedPerSet {
                recentZeroReturnsWithConnections.removeFirst()
            }
        }
        if call.observedDropCounterIncrease {
            if firstDropCounterIncreases.count < Self.retainedPerSet {
                firstDropCounterIncreases.append(call)
            }
            recentDropCounterIncreases.append(call)
            if recentDropCounterIncreases.count > Self.retainedPerSet {
                recentDropCounterIncreases.removeFirst()
            }
        }
    }
    var isValid: Bool {
        guard let lastCall, lastCall.isValid else { return false }
        func valid(_ records: [OMTVideoSDKCallObservation], matching predicate: (OMTVideoSDKCallObservation) -> Bool) -> Bool {
            guard records.count <= Self.retainedPerSet else { return false }
            var preceding: UInt64 = 0
            for record in records {
                guard record.isValid, record.generation == lastCall.generation,
                      record.contentEpoch <= lastCall.contentEpoch, record.callIndex > preceding,
                      record.callIndex <= lastCall.callIndex, predicate(record) else { return false }
                preceding = record.callIndex
            }
            return true
        }
        return valid(firstZeroReturnsWithConnections, matching: { $0.zeroReturnWithConnectionContext })
            && valid(recentZeroReturnsWithConnections, matching: { $0.zeroReturnWithConnectionContext })
            && valid(firstDropCounterIncreases, matching: { $0.observedDropCounterIncrease })
            && valid(recentDropCounterIncreases, matching: { $0.observedDropCounterIncrease })
    }
}

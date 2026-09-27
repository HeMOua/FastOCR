import Foundation

public struct SpeechSegment: Sendable {
    public let samples: [Float]
    public let endedAt: TimeInterval
    public let index: Int
    public var duration: TimeInterval { Double(samples.count) / 16_000 }
    public init(samples: [Float], endedAt: TimeInterval, index: Int) {
        self.samples = samples; self.endedAt = endedAt; self.index = index
    }
}

/// A bounded 16 kHz mono PCM buffer. Energy gating is deliberately not claimed to be perfect VAD.
public struct AudioSegmenter {
    private let sampleRate = 16_000
    private let threshold: Float
    private let maximum: Int
    private var current: [Float] = []
    private var preRoll: [Float] = []
    private var silentSamples = 0
    private var voicedSamples = 0
    private var lastReceived: TimeInterval?
    private var index = 0
    public init(threshold: Float = 0.006, maximumSeconds: Double = 3) {
        self.threshold = threshold
        maximum = Int(min(8, max(1, maximumSeconds)) * 16_000)
    }
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(Float(0)) { $0 + ($1.isFinite ? $1 * $1 : 0) } / Float(samples.count))
    }
    public var bufferedSampleCount: Int { current.count + preRoll.count }
    public mutating func append(_ samples: [Float], at now: TimeInterval) -> [SpeechSegment] {
        lastReceived = now
        var ready: [SpeechSegment] = []
        // Analyze in 20 ms blocks, independent of the device's callback size.
        for start in stride(from: 0, to: samples.count, by: 320) {
            let block = Array(samples[start..<min(start + 320, samples.count)]).map { $0.isFinite ? $0 : 0 }
            let loud = Self.rms(block) >= threshold
            if current.isEmpty && !loud {
                preRoll.append(contentsOf: block)
                if preRoll.count > 3200 { preRoll.removeFirst(preRoll.count - 3200) }
                continue
            }
            if current.isEmpty { current = preRoll; preRoll.removeAll(keepingCapacity: true) }
            current.append(contentsOf: block)
            if loud { voicedSamples += block.count; silentSamples = 0 }
            else { silentSamples += block.count }
            if current.count >= maximum || silentSamples >= 8000 {
                if let segment = finish(at: now) { ready.append(segment) }
            }
        }
        return ready
    }
    /// Some apps stop emitting buffers altogether when paused. Flush the final phrase too.
    public mutating func flushIfIdle(at now: TimeInterval) -> SpeechSegment? {
        guard let lastReceived, now - lastReceived >= 0.55, !current.isEmpty else { return nil }
        return finish(at: lastReceived)
    }
    private mutating func finish(at now: TimeInterval) -> SpeechSegment? {
        defer {
            current.removeAll(keepingCapacity: true)
            preRoll.removeAll(keepingCapacity: true)
            silentSamples = 0; voicedSamples = 0
        }
        guard voicedSamples >= 3200 else { return nil }
        // Keep 150 ms of trailing silence while avoiding silence-heavy inference.
        let trim = max(0, silentSamples - 2400)
        let samples = Array(current.prefix(max(0, current.count - trim)))
        index += 1
        return SpeechSegment(samples: samples, endedAt: now, index: index)
    }
}

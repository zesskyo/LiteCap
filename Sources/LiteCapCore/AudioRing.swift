import Foundation

/// Stereo (planar) Float32 FIFO between a capture callback and the audio render thread.
///
/// Different devices run on slightly different clocks, so the fill level slowly
/// drifts. When it grows past `maxLatency` the oldest audio is skipped; when it
/// runs dry the reader gets silence and waits to refill to `targetLatency`.
public final class AudioRing: @unchecked Sendable {
    private var left: [Float]
    private var right: [Float]
    private let capacity: Int
    private var readIndex = 0
    private var count = 0
    private var priming = true
    private let lock = NSLock()
    private let targetLatency: Int
    private let maxLatency: Int

    /// 40 ms cushion, trimmed back if it grows past 200 ms (clock drift).
    public init(capacityFrames: Int = 48_000, targetLatencyFrames: Int = 1_920, maxLatencyFrames: Int = 9_600) {
        capacity = capacityFrames
        left = Array(repeating: 0, count: capacityFrames)
        right = Array(repeating: 0, count: capacityFrames)
        targetLatency = targetLatencyFrames
        maxLatency = maxLatencyFrames
    }

    public var fillFrames: Int { lock.withLock { count } }

    /// `l` and `r` point to `frames` samples each (pass the same pointer twice for mono).
    public func write(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        var start = 0
        var n = frames
        if n > capacity { start = n - capacity; n = capacity }
        // Overflow: drop oldest.
        let overflow = count + n - capacity
        if overflow > 0 { advance(overflow) }
        var writeIndex = (readIndex + count) % capacity
        for i in 0..<n {
            left[writeIndex] = l[start + i]
            right[writeIndex] = r[start + i]
            writeIndex += 1
            if writeIndex == capacity { writeIndex = 0 }
        }
        count += n
        if count > maxLatency { advance(count - targetLatency) }
        if priming && count >= targetLatency { priming = false }
    }

    /// Always fills `frames` samples; silence where no data is available.
    public func read(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        if priming {
            l.update(repeating: 0, count: frames)
            r.update(repeating: 0, count: frames)
            return
        }
        let n = min(frames, count)
        for i in 0..<n {
            l[i] = left[readIndex]
            r[i] = right[readIndex]
            readIndex += 1
            if readIndex == capacity { readIndex = 0 }
        }
        count -= n
        if n < frames {
            (l + n).update(repeating: 0, count: frames - n)
            (r + n).update(repeating: 0, count: frames - n)
            priming = true // underrun: rebuild a small cushion before playing again
        }
    }

    public func reset() {
        lock.withLock {
            readIndex = 0
            count = 0
            priming = true
        }
    }

    private func advance(_ n: Int) {
        let k = min(n, count)
        readIndex = (readIndex + k) % capacity
        count -= k
    }
}

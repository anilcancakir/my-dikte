import AVFoundation
import Foundation
import Testing

@testable import MyDikte

/// The encoder's skip is a byte offset into a float32 PCM file, and getting it wrong is silent: an
/// offset that is not a multiple of four shifts every sample after it and turns the whole recording
/// into noise that still has the right duration and level. So the arithmetic is pinned here.
@Suite("AudioEncoder leading trim")
struct AudioEncoderTrimTests {
    private static let sampleRate: Double = 16_000

    /// A float32 mono PCM file: `silentSeconds` of zeros, then a full-scale square wave.
    private static func makePCM(silentSeconds: Double, toneSeconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim-\(UUID().uuidString).pcm")

        var samples: [Float] = Array(repeating: 0, count: Int(silentSeconds * sampleRate))
        let toneFrames = Int(toneSeconds * sampleRate)
        // A square wave rather than a sine: its value is never near zero, so a misaligned read shows
        // up as a change in level rather than hiding inside a gentle waveform.
        samples += (0..<toneFrames).map { $0 % 100 < 50 ? Float(0.5) : Float(-0.5) }

        try samples.withUnsafeBufferPointer { pointer in
            try Data(buffer: pointer).write(to: url)
        }
        return url
    }

    private static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    @Test("skipping nothing encodes the whole recording")
    func skippingNothingKeepsEverything() throws {
        let pcm = try Self.makePCM(silentSeconds: 1.0, toneSeconds: 3.0)
        let m4a = pcm.deletingPathExtension().appendingPathExtension("m4a")
        defer {
            try? FileManager.default.removeItem(at: pcm)
            try? FileManager.default.removeItem(at: m4a)
        }

        try AudioEncoder.encodeM4A(pcmFileURL: pcm, to: m4a)
        // AAC pads to a packet boundary, so this is a tolerance rather than an equality.
        #expect(abs(try Self.duration(of: m4a) - 4.0) < 0.1)
    }

    @Test("skipping the silent head removes exactly that much audio")
    func skippingTheHeadRemovesThatMuch() throws {
        let pcm = try Self.makePCM(silentSeconds: 1.85, toneSeconds: 6.29)
        let m4a = pcm.deletingPathExtension().appendingPathExtension("m4a")
        defer {
            try? FileManager.default.removeItem(at: pcm)
            try? FileManager.default.removeItem(at: m4a)
        }

        // The measured AirPods case: 1.85 s of digital silence, 1.70 s of it dropped after the pre-roll.
        try AudioEncoder.encodeM4A(pcmFileURL: pcm, to: m4a, skippingLeadingSeconds: 1.70)
        #expect(abs(try Self.duration(of: m4a) - (8.14 - 1.70)) < 0.1)
    }

    /// The alignment check. A skip that lands mid-sample would keep the duration right and destroy the
    /// samples, so this asserts on the decoded audio rather than on the length.
    @Test("the audio after a skip is intact, not shifted by a byte")
    func audioAfterASkipIsIntact() throws {
        let pcm = try Self.makePCM(silentSeconds: 1.0, toneSeconds: 2.0)
        let m4a = pcm.deletingPathExtension().appendingPathExtension("m4a")
        defer {
            try? FileManager.default.removeItem(at: pcm)
            try? FileManager.default.removeItem(at: m4a)
        }

        // Deliberately not a whole number of frames at this rate: 0.85 s is 13,600 frames, and a
        // fractional second is what would expose sloppy rounding.
        try AudioEncoder.encodeM4A(pcmFileURL: pcm, to: m4a, skippingLeadingSeconds: 0.85)

        let file = try AVAudioFile(forReading: m4a)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        else {
            Issue.record("could not allocate a read buffer")
            return
        }
        try file.read(into: buffer)

        guard let channel = buffer.floatChannelData?[0] else {
            Issue.record("decoded buffer had no float channel data")
            return
        }
        let frames = Int(buffer.frameLength)
        var peak: Float = 0
        for index in 0..<frames {
            peak = max(peak, abs(channel[index]))
        }

        // The square wave sits at 0.5, so a peak near it means the samples survived the offset. A
        // byte-shifted read of float32 data produces values orders of magnitude off, not 0.5.
        #expect(peak > 0.3, "peak was \(peak), so the skip did not land on a frame boundary")
        #expect(peak < 1.5, "peak was \(peak), which is not a 0.5 square wave")
    }
}

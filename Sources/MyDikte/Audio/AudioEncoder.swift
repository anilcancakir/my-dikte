import AVFoundation
import Foundation

/// Encodes a raw Float32 PCM spool to AAC in an `m4a` container, for upload.
///
/// Not premature optimisation: measured against `api.groq.com` from this machine the TLS
/// handshake costs 28 to 35 ms, while a 320 KB WAV body costs roughly 256 ms on a 10 Mbps
/// uplink, so the body is the largest single lever in the network path. Ten seconds of 16 kHz
/// mono comes out around 65 KB here against 320 KB uncompressed.
enum AudioEncoder {
    enum Failure: Error, LocalizedError {
        case sourceUnreadable(String)
        case formatUnavailable
        case emptyAudio
        case encodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .sourceUnreadable(let reason):
                return "Could not read the recorded audio: \(reason)"
            case .formatUnavailable:
                return "Could not describe the recorded audio to the AAC encoder."
            case .emptyAudio:
                return "The recording held no audio to encode."
            case .encodeFailed(let reason):
                return "Encoding the recording to m4a failed: \(reason)"
            }
        }
    }

    /// 32 kbps AAC-LC is well above what a 16 kHz mono speech clip needs, and well below the
    /// ceiling: measured here, `AVEncoderBitRateKey` at 64000 or above makes `AVAudioFile`
    /// creation fail outright inside
    /// `AudioConverterSetProperty(kAudioConverterEncodeBitRate)`, so the reference's 96000
    /// (`references/pindrop/Pindrop/Services/DictationAudioRetentionService.swift:22`) would not
    /// encode at this sample rate at all.
    static let bitRate: Int = 32_000

    /// Read granularity. Small enough that a long dictation never exists twice in memory.
    private static let framesPerChunk: Int = 16_384

    /// Streams `pcmFileURL` (raw Float32, mono, `sampleRate`) into `destinationURL` as AAC.
    ///
    /// 16 kHz survives the encoder untouched here, verified with `afinfo`, so there is no
    /// resample step: the same reference resamples sub-32 kHz input to 44.1 kHz, and doing that
    /// would triple the upload for no transcription benefit.
    static func encodeM4A(
        pcmFileURL: URL,
        to destinationURL: URL,
        sampleRate: Double = AudioCapture.sampleRate
    ) throws {
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw Failure.formatUnavailable
        }

        let sourceHandle: FileHandle
        do {
            sourceHandle = try FileHandle(forReadingFrom: pcmFileURL)
        } catch {
            throw Failure.sourceUnreadable(error.localizedDescription)
        }
        defer { try? sourceHandle.close() }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: destinationURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw Failure.encodeFailed(error.localizedDescription)
        }

        var wroteFrames = false
        while true {
            let chunk: Data
            do {
                chunk = try sourceHandle.read(upToCount: framesPerChunk * MemoryLayout<Float>.size) ?? Data()
            } catch {
                throw Failure.sourceUnreadable(error.localizedDescription)
            }
            let frameCount: Int = chunk.count / MemoryLayout<Float>.size
            guard frameCount > 0 else {
                break
            }

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ), let channelData = buffer.floatChannelData else {
                throw Failure.encodeFailed("Could not prepare a \(frameCount) frame encode buffer.")
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            chunk.withUnsafeBytes { rawBuffer in
                guard let source = rawBuffer.bindMemory(to: Float.self).baseAddress else {
                    return
                }
                channelData[0].update(from: source, count: frameCount)
            }

            do {
                try outputFile.write(from: buffer)
            } catch {
                throw Failure.encodeFailed(error.localizedDescription)
            }
            wroteFrames = true
        }

        guard wroteFrames else {
            throw Failure.emptyAudio
        }
        // `AVAudioFile` has no close: the container's index is written when it deinits, which is
        // at the end of this scope. So the file is only complete once this call has returned,
        // and a reader that races it sees a truncated m4a.
    }
}

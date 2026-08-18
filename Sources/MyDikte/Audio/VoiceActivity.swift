import Foundation

/// Decides whether a recording holds speech worth sending to a transcription API.
///
/// Absolute thresholds do not travel between microphones: one machine's built-in mic idles at
/// -70 dBFS in a quiet room, another clips the same room at -35. So every test here is relative
/// to the recording's own noise floor rather than to a fixed level.
/// Port of `references/dikte/dikte/vad.py:34-84`.
public struct VoiceActivity {
    /// The numbers `isSilent` decides from, derived from a recording's per-chunk RMS values.
    public struct Analysis: Equatable {
        /// 10th percentile of the sorted RMS values, in dB.
        public let noiseFloorDB: Double
        /// 90th percentile of the sorted RMS values, in dB.
        public let speechPeakDB: Double
        /// `speechPeakDB` minus `noiseFloorDB`.
        public let dynamicRangeDB: Double
        /// Duration covered by chunks whose level clears the noise floor by `marginDB`.
        public let voicedSeconds: Double
    }

    private init() {}

    /// Converts a linear RMS amplitude to dB, flooring non-positive input at -120 dB.
    public static func toDB(_ value: Double) -> Double {
        value > 0 ? 20 * log10(value) : -120.0
    }

    /// Reads the value at `fraction` through a pre-sorted array, matching the reference's
    /// nearest-rank percentile rather than an interpolated one.
    private static func percentile(_ sortedValues: [Double], fraction: Double) -> Double {
        guard !sortedValues.isEmpty else {
            return 0.0
        }

        let index: Int = min(sortedValues.count - 1, max(0, Int(Double(sortedValues.count) * fraction)))
        return sortedValues[index]
    }

    /// Turns per-chunk RMS levels into the numbers `isSilent` needs.
    public static func analyse(
        rmsValues: [Double],
        chunkSeconds: Double,
        marginDB: Double = 10.0
    ) -> Analysis {
        guard !rmsValues.isEmpty else {
            return Analysis(noiseFloorDB: -120.0, speechPeakDB: -120.0, dynamicRangeDB: 0.0, voicedSeconds: 0.0)
        }

        let ordered: [Double] = rmsValues.sorted()
        let noiseFloorDB: Double = toDB(percentile(ordered, fraction: 0.10))
        let speechPeakDB: Double = toDB(percentile(ordered, fraction: 0.90))

        // Anything this far above the recording's own floor counts as voice.
        let gateDB: Double = noiseFloorDB + marginDB
        let voicedCount: Int = rmsValues.filter { toDB($0) >= gateDB }.count

        return Analysis(
            noiseFloorDB: noiseFloorDB,
            speechPeakDB: speechPeakDB,
            dynamicRangeDB: speechPeakDB - noiseFloorDB,
            voicedSeconds: Double(voicedCount) * chunkSeconds
        )
    }

    /// True when the recording holds no speech worth sending to the API.
    ///
    /// Three independent reasons, any one of which is enough:
    ///   - the loud end of the recording is below the absolute floor
    ///   - nothing rose far enough above the noise floor for long enough
    ///   - the level never moved, meaning steady hiss, hum or fan noise
    public static func isSilent(
        _ analysis: Analysis,
        silenceDB: Double = -55.0,
        marginDB: Double = 10.0,
        minVoicedSeconds: Double = 0.3
    ) -> Bool {
        if analysis.speechPeakDB < silenceDB {
            return true
        }
        if analysis.voicedSeconds < minVoicedSeconds {
            return true
        }
        // Only distrust flat dynamics near the floor; a loud, evenly-spoken sentence
        // legitimately has a narrow range.
        if analysis.speechPeakDB < silenceDB + 12 && analysis.dynamicRangeDB < marginDB * 0.6 {
            return true
        }
        return false
    }
}

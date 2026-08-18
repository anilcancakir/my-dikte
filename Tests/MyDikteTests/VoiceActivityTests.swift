import Foundation
import Testing

@testable import MyDikte

@Suite("VoiceActivity")
struct VoiceActivityTests {
    /// Converts a dB level to the linear RMS amplitude `toDB` would report back, the inverse of the port under test.
    private static func amplitude(fromDB db: Double) -> Double {
        pow(10.0, db / 20.0)
    }

    @Test("pure silence is reported as silent")
    func pureSilenceIsSilent() {
        let rmsValues: [Double] = Array(repeating: 0.0, count: 20)
        let analysis: VoiceActivity.Analysis = VoiceActivity.analyse(rmsValues: rmsValues, chunkSeconds: 0.1)

        #expect(analysis.speechPeakDB == -120.0)
        #expect(VoiceActivity.isSilent(analysis))
    }

    @Test("a quiet steady hiss near the floor is silent via the dynamic-range test")
    func quietSteadyHissIsSilentViaDynamicRangeTest() {
        // dB values spread over a 2 dB band just above the floor (silenceDB = -55), so speechDB
        // clears the absolute floor test but stays inside `silenceDB + 12` for the third test.
        let dBValues: [Double] = (0..<20).map { index in
            -52.0 + (2.0 * Double(index) / 19.0)
        }
        let rmsValues: [Double] = dBValues.map(Self.amplitude(fromDB:))
        let analysis: VoiceActivity.Analysis = VoiceActivity.analyse(rmsValues: rmsValues, chunkSeconds: 0.1)

        // Confirms this is not the trivial case: the peak clears the absolute floor on its own.
        #expect(analysis.speechPeakDB > -55.0)
        #expect(analysis.dynamicRangeDB < 6.0)

        // minVoicedSeconds: 0 disables the duration test so the assertion isolates the third test.
        #expect(VoiceActivity.isSilent(analysis, minVoicedSeconds: 0.0))
    }

    @Test("a 0.2 second burst is silent via the duration test")
    func shortBurstIsSilentViaDurationTest() {
        let baseline: [Double] = Array(repeating: Self.amplitude(fromDB: -70.0), count: 10)
        let burst: [Double] = Array(repeating: Self.amplitude(fromDB: -20.0), count: 2)
        let analysis: VoiceActivity.Analysis = VoiceActivity.analyse(
            rmsValues: baseline + burst,
            chunkSeconds: 0.1
        )

        // Confirms neither the absolute floor test nor the dynamic-range test is what fires here.
        #expect(analysis.speechPeakDB >= -55.0)
        #expect(analysis.speechPeakDB >= -55.0 + 12.0)
        #expect(analysis.voicedSeconds < 0.3)

        #expect(VoiceActivity.isSilent(analysis))
    }

    @Test("a 0.5 second burst 20 dB above the floor is not silent")
    func longLoudBurstIsNotSilent() {
        let baseline: [Double] = Array(repeating: Self.amplitude(fromDB: -70.0), count: 45)
        let burst: [Double] = Array(repeating: Self.amplitude(fromDB: -50.0), count: 5)
        let analysis: VoiceActivity.Analysis = VoiceActivity.analyse(
            rmsValues: baseline + burst,
            chunkSeconds: 0.1
        )

        #expect(analysis.voicedSeconds == 0.5)
        #expect(!VoiceActivity.isSilent(analysis))
    }

    @Test("an empty RMS array does not crash and is reported as silent")
    func emptyInputDoesNotCrash() {
        let analysis: VoiceActivity.Analysis = VoiceActivity.analyse(rmsValues: [], chunkSeconds: 0.1)

        #expect(analysis.noiseFloorDB == -120.0)
        #expect(analysis.speechPeakDB == -120.0)
        #expect(analysis.dynamicRangeDB == 0.0)
        #expect(analysis.voicedSeconds == 0.0)
        #expect(VoiceActivity.isSilent(analysis))
    }

    @Test("toDB floors non-positive input at -120 dB")
    func toDBFloorsNonPositiveInput() {
        #expect(VoiceActivity.toDB(0.0) == -120.0)
        #expect(VoiceActivity.toDB(-1.0) == -120.0)
        #expect(abs(VoiceActivity.toDB(1.0) - 0.0) < 0.0001)
    }
}

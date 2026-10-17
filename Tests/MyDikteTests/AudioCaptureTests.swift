import Testing

@testable import MyDikte

/// Whether a configuration change during a recording cost it audio.
///
/// The regression it guards: opening a Bluetooth headset's microphone switches it from A2DP to the
/// hands-free profile, which posts `AVAudioEngineConfigurationChange` about 70 ms into the
/// recording. Treating every change as fatal failed each dictation on a UGREEN Studio Max2 while the
/// engine kept running and the recording was whole.
@Suite("AudioCapture configuration change")
struct AudioCaptureConfigurationChangeTests {
    @Test("an engine that kept running and a recording that kept pace lost nothing")
    func runningEngineWithAWholeRecordingLostNothing() {
        let lost = AudioCapture.configurationChangeLostAudio(
            engineWasRunning: true,
            wallClock: 7.30,
            duration: 7.24
        )

        #expect(!lost)
    }

    @Test("an engine the change stopped has lost everything after the stop")
    func stoppedEngineLostAudio() {
        let lost = AudioCapture.configurationChangeLostAudio(
            engineWasRunning: false,
            wallClock: 7.30,
            duration: 7.24
        )

        #expect(lost)
    }

    @Test("a running engine that stopped delivering is caught by the gap it leaves")
    func stalledEngineLostAudio() {
        let lost = AudioCapture.configurationChangeLostAudio(
            engineWasRunning: true,
            wallClock: 9.0,
            duration: 9.0 - AudioCapture.configurationStallToleranceSeconds - 0.1
        )

        #expect(lost)
    }

    @Test("the tolerance sits far above the measured capture lag")
    func toleranceClearsTheMeasuredLag() {
        // `evidence/step-08-cold-start.txt`: the file trails the wall clock by 10.7 to 71.4 ms.
        #expect(AudioCapture.configurationStallToleranceSeconds > 0.5)
    }
}

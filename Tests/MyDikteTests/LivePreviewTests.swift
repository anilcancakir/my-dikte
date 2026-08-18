import Foundation
import Speech
import Testing

@testable import MyDikte

/// The two pure decisions behind the live preview. Everything else about `LivePreview` is a
/// real-time audio path and a real recogniser, which are verified by hands-on QA in the signed
/// bundle instead: mocking `SFSpeechRecognizer` would produce confidence without coverage.
@Suite("Live preview readiness")
struct LivePreviewReadinessTests {
    /// Every input in the state a working machine reports, so each test below changes exactly one.
    private static func readiness(
        isEnabledInSettings: Bool = true,
        authorization: SFSpeechRecognizerAuthorizationStatus = .authorized,
        hasRecognizer: Bool = true,
        supportsOnDeviceRecognition: Bool = true,
        isRecognizerAvailable: Bool = true,
        hasAudioBuffers: Bool = true
    ) -> LivePreview.Readiness {
        LivePreview.readiness(
            isEnabledInSettings: isEnabledInSettings,
            authorization: authorization,
            hasRecognizer: hasRecognizer,
            supportsOnDeviceRecognition: supportsOnDeviceRecognition,
            isRecognizerAvailable: isRecognizerAvailable,
            hasAudioBuffers: hasAudioBuffers
        )
    }

    @Test("everything in place reports ready")
    func everythingInPlaceIsReady() {
        #expect(Self.readiness() == .ready)
        #expect(Self.readiness().isReady)
    }

    /// The setting is checked before anything else so that turning the preview off means no
    /// recogniser is created and no authorisation is read, let alone requested.
    @Test("the setting being off outranks every other input")
    func settingOffOutranksEverything() {
        #expect(Self.readiness(isEnabledInSettings: false) == .disabledBySetting)
        #expect(
            Self.readiness(
                isEnabledInSettings: false,
                authorization: .denied,
                hasRecognizer: false,
                supportsOnDeviceRecognition: false
            ) == .disabledBySetting
        )
    }

    @Test("an unresolved authorisation is not an authorisation")
    func notDeterminedIsNotAuthorised() {
        #expect(Self.readiness(authorization: .notDetermined) == .notAuthorised(.notDetermined))
    }

    @Test("a denied or restricted authorisation reports which of the two it was")
    func deniedAndRestrictedAreDistinguishable() {
        #expect(Self.readiness(authorization: .denied) == .notAuthorised(.denied))
        #expect(Self.readiness(authorization: .restricted) == .notAuthorised(.restricted))
    }

    @Test("a nil recogniser for the locale reports the recogniser as missing")
    func missingRecognizerIsReported() {
        #expect(Self.readiness(hasRecognizer: false) == .recognizerMissing)
    }

    /// `requiresOnDeviceRecognition` is only honoured when the recogniser supports it, so an
    /// unsupported locale must turn the preview off rather than let audio reach Apple's servers.
    @Test("no on-device support means no preview at all, and it outranks a flapping availability")
    func onDeviceUnavailableTurnsThePreviewOff() {
        #expect(Self.readiness(supportsOnDeviceRecognition: false) == .onDeviceRecognitionUnavailable)
        #expect(
            Self.readiness(
                supportsOnDeviceRecognition: false,
                isRecognizerAvailable: false
            ) == .onDeviceRecognitionUnavailable
        )
    }

    @Test("a recogniser that reports itself unavailable reports that")
    func unavailableRecognizerIsReported() {
        #expect(Self.readiness(isRecognizerAvailable: false) == .recognizerUnavailable)
    }

    @Test("a preview with no preallocated audio buffers cannot run")
    func missingAudioBuffersIsReported() {
        #expect(Self.readiness(hasAudioBuffers: false) == .audioBufferUnavailable)
    }

    /// A preview that does not appear has to say why in the log, and the privacy refusal has to
    /// name the boundary rather than read as a transient glitch.
    @Test("every not-ready reason carries a log message naming its cause")
    func everyReasonExplainsItself() {
        let reasons: [LivePreview.Readiness] = [
            .disabledBySetting,
            .notAuthorised(.denied),
            .notAuthorised(.notDetermined),
            .recognizerMissing,
            .onDeviceRecognitionUnavailable,
            .recognizerUnavailable,
            .audioBufferUnavailable,
        ]

        for reason in reasons {
            #expect(!reason.isReady)
            #expect(!reason.logMessage.isEmpty)
        }
        #expect(LivePreview.Readiness.notAuthorised(.denied).logMessage.contains("System Settings"))
        #expect(LivePreview.Readiness.onDeviceRecognitionUnavailable.logMessage.contains("on device"))
    }
}

/// The indicator is a 320-point panel in a screen corner, so the preview text needs a hard bound.
/// The rule is a tail: while speaking, the newest words are the ones being checked, and a head
/// truncation would freeze on the opening words and make the whole preview useless.
@Suite("Live preview display text")
struct LivePreviewDisplayTextTests {
    @Test("text within the limit is shown as it arrived")
    func shortTextIsUnchanged() {
        #expect(LivePreview.displayText("merhaba dünya") == "merhaba dünya")
    }

    @Test("text exactly at the limit is not truncated")
    func textAtTheLimitIsUnchanged() {
        let text = String(repeating: "a", count: LivePreview.displayCharacterLimit)

        #expect(LivePreview.displayText(text) == text)
    }

    @Test("longer text keeps its tail behind a leading ellipsis and never grows past the bound")
    func longTextKeepsItsTail() {
        let limit: Int = LivePreview.displayCharacterLimit
        let text = String(repeating: "a", count: limit) + "son kelime"

        let shown: String = LivePreview.displayText(text)

        #expect(shown.hasPrefix("…"))
        #expect(shown.hasSuffix("son kelime"))
        #expect(shown.count == limit + 1)
    }

    /// A partial result is one line today, but a newline in one would silently break the two-line
    /// budget the panel is drawn for, and the panel would start covering the screen corner.
    @Test("newlines and runs of whitespace collapse to single spaces")
    func whitespaceCollapses() {
        #expect(LivePreview.displayText("bir\niki") == "bir iki")
        #expect(LivePreview.displayText("bir   iki\t\tüç") == "bir iki üç")
        #expect(LivePreview.displayText("  kenarlar  ") == "kenarlar")
    }

    @Test("an empty partial result stays empty rather than becoming an ellipsis")
    func emptyStaysEmpty() {
        #expect(LivePreview.displayText("") == "")
        #expect(LivePreview.displayText("   ") == "")
    }

    /// Turkish is the whole point of this feature, so the bound counts characters the way a reader
    /// does. A byte or UTF-16 count would cut "ğ" in half and put a replacement glyph on screen.
    @Test("the bound counts characters, so Turkish letters are never cut in half")
    func turkishCharactersSurviveTruncation() {
        let limit: Int = LivePreview.displayCharacterLimit
        let text = String(repeating: "ğ", count: limit * 2)

        let shown: String = LivePreview.displayText(text)

        #expect(shown.count == limit + 1)
        #expect(shown.dropFirst().allSatisfy { $0 == "ğ" })
    }

    @Test("a custom limit is honoured, so the panel's bound lives in one place")
    func customLimitIsHonoured() {
        #expect(LivePreview.displayText("abcdef", limit: 3) == "…def")
    }
}

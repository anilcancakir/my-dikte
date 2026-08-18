import Foundation
import Testing

@testable import MyDikte

@Suite("TurkishFolding")
struct TurkishFoldingTests {
    @Test("dotless-i and dotted-capital-I fold to plain i, matching the measured probe outputs")
    func normaliseMatchesProbeOutputs() {
        #expect(TurkishFolding.normalise("Altyazı M.K.") == "altyazi mk")
        #expect(TurkishFolding.normalise("İzlediğiniz için teşekkürler") == "izlediginiz icin tesekkurler")
        #expect(TurkishFolding.normalise("  Abone   olmayı unutmayın!  ") == "abone olmayi unutmayin")
    }

    @Test("generic diacritic-insensitive folding alone does not fold dotless-i")
    func genericFoldingAloneIsInsufficient() {
        // Documents why the explicit map exists: without it, a later reader could
        // simplify TurkishFolding down to this call and silently break "Altyazı M.K.".
        let generic: String = "Altyazı M.K.".folding(options: .diacriticInsensitive, locale: nil).lowercased()
        #expect(generic != "altyazi mk")
    }
}

@Suite("HallucinationFilter")
struct HallucinationFilterTests {
    @Test("the phrase set carries all twenty-one entries from the reference")
    func phraseSetCountMatchesReference() {
        #expect(HallucinationFilter.phrases.count == 21)
    }

    @Test("a short Turkish stock phrase is caught")
    func shortStockPhraseIsCaught() {
        #expect(HallucinationFilter.looksLikeHallucination(text: "Altyazı M.K.", duration: 2.0))
    }

    @Test("the same stock phrase in a long recording is not caught")
    func longRecordingIsNotCaught() {
        #expect(!HallucinationFilter.looksLikeHallucination(text: "Altyazı M.K.", duration: 8.0))
    }

    @Test("a repetition of a single stock phrase is caught")
    func repeatedStockPhraseIsCaught() {
        #expect(
            HallucinationFilter.looksLikeHallucination(
                text: "Altyazı M.K. Altyazı M.K. Altyazı M.K.",
                duration: 3.0
            )
        )
    }

    @Test("the English stock phrase is caught")
    func englishStockPhraseIsCaught() {
        #expect(HallucinationFilter.looksLikeHallucination(text: "Thanks for watching", duration: 2.0))
    }

    @Test("a genuine short Turkish dictation is not caught")
    func genuineShortDictationIsNotCaught() {
        #expect(
            !HallucinationFilter.looksLikeHallucination(text: "toplantıyı perşembeye alalım", duration: 2.5)
        )
    }

    @Test("the empty string is caught")
    func emptyStringIsCaught() {
        #expect(HallucinationFilter.looksLikeHallucination(text: "", duration: 1.0))
    }
}

import Foundation
import Testing

@testable import MyDikte

/// The measured failure this guard exists for, and the cases that must stay allowed.
///
/// A cleanup model removes words and adds punctuation; it does not invent words. Checking that
/// invariant is what catches a same-length, same-position substitution such as Turkish "yine"
/// becoming English "again", which the glossary and word-count checks cannot see by construction.
@Suite("ParaphraseGuard introduced words")
struct ParaphraseGuardIntroducedWordTests {
    @Test("the measured yine-to-again substitution is rejected")
    func measuredSubstitutionIsRejected() {
        let raw = "production'da hani şu cache invalidation sorunu yine çıktı"
        let cleaned = "production'da again o cache invalidation sorunu çıktı"
        let result = ParaphraseGuard.check(
            raw: raw,
            cleaned: cleaned,
            glossary: ["cache invalidation"]
        )
        #expect(result != .accept)
    }

    @Test("a glossary term the model repaired into the text is allowed")
    func glossaryRepairIsAllowed() {
        // The cleanup prompt is explicitly asked to repair misheard technical terms, so a word
        // that appears only in the cleaned text is fine when the glossary vouches for it.
        let raw = "pikuti ile arayüzü bitirdim"
        let cleaned = "PyQt ile arayüzü bitirdim."
        let result = ParaphraseGuard.check(raw: raw, cleaned: cleaned, glossary: ["PyQt"])
        #expect(result == .accept)
    }

    @Test("splitting or joining a word the speaker said is allowed")
    func splittingAWordIsAllowed() {
        let raw = "sonra arayüzü şey bitirdim"
        let cleaned = "Sonra ara yüzü bitirdim."
        let result = ParaphraseGuard.check(raw: raw, cleaned: cleaned, glossary: [])
        #expect(result == .accept)
    }

    @Test("punctuation, casing and filler removal introduce no new words")
    func ordinaryCleanupIsAllowed() {
        let raw = "ıı bugün şey servisleri güncelledim yani"
        let cleaned = "Bugün servisleri güncelledim."
        let result = ParaphraseGuard.check(raw: raw, cleaned: cleaned, glossary: [])
        #expect(result == .accept)
    }

    @Test("a Turkish suffix added to a word the speaker said is allowed")
    func suffixedFormIsAllowed() {
        // "Redis" spoken, "Redis'in" written: the cleaned word contains a raw word, so it is
        // the same word wearing a suffix rather than a new one.
        let raw = "sonra Redis ayarını düşürdük"
        let cleaned = "Sonra Redis'in ayarını düşürdük."
        let result = ParaphraseGuard.check(raw: raw, cleaned: cleaned, glossary: [])
        #expect(result == .accept)
    }
}

@Suite("ParaphraseGuard")
struct ParaphraseGuardTests {
    @Test("a clean removal of fillers is accepted")
    func fillerRemovalIsAccepted() {
        let result = ParaphraseGuard.check(
            raw: "şey yani toplantıyı perşembeye pazartesiye plan yaparak alalım",
            cleaned: "Toplantıyı perşembeye pazartesiye plan yaparak alalım.",
            glossary: []
        )
        #expect(result == .accept)
    }

    @Test("a dropped glossary term is rejected")
    func droppedGlossaryTermIsRejected() {
        let result = ParaphraseGuard.check(
            raw: "Kubernetes clusterını yeniden başlattım",
            cleaned: "Cluster'ı yeniden başlattım.",
            glossary: ["Kubernetes"]
        )
        guard case .reject = result else {
            Issue.record("expected .reject, got \(result)")
            return
        }
    }

    @Test("an output half the length of the raw is rejected")
    func halvedOutputIsRejected() {
        let result = ParaphraseGuard.check(
            raw: "bir iki üç dört beş altı",
            cleaned: "bir iki üç",
            glossary: []
        )
        guard case .reject = result else {
            Issue.record("expected .reject, got \(result)")
            return
        }
    }

    @Test("an output twice the length of the raw is rejected")
    func doubledOutputIsRejected() {
        let result = ParaphraseGuard.check(
            raw: "bir iki üç",
            cleaned: "bir iki üç dört beş altı",
            glossary: []
        )
        guard case .reject = result else {
            Issue.record("expected .reject, got \(result)")
            return
        }
    }

    @Test("an empty output against a non-empty raw is rejected")
    func emptyOutputIsRejected() {
        let result = ParaphraseGuard.check(
            raw: "toplantıyı perşembeye alalım",
            cleaned: "",
            glossary: []
        )
        guard case .reject = result else {
            Issue.record("expected .reject, got \(result)")
            return
        }
    }

    @Test("a possessive suffix on a glossary term satisfies the substring check")
    func possessiveSuffixSatisfiesGlossaryTerm() {
        let result = ParaphraseGuard.check(
            raw: "Redis'in cache'ini temizledim",
            cleaned: "Redis'in cache'ini temizledim.",
            glossary: ["Redis"]
        )
        #expect(result == .accept)
    }
}

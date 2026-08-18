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

/// The guard reports what concerned it as data, and the user-facing sentence is derived from that
/// data. Nothing ever parses the sentence back out: counting how often a term is flagged across the
/// log has to survive a change of wording, and a prose reason cannot promise that.
@Suite("ParaphraseGuard concerns as data")
struct ParaphraseGuardConcernTests {
    @Test("an empty cleanup is its own kind and has no term")
    func emptyCleanupIsItsOwnKind() throws {
        let concern = try Self.concern(
            raw: "toplantıyı perşembeye alalım",
            cleaned: "",
            glossary: []
        )

        #expect(concern.kind == .emptyCleanup)
        #expect(concern.term == nil)
        #expect(concern.wordCounts == nil)
    }

    @Test("a dropped glossary term names the term, as the glossary spells it")
    func droppedGlossaryTermNamesTheTerm() throws {
        let concern = try Self.concern(
            raw: "Kubernetes clusterını yeniden başlattım",
            cleaned: "Cluster'ı yeniden başlattım.",
            glossary: ["Kubernetes"]
        )

        #expect(concern.kind == .droppedGlossaryTerm)
        #expect(concern.term == "Kubernetes")
    }

    @Test("growth past the tolerance is its own kind and carries both word counts")
    func growthCarriesItsCounts() throws {
        let concern = try Self.concern(
            raw: "bir iki üç",
            cleaned: "bir iki üç dört beş altı",
            glossary: []
        )

        #expect(concern.kind == .grewBeyondTolerance)
        #expect(concern.wordCounts == ParaphraseGuard.Concern.WordCounts(raw: 3, cleaned: 6))
        #expect(concern.term == nil)
    }

    @Test("an unexplained shrinkage is its own kind and carries both word counts")
    func shrinkageCarriesItsCounts() throws {
        let concern = try Self.concern(
            raw: "bir iki üç dört beş altı",
            cleaned: "bir iki üç",
            glossary: []
        )

        #expect(concern.kind == .droppedContent)
        #expect(concern.wordCounts == ParaphraseGuard.Concern.WordCounts(raw: 6, cleaned: 3))
    }

    /// The term is what the ledger counts and what the user would add to the glossary, so it has to
    /// arrive spelled the way the cleanup spelled it. The comparison inside the guard is done on a
    /// folded form ("faturalari"), and handing that to the glossary would suggest a misspelling.
    @Test("an introduced word names the word, spelled as the cleanup spelled it")
    func introducedWordKeepsItsSpelling() throws {
        let concern = try Self.concern(
            raw: "toplantıyı perşembeye alalım ve notları herkese gönderelim",
            cleaned: "toplantıyı perşembeye alalım ve faturaları herkese gönderelim",
            glossary: []
        )

        #expect(concern.kind == .introducedWord)
        #expect(concern.term == "faturaları")
    }

    @Test("the trailing punctuation of a flagged word is not part of the term")
    func introducedWordDropsTrailingPunctuation() throws {
        let concern = try Self.concern(
            raw: "toplantıyı perşembeye alalım ve notları herkese gönderelim",
            cleaned: "toplantıyı perşembeye alalım ve herkese gönderelim faturaları.",
            glossary: []
        )

        #expect(concern.term == "faturaları")
    }

    @Test("the four checks report four different kinds, so a reader never has to tell them apart by wording")
    func checksMapToDistinctKinds() throws {
        let kinds: [ParaphraseGuard.Concern.Kind] = [
            try Self.concern(raw: "toplantıyı perşembeye alalım", cleaned: "", glossary: []).kind,
            try Self.concern(
                raw: "Kubernetes clusterını yeniden başlattım",
                cleaned: "Cluster'ı yeniden başlattım.",
                glossary: ["Kubernetes"]
            ).kind,
            try Self.concern(raw: "bir iki üç", cleaned: "bir iki üç dört beş altı", glossary: []).kind,
            try Self.concern(raw: "bir iki üç dört beş altı", cleaned: "bir iki üç", glossary: []).kind,
            try Self.concern(
                raw: "toplantıyı perşembeye alalım ve notları herkese gönderelim",
                cleaned: "toplantıyı perşembeye alalım ve faturaları herkese gönderelim",
                glossary: []
            ).kind,
        ]

        #expect(Set(kinds).count == kinds.count)
    }

    @Test("the user-facing sentence is built from the data, term and counts included")
    func sentenceIsBuiltFromTheData() throws {
        let introduced = try Self.concern(
            raw: "toplantıyı perşembeye alalım ve notları herkese gönderelim",
            cleaned: "toplantıyı perşembeye alalım ve faturaları herkese gönderelim",
            glossary: []
        )
        let shrunk = try Self.concern(raw: "bir iki üç dört beş altı", cleaned: "bir iki üç", glossary: [])

        #expect(introduced.sentence.contains("\"faturaları\""))
        #expect(shrunk.sentence.contains("6 words became 3"))
    }

    /// The log is append-only, so a concern written by an older build can arrive without its counts.
    /// The sentence then says less rather than inventing a number.
    @Test("a concern with no counts still produces a sentence")
    func sentenceSurvivesMissingCounts() {
        let concern = ParaphraseGuard.Concern(kind: .droppedContent)

        #expect(concern.sentence.isEmpty == false)
        #expect(concern.sentence.contains("words became") == false)
    }

    private static func concern(
        raw: String,
        cleaned: String,
        glossary: [String]
    ) throws -> ParaphraseGuard.Concern {
        let result = ParaphraseGuard.check(raw: raw, cleaned: cleaned, glossary: glossary)
        guard case .concern(let concern) = result else {
            throw ConcernExpectationFailure.accepted
        }
        return concern
    }

    private enum ConcernExpectationFailure: Error {
        case accepted
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
        guard case .concern = result else {
            Issue.record("expected .concern, got \(result)")
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
        guard case .concern = result else {
            Issue.record("expected .concern, got \(result)")
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
        guard case .concern = result else {
            Issue.record("expected .concern, got \(result)")
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
        guard case .concern = result else {
            Issue.record("expected .concern, got \(result)")
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

    /// The measured case, verbatim from `evidence/step-06-guard-live-matrix.txt`: with the glossary
    /// configured, the default cleanup model repaired "pikutiyle" into "PyQt ile" on four runs out
    /// of four, and the guard rejected all four on the introduced-word check. The repair is the
    /// single measured accuracy win the glossary exists for, so rejecting it made the guard reject
    /// the behaviour the cleanup prompt explicitly asks for.
    @Test("the measured glossary repair that splits a Turkish postposition off is accepted")
    func measuredGlossaryRepairSplittingAPostpositionIsAccepted() {
        let result = ParaphraseGuard.check(
            raw: "Iıı bugün şey kubernetes üzerinde çalışan servisleri güncelledim yani sonra "
                + "grafana da bir panel açtım hani ve pikutiyle arayüzü şey bitirdim işte.",
            cleaned: "Bugün Kubernetes üzerinde çalışan servisleri güncelledim, sonra Grafana'da "
                + "bir panel açtım ve PyQt ile arayüzü bitirdim.",
            glossary: ["Kubernetes", "Grafana", "PyQt", "Redis", "staging"]
        )
        #expect(result == .accept)
    }

    /// Every member of the exemption list, one at a time, separated out of a sentence that does not
    /// contain it in any form. The fixture is a full dictation rather than a two-word fragment on
    /// purpose: at a one-third tolerance a two-word utterance cannot gain a word at all, so a short
    /// fixture tests the growth check instead of the check under test.
    @Test(
        "each Turkish clitic and postposition the cleanup can separate out is exempt",
        arguments: ["ile", "ise", "için", "gibi", "kadar"]
    )
    func separatedFunctionWordIsAccepted(functionWord: String) {
        let raw = "bugün toplantı vardı ve notları aldım sonra ofisten çıktım"
        let cleaned = "Bugün toplantı vardı ve notları aldım, sonra \(functionWord) ofisten çıktım."

        let result = ParaphraseGuard.check(raw: raw, cleaned: cleaned, glossary: [])
        #expect(result == .accept, "\"\(functionWord)\" should not read as an introduced word")
    }

    /// The natural shape of the measured failure, at dictation length: a run-together form that
    /// cleanup separates into a word plus its postposition, where the postposition is not a
    /// substring of the raw word and so the substring rule cannot account for it.
    /// The second measured instance of the same failure, from a real dictation on 2026-08-18. The user
    /// said "Speech to Text" twice; Whisper heard "Spish to Text"; the cleanup model repaired both,
    /// which is exactly what its prompt asks it to do; and this guard rejected the whole cleanup on the
    /// word "speech", so the user received the raw transcript with the error still in it.
    ///
    /// What separates that from the failure this check exists for: a repair replaces a mangled form with
    /// something that sounds like it, which is why the recogniser made the error in the first place. A
    /// translation replaces a real word with a foreign one that sounds nothing like it.
    @Test("a misheard technical term repaired into its real spelling is accepted")
    func phoneticRepairIsAccepted() {
        let result = ParaphraseGuard.check(
            raw: "bizim kullandığımız sistem sadece Spish to Text mi yapıyor yoksa prompt haline de getiriyor mu",
            cleaned: "Bizim kullandığımız sistem sadece Speech to Text mi yapıyor, yoksa prompt haline de getiriyor mu?",
            glossary: []
        )
        #expect(result == .accept)
    }

    /// Measured on a real dictation: the raw transcript had "hala" and the cleanup model wrote "hâlâ",
    /// the correct Turkish spelling with its circumflexes. The guard rejected the entire cleanup with
    /// "introduced a word that was not spoken: hâlâ", so the whole run fell back to the raw transcript
    /// over two diacritics. The phonetic exemption could not save it either: both words reduce to the
    /// two-consonant skeleton "hl", which is below the length floor by design.
    @Test("a Turkish circumflex added by cleanup is the same word, not a new one")
    func addedCircumflexIsNotAnIntroducedWord() {
        let result = ParaphraseGuard.check(
            raw: "bir de hala kurtaramadığım kelime var",
            cleaned: "Bir de hâlâ kurtaramadığım kelime var.",
            glossary: []
        )
        #expect(result == .accept)
    }

    @Test(
        "diacritic-only differences in either direction are accepted",
        arguments: [
            ("kar yagisi vardi", "kâr yağışı vardı"),
            ("rüzgâr çok kuvvetli", "rüzgar çok kuvvetli"),
        ]
    )
    func diacriticDifferencesAreAccepted(raw: String, cleaned: String) {
        #expect(ParaphraseGuard.check(raw: raw, cleaned: cleaned, glossary: []) == .accept)
    }

    /// Third measured instance, and it defeated the equal-length version of the phonetic rule. The user
    /// said "optimize", Whisper heard "optimizir", cleanup repaired it, and the guard rejected the whole
    /// cleanup because the skeletons differ in length: "ptmzr" against "ptmz". A repair routinely adds or
    /// drops a consonant, so the comparison has to allow an insertion or a deletion and not only a
    /// substitution.
    @Test("a repair that drops a trailing consonant is accepted")
    func repairChangingSkeletonLengthIsAccepted() {
        let result = ParaphraseGuard.check(
            raw: "bu sistem verilen metni Opus 5 için optimizir hale getirmek için nasıl çalışıyor",
            cleaned: "Bu sistem verilen metni Opus 5 için optimize hale getirmek için nasıl çalışıyor?",
            glossary: []
        )
        #expect(result == .accept)
    }

    @Test("a repair within one consonant of what was heard is accepted")
    func oneConsonantRepairIsAccepted() {
        let result = ParaphraseGuard.check(
            raw: "bunu kubernetis üzerinde çalıştırdım ve bütün loglara baktım",
            cleaned: "Bunu Kubernetes üzerinde çalıştırdım ve bütün loglara baktım.",
            glossary: []
        )
        #expect(result == .accept)
    }

    /// A known and accepted limit, recorded rather than papered over. "komit" to "commit" is two edits
    /// on the skeleton (`kmt` to `cmmt`: one substitution and one insertion), so the one-edit rule
    /// rejects it. Widening to two edits would start admitting real substitutions, and the glossary
    /// already licenses a term outright, so the answer for a term mangled this far is to name it in the
    /// glossary rather than to loosen the guard for everyone.
    @Test("a repair two consonants away is still rejected, and the glossary is the way through")
    func twoConsonantRepairNeedsTheGlossary() {
        let raw = "dosyayı komit ettim ve sonra pushladım hepsini"
        let cleaned = "Dosyayı commit ettim ve sonra pushladım hepsini."

        guard case .concern = ParaphraseGuard.check(raw: raw, cleaned: cleaned, glossary: []) else {
            Issue.record("expected .concern without a glossary")
            return
        }
        #expect(ParaphraseGuard.check(raw: raw, cleaned: cleaned, glossary: ["commit"]) == .accept)
    }

    /// The counterpart, and the reason the exemption cannot simply allow any single new word: this is the
    /// substitution the introduced-word check was built for, and it must still be caught. "again" sounds
    /// nothing like "yine", so a phonetic rule separates the two cases where a word count cannot.
    @Test("a Turkish word translated into English is still rejected")
    func translationIsStillRejected() {
        let result = ParaphraseGuard.check(
            raw: "yine aynı hatayı aldım ve bütün testleri baştan çalıştırdım",
            cleaned: "again aynı hatayı aldım ve bütün testleri baştan çalıştırdım",
            glossary: []
        )
        guard case .concern = result else {
            Issue.record("expected .concern, got \(result)")
            return
        }
    }

    @Test("a word with no phonetic relation to anything spoken is still rejected")
    func unrelatedInventionIsStillRejected() {
        let result = ParaphraseGuard.check(
            raw: "toplantıyı perşembeye alalım ve notları herkese gönderelim",
            cleaned: "toplantıyı perşembeye alalım ve faturaları herkese gönderelim",
            glossary: []
        )
        guard case .concern = result else {
            Issue.record("expected .concern, got \(result)")
            return
        }
    }

    @Test("a run-together form separated into a word plus its postposition is accepted")
    func separatedPostpositionFromRunTogetherFormIsAccepted() {
        let result = ParaphraseGuard.check(
            raw: "dün akşam toplantıya onunla gittim ve bütün notları aldım",
            cleaned: "Dün akşam toplantıya onun ile gittim ve bütün notları aldım.",
            glossary: []
        )
        #expect(result == .accept)
    }

    /// The exemption is a closed list of function words and must not become a general amnesty for
    /// short words: a three-letter Turkish content word swapped in is exactly the substitution the
    /// introduced-word check exists to catch, which is why the fix is a list and not a raised
    /// length threshold.
    @Test(
        "a three-letter Turkish content word substituted in is still rejected",
        arguments: [
            ("evde kar yağıyordu", "evde yol yağıyordu"),
            ("gözüme bir şey kaçtı", "kulağıma bir şey kaçtı"),
        ]
    )
    func shortContentWordSubstitutionIsRejected(raw: String, cleaned: String) {
        let result = ParaphraseGuard.check(raw: raw, cleaned: cleaned, glossary: [])
        guard case .concern = result else {
            Issue.record("expected .concern, got \(result)")
            return
        }
    }
}

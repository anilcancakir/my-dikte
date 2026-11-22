"""Tests for the pure parts of stt_bench: text normalisation, scoring, variant parsing and the request body."""

import unittest

import stt_bench


class NormaliseTests(unittest.TestCase):
    def test_turkish_capitals_fold_to_their_own_lowercase(self) -> None:
        self.assertEqual(stt_bench.normalise("İyi Işık"), ["iyi", "ışık"])

    def test_apostrophes_hyphens_and_punctuation_split_tokens(self) -> None:
        self.assertEqual(
            stt_bench.normalise("Kubernetes'e, real-time! WebSocket’e"),
            ["kubernetes", "e", "real", "time", "websocket", "e"],
        )


class EditCountTests(unittest.TestCase):
    def test_identical_text_has_no_edits(self) -> None:
        self.assertEqual(stt_bench.edit_count(["a", "b", "c"], ["a", "b", "c"]), 0)

    def test_substitution_deletion_and_insertion_cost_one_each(self) -> None:
        self.assertEqual(stt_bench.edit_count(["a", "b", "c"], ["a", "x", "c"]), 1)
        self.assertEqual(stt_bench.edit_count(["a", "b", "c"], ["a", "c"]), 1)
        self.assertEqual(stt_bench.edit_count(["a", "c"], ["a", "b", "c"]), 1)

    def test_empty_hypothesis_costs_the_whole_reference(self) -> None:
        self.assertEqual(stt_bench.edit_count(["a", "b"], []), 2)


class TermHitTests(unittest.TestCase):
    def test_exact_token_and_apostrophe_suffix_both_hit(self) -> None:
        self.assertTrue(stt_bench.term_hit("Redis üzerinden çalışıyor", "Redis"))
        self.assertTrue(stt_bench.term_hit("Grafana'da görünüyor", "Grafana"))

    def test_a_term_written_across_word_boundaries_still_hits(self) -> None:
        self.assertTrue(stt_bench.term_hit("bir web socket aç", "WebSocket"))
        self.assertTrue(stt_bench.term_hit("real-time güncelleme", "real time"))
        self.assertTrue(stt_bench.term_hit("memory leak var", "memory leak"))
        self.assertTrue(stt_bench.term_hit("Claude Code'a söyle", "Claude Code"))

    def test_a_longer_word_does_not_count_for_a_short_term(self) -> None:
        self.assertFalse(stt_bench.term_hit("açık window yok", "wind"))
        self.assertFalse(stt_bench.term_hit("dartta bir şey", "Dart"))

    def test_a_suffix_without_apostrophe_counts_from_five_letters(self) -> None:
        self.assertTrue(stt_bench.term_hit("kubernetese deploy et", "Kubernetes"))

    def test_a_long_tail_is_a_different_word_not_a_suffix(self) -> None:
        self.assertFalse(stt_bench.term_hit("statement yaz", "state"))
        self.assertFalse(stt_bench.term_hit("redistribute et", "Redis"))
        self.assertTrue(stt_bench.term_hit("kubernetesler çöktü", "Kubernetes"))

    def test_a_misheard_term_misses(self) -> None:
        self.assertFalse(stt_bench.term_hit("fakat bağlantısı koptu", "socket"))


class ScoreTests(unittest.TestCase):
    def test_score_counts_edits_words_and_term_hits(self) -> None:
        score = stt_bench.score(
            reference="Redis'e socket aç",
            terms=["Redis", "socket"],
            hypothesis="Redis'e fakat aç",
        )

        self.assertEqual(score.edits, 1)
        self.assertEqual(score.reference_words, 4)
        self.assertEqual(score.term_hits, 1)
        self.assertEqual(score.term_total, 2)


class VariantTests(unittest.TestCase):
    def test_a_bare_model_sends_no_terms_and_no_secondary_language(self) -> None:
        variant = stt_bench.parse_variant("v2")

        self.assertEqual(variant.model_id, "scribe_v2")
        self.assertEqual(variant.term_source, "none")
        self.assertEqual(variant.secondary_languages, [])

    def test_tokens_combine_model_terms_and_secondary_language(self) -> None:
        variant = stt_bench.parse_variant("v3+gl+en")

        self.assertEqual(variant.model_id, "scribe_v3")
        self.assertEqual(variant.term_source, "glossary")
        self.assertEqual(variant.secondary_languages, ["en"])
        self.assertEqual(variant.name, "v3+gl+en")

    def test_an_unknown_token_is_an_error_not_a_silent_default(self) -> None:
        with self.assertRaises(ValueError):
            stt_bench.parse_variant("v3+bogus")

    def test_a_missing_model_is_an_error(self) -> None:
        with self.assertRaises(ValueError):
            stt_bench.parse_variant("gl+en")


class KeytermTests(unittest.TestCase):
    def test_terms_the_api_would_reject_are_dropped_before_counting(self) -> None:
        terms = [
            "Redis",
            "x" * 51,
            "one two three four five six",
            "bad<term",
            "kodizm",
        ]

        self.assertEqual(stt_bench.eligible_keyterms(terms), ["Redis", "kodizm"])

    def test_the_list_is_capped_at_one_hundred(self) -> None:
        terms = [f"term{number}" for number in range(150)]

        self.assertEqual(len(stt_bench.eligible_keyterms(terms)), 100)


class MultipartTests(unittest.TestCase):
    def test_every_keyterm_is_its_own_part_and_the_file_carries_its_name(self) -> None:
        body = stt_bench.build_multipart(
            boundary="XBOUNDARY",
            fields=[
                ("model_id", "scribe_v3"),
                ("keyterms", "Redis"),
                ("keyterms", "kodizm"),
            ],
            file_field="file",
            filename="01.m4a",
            content=b"AUDIO",
        )

        self.assertEqual(body.count(b'name="keyterms"'), 2)
        self.assertIn(b'name="file"; filename="01.m4a"', body)
        self.assertIn(b"\r\n\r\nAUDIO\r\n", body)
        self.assertTrue(body.endswith(b"--XBOUNDARY--\r\n"))


class AudioVariantTests(unittest.TestCase):
    def test_a_filter_implies_pcm_and_keeps_the_order_it_was_written_in(self) -> None:
        variant = stt_bench.parse_variant("v3+names+hp+norm")

        self.assertEqual(variant.filters, ["hp", "norm"])
        self.assertTrue(variant.pcm)
        self.assertEqual(variant.term_source, "names")

    def test_pcm_alone_sends_the_decoded_clip_unfiltered(self) -> None:
        variant = stt_bench.parse_variant("v3+pcm")

        self.assertEqual(variant.filters, [])
        self.assertTrue(variant.pcm)

    def test_a_plain_variant_sends_the_clip_as_recorded(self) -> None:
        variant = stt_bench.parse_variant("v3+dev")

        self.assertFalse(variant.pcm)
        self.assertEqual(variant.term_source, "dev")

    def test_the_filter_chain_joins_the_filters_in_order(self) -> None:
        chain = stt_bench.filter_chain(["hp", "dn"])

        self.assertEqual(chain, f"{stt_bench.FILTERS['hp']},{stt_bench.FILTERS['dn']}")
        self.assertEqual(stt_bench.filter_chain([]), "")


class ListedRecallTests(unittest.TestCase):
    def test_hits_are_split_by_whether_the_term_was_sent_as_a_keyterm(self) -> None:
        outcome = stt_bench.score(
            reference="Redis'e socket aç",
            terms=["Redis", "socket"],
            hypothesis="Redis'e fakat aç",
            keyterms=["redis"],
        )

        self.assertEqual((outcome.hits_listed, outcome.total_listed), (1, 1))
        self.assertEqual((outcome.hits_unlisted, outcome.total_unlisted), (0, 1))
        self.assertEqual(outcome.unlisted_terms, ["socket"])
        self.assertEqual(outcome.hit_terms, ["Redis"])

    def test_a_keyterm_matches_a_term_whatever_its_spacing_and_case(self) -> None:
        outcome = stt_bench.score(
            reference="web socket",
            terms=["WebSocket"],
            hypothesis="WebSocket",
            keyterms=["Web Socket"],
        )

        self.assertEqual(outcome.total_listed, 1)


def make_row(variant: str, error: str | None, unlisted: list[str], hits: list[str]) -> stt_bench.Row:
    outcome = None
    if error is None:
        outcome = stt_bench.Score(
            edits=0,
            reference_words=1,
            term_hits=len(hits),
            term_total=1,
            hits_listed=0,
            total_listed=0,
            hits_unlisted=0,
            total_unlisted=len(unlisted),
            hit_terms=hits,
            unlisted_terms=unlisted,
            spurious_terms=[],
        )

    return stt_bench.Row(variant, "01", 1, "", 0.0, error, 0, outcome)


class PairedRecallTests(unittest.TestCase):
    def test_a_variant_is_compared_with_the_bare_one_on_the_terms_it_left_out(self) -> None:
        rows = [
            make_row("v3+gl", None, ["socket", "latency"], ["socket"]),
            make_row("v3", None, [], ["latency", "Redis"]),
        ]

        self.assertEqual(stt_bench.paired_unlisted_recall(rows, "v3+gl", "v3"), (1, 1, 2))

    def test_a_failed_call_is_left_out_of_both_sides(self) -> None:
        rows = [
            make_row("v3+gl", "HTTP 500", ["socket"], []),
            make_row("v3", None, [], ["socket"]),
        ]

        self.assertEqual(stt_bench.paired_unlisted_recall(rows, "v3+gl", "v3"), (0, 0, 0))


class GlossarySetTests(unittest.TestCase):
    SETS = {"names": ["Claude", "Redis"], "extras": ["Redis", "socket"]}

    def test_dev_is_the_names_then_the_extras_without_duplicates(self) -> None:
        terms = stt_bench.keyterms_for(stt_bench.parse_variant("v3+dev"), [], [], self.SETS)

        self.assertEqual(terms, ["Claude", "Redis", "socket"])

    def test_names_alone_and_the_apps_glossary_stay_separate(self) -> None:
        names = stt_bench.keyterms_for(stt_bench.parse_variant("v3+names"), ["x"], [], self.SETS)
        app = stt_bench.keyterms_for(stt_bench.parse_variant("v3+gl"), ["x"], [], self.SETS)

        self.assertEqual(names, ["Claude", "Redis"])
        self.assertEqual(app, ["x"])


class ProductionTermsTests(unittest.TestCase):
    def test_prod_is_the_users_glossary_then_the_names_each_once_whatever_the_case(self) -> None:
        sets = {"names": ["Claude", "Redis"], "extras": ["socket"]}

        terms = stt_bench.keyterms_for(stt_bench.parse_variant("v3+prod"), ["redis", "zzz"], [], sets)

        self.assertEqual(terms, ["redis", "zzz", "Claude"])


class ContentTypeTests(unittest.TestCase):
    def test_the_file_part_carries_the_content_type_it_is_given(self) -> None:
        body = stt_bench.build_multipart(
            boundary="XBOUNDARY",
            fields=[],
            file_field="file",
            filename="01.m4a",
            content=b"AUDIO",
            content_type="audio/mp4",
        )

        self.assertIn(b"Content-Type: audio/mp4\r\n\r\nAUDIO", body)


class SpuriousTermTests(unittest.TestCase):
    def test_a_keyterm_that_shows_up_without_being_spoken_is_spurious(self) -> None:
        outcome = stt_bench.score(
            reference="Redis aç",
            terms=["Redis"],
            hypothesis="Redis magic aç",
            keyterms=["Redis", "magic"],
        )

        self.assertEqual(outcome.spurious_terms, ["magic"])

    def test_a_keyterm_that_was_spoken_is_not_spurious(self) -> None:
        outcome = stt_bench.score(
            reference="magic aç",
            terms=[],
            hypothesis="magic aç",
            keyterms=["magic"],
        )

        self.assertEqual(outcome.spurious_terms, [])


class HeldOutGlossaryTests(unittest.TestCase):
    def test_devx_keeps_the_names_and_drops_extras_the_texts_score(self) -> None:
        texts = [stt_bench.TextItem(id="01", text="x", terms=["socket", "Redis"])]
        sets = {"names": ["Claude", "Redis"], "extras": ["socket", "agent"]}

        terms = stt_bench.keyterms_for(stt_bench.parse_variant("v3+devx"), [], texts, sets)

        self.assertEqual(terms, ["Claude", "Redis", "agent"])


if __name__ == "__main__":
    unittest.main()

"""Tests for the pure parts of record_clips: signal level, when a Bluetooth input goes live, and the leading trim."""

import unittest
from array import array

import record_clips


def silence(samples: int) -> array:
    return array("h", [0] * samples)


def tone(samples: int, level: int = 400) -> array:
    return array("h", [level] * samples)


class ChunkRmsTests(unittest.TestCase):
    def test_digital_silence_has_no_level(self) -> None:
        self.assertEqual(record_clips.chunk_rms(silence(320)), 0.0)

    def test_a_constant_signal_has_that_level(self) -> None:
        self.assertAlmostEqual(record_clips.chunk_rms(tone(320, level=100)), 100.0)


class FirstLiveSampleTests(unittest.TestCase):
    def test_all_zeros_is_never_live(self) -> None:
        self.assertIsNone(record_clips.first_live_sample(silence(16_000)))

    def test_the_first_loud_chunk_marks_the_start(self) -> None:
        samples = silence(640) + tone(320)

        self.assertEqual(record_clips.first_live_sample(samples), 640)

    def test_room_tone_under_the_floor_is_not_live(self) -> None:
        self.assertIsNone(record_clips.first_live_sample(tone(3_200, level=5)))


class TrimToLiveTests(unittest.TestCase):
    def test_the_zero_lead_in_is_cut_but_the_pre_roll_stays(self) -> None:
        samples = silence(16_000) + tone(3_200)

        trimmed = record_clips.trim_to_live(samples)

        self.assertEqual(len(trimmed), 3_200 + record_clips.PRE_ROLL_SAMPLES)
        self.assertEqual(trimmed[-1], 400)

    def test_a_clip_that_starts_live_is_kept_whole(self) -> None:
        samples = tone(3_200)

        self.assertEqual(record_clips.trim_to_live(samples), samples)

    def test_a_clip_that_never_went_live_is_empty(self) -> None:
        self.assertEqual(len(record_clips.trim_to_live(silence(16_000))), 0)


class SelectionTests(unittest.TestCase):
    def test_only_splits_the_requested_ids_and_trims_them(self) -> None:
        self.assertEqual(record_clips.parse_only("03, 01"), ["03", "01"])

    def test_no_selection_means_every_text(self) -> None:
        self.assertEqual(record_clips.parse_only(""), [])


if __name__ == "__main__":
    unittest.main()

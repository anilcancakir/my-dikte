# Scribe v3, keyterms and audio processing (2026-11-23)

Five recordings of the user reading five texts that mix Turkish with English developer terms
(`bench/stt/texts.json`), over AirPods, 8 to 21 s each, 45 scored terms in total. Every setting was
called three times per clip, interleaved, with `bench/stt/stt_bench.py run`. The request is the app's
own (`language_code=tr`, `no_verbatim`, one `keyterms` field per term). WER is word edits over reference
words, Turkish-aware, with apostrophes splitting words. "Listed" recall is the scored terms that were
also sent as keyterms; "unlisted" recall is the ones that were not. The transcripts are not reproduced.

## A. How many keyterms

| Setting | WER | Run range | Unlisted recall |
|---|---|---|---|
| v2, 5-term glossary (the setup before) | 34.1% | 33.7-34.9 | 50.8% |
| v3, no keyterms | 27.2% | 26.9-28.0 | 54.8% |
| v3, 5-term glossary | 22.5% | 20.6-24.0 | 57.5% |
| v3, 44 app names | 15.4% | 14.9-16.6 | 82.8% |
| v3, names plus 31 developer words | 13.1% | 13.1-13.1 | 69.2% |
| v2, names plus 31 developer words | 19.6% | 17.7-21.7 | 76.9% |

## B. Audio processing, on the names plus developer words list

The clips were AAC-encoded when recorded and every variant here ran on them decoded, so a filter is applied
after one AAC pass. The filtered variants are sent as PCM, so their baseline is the raw PCM row, not the AAC row.

| Setting | WER | Median s |
|---|---|---|
| AAC clip as recorded | 13.5% | 1.42 |
| raw PCM (`file_format=pcm_s16le_16`) | 14.5% | 1.53 |
| high-pass 80 Hz | 14.3% | 1.65 |
| loudness normalisation | 13.9% | 1.72 |
| speech normaliser | 15.2% | 1.71 |
| FFT denoise | 17.5% | 1.76 |
| high-pass and loudness | 15.0% | 1.92 |
| denoise and loudness | 16.8% | 1.65 |

## C. Does it generalise

The developer words overlap the test texts, so a second run removed from that list every word the texts
score (`devx`) and added a check for keyterms that appear without being spoken.

| Setting | WER | Run range | Unlisted recall | Same terms, v3 with no keyterms | Spurious keyterms |
|---|---|---|---|---|---|
| v3, 5-term glossary | 23.4% | 22.9-24.0 | 56.7% | 51.7% | 0 |
| v3, 44 app names | 15.2% | 13.1-17.7 | 83.9% | 69.0% | 0 |
| v3, names plus held-out words | 16.4% | 15.4-18.3 | 79.3% | 69.0% | 0 |
| v3, names plus all words | 13.3% | 13.1-13.7 | 69.2% | 53.8% | 0 |

## Reading

- The model and the names list are the two levers: v2 with five terms to v3 with 44 names is 34.1% to
  15.4%. The names list is the app's own `CleanupPrompt.names`, written before these texts existed.
- The names did not crowd out terms they did not list, and added no spurious terms, although most of the 44
  names are unspoken in any given clip (clip 01 speaks none, clip 05 two). Scribe v2 improved too with 75
  terms (34.1% to 19.6%). The README's earlier crowding measurements were on Whisper and an earlier Scribe v2
  setup, so how it scales on v3 with a much longer list of unspoken terms is not settled.
- Generic words on top added nothing once the test words were removed (16.4% against 15.2%, inside the
  run range). The gain of the full list is overlap with the test words.
- No audio processing helped on clips already encoded once: denoise scored 17.5% against 14.5% for the
  same PCM unfiltered, and the run ranges (17.1 to 18.3 against 13.7 to 15.4) do not overlap, so it
  probably hurt; the other filters sit within a point or two of PCM, inside the run spread. Filtering before the first encode and
  uploading the original capture as PCM were not tested. A PCM upload is documented as lower latency; here
  it was no faster.
- Production path, same clips, one run: `PipelineConfiguration` and `TranscriptionClient` with the user's
  settings sent `scribe_v3` and 48 keyterms (5 glossary terms and 43 names) and scored 16.0% WER, 40 of 45
  terms. The `prod` variant of the bench reproduces that term list.

## Limits

Five recordings, one speaker, one microphone (a Bluetooth headset in call mode, 16 kHz). The texts were
written from his vocabulary, so the names overlap the test words. Clip 01, the shortest, stayed near 45%
in every setting ("backoff'u exponential" came out as "lambda kafa expansion"). Realtime Scribe v3 Live
was not measured. The run-to-run spread reached 4.6 points on a single setting.

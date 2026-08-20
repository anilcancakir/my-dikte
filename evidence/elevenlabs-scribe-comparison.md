# ElevenLabs Scribe against Groq whisper-large-v3, on this user's own recordings

Measured 2026-08-21 on an M1 Pro, macOS 26.5.2, with a real ElevenLabs key. Every clip is a real
dictation this user spoke, pulled from `~/Library/Application Support/MyDikte/audio`, with Groq's
answer for the same clip read out of `log.jsonl` rather than re-requested. So the Groq column is what
the app actually produced at the time, warm connection and all.

Nine recordings, three of them long (14 to 27 s) and five in the median band (8 to 13 s), which is
where this user's dictations actually sit: median 9.9 s, mean 10.4 s over 44 logged runs.

## What was sent

Batch, `POST https://api.elevenlabs.io/v1/speech-to-text`:

```
model_id=scribe_v2
language_code=tur
tag_audio_events=false
timestamps_granularity=none
no_verbatim=true            (where stated)
keyterms=<one field per glossary term>   (where stated)
```

Realtime, `wss://api.elevenlabs.io/v1/speech-to-text/realtime`:

```
model_id=scribe_v2_realtime
audio_format=pcm_16000
commit_strategy=manual
language_code=tur
no_verbatim=true
keyterms=<one query item per glossary term>
```

The realtime clips were streamed at wall-clock speed in 50 ms chunks by a throwaway Swift probe, so
the timings below are what a person speaking into the microphone would have seen. `afconvert -f WAVE
-d LEI16@16000 -c 1` produced the PCM.

## Accuracy: ElevenLabs batch beats Groq on technical Turkish

The pattern is consistent and it is about English technical terms embedded in Turkish speech, which
is most of what this user dictates.

| Spoken | Groq whisper-large-v3 | ElevenLabs scribe_v2 |
|---|---|---|
| socket | *(dropped entirely)* | socket |
| API | AP | API |
| repository | repositor | repository |
| Groq | grok | Groq |
| hale getirmemiz | hareketimimiz | hale getirmemiz |
| güncellenmesi | güncellemlesin | güncellenmesi |

Groq's failures here are not near-misses, they are invented Turkish words: "güncellemlesin" and
"hareketimimiz" are not words. Scribe does not do that. On the 27 s technical recording Groq lost the
word "socket" from the opening question altogether, while Scribe returned "Hangi kısmı nasıl çalışıyor
socket kısmı?".

Neither model handled the hardest clip. The true sentence was "koruma bugün üç kez doğru bir
temizliği engelledi", and Groq returned "doğru bir çiftimizden geldi", batch Scribe "doğru bir sızma
izi engelledi", realtime Scribe "doğru bir temizliği engelledi". Realtime is the only one that got
it, and that is the single result pointing the other way in this whole file.

## Accuracy: the realtime model is materially worse, and that decided the architecture

`scribe_v2_realtime` degrades as the clip grows, because a streaming model commits with limited
lookahead while the batch model sees the whole recording.

| Recording | Batch scribe_v2 | Realtime scribe_v2_realtime |
|---|---|---|
| 27.3 s technical | "socket" correct, 4 occurrences | "fakat" in all 4 places |
| 21.6 s | "hale getirmemiz lazımdı" | "halde gitmemiz lazım gidiyor" |
| 21.6 s | "otomatik update olmasını istiyorum" | "olmasın istiyorum" (meaning inverted) |
| 12.7 s glossary-heavy | Kubernetes, Grafana, PyQt all present | "Kubernetes" dropped, PyQt to "File create" |
| 12.7 s | "Opus 5 için optimize" | "post-press için optimize" |

The last two are the damning ones: Kubernetes and PyQt were **in the keyterms list** the realtime
socket was opened with, and it still lost them. Passing keyterms helped it partially recover on the
27 s clip ("socket enable durumdaysa" and "real time socketlerinden" came back correct) but it never
reached the batch model's level.

Hence the split in the code: realtime feeds the preview, where being early beats being right, and
batch produces the text that reaches the caret.

## keyterms are not free wins

Same behaviour as Whisper's `prompt` field, which this project already measured: unrelated terms
crowd out relevant ones.

- 12.7 s clip: fixed "örneklerle" back to "önerilerle", and lifted per-word confidence 0.844 to 0.913.
- 27.3 s clip: fixed "web API" to "direkt bir API" and "yanına gelsin" to "real time socket üzerinden".
- 14.7 s clip: **made it worse**, turning "parafiz" into "power phase".
- 21.6 s clip: turned "lazım" into "lazımdı".

Two clear wins, one clear loss, one neutral-to-negative, at $0.05 per audio hour on top of the base
rate. Worth keeping for a short, focused glossary; not worth growing the glossary for.

## Latency: ElevenLabs batch is about twice Groq

Groq figures are `transcribeMs` from `log.jsonl`, so they include the warm shared connection the app
maintains. ElevenLabs figures are `curl`'s `time_total` on a cold connection each time, which flatters
Groq slightly; the gap is real regardless of that.

| Clip | Groq transcribe | Scribe v2 batch |
|---|---|---|
| 14.7 s | 454 ms | 1.11 s |
| 20.1 s | 652 ms | 1.57 s |
| 21.6 s | 580 ms | 1.02 s |
| 27.3 s | 871 ms | 3.02 s |

Median 616 ms against roughly 1.34 s.

## Latency: realtime removes the wait entirely

This is what realtime is actually for. Commit to committed transcript, measured on five recordings:

```
210 ms   217 ms   201 ms   267 ms   313 ms   192 ms   205 ms   308 ms   265 ms
```

Everything before that arrived while the user was still speaking. The first partial lands about 2.4 s
in, which matches ElevenLabs' documented "transcript processing starts after the first 2 seconds of
audio", and partials are rewritten in place as the model changes its mind, which is the behaviour the
user asked for by name.

## Per-word confidence is a real signal, and still only nine points

Scribe returns a `logprob` on every word. Taking the geometric mean (exponentiated mean log
probability, following LiveKit's `_speech_confidence`):

| Clip | Confidence | Transcript quality |
|---|---|---|
| 14.7 s hardest | 0.823 | worst of the set |
| 14.7 s + no_verbatim | 0.846 | still poor |
| 27.3 s | 0.913 | good |
| 21.6 s | 0.947 to 0.965 | very good |
| 20.1 s | 0.968 to 0.972 | very good |

The ordering is right: the lowest number is the worst transcript. It is still nine measurements, and
this project has already paid once for a threshold set from reasoning rather than data. The value is
logged and no threshold is enforced. See `TranscriptionResponse.wordConfidence`.

## Cost, against this user's real usage

44 logged runs: median 9.9 s, mean 10.4 s. ElevenLabs bills per audio minute at $0.22 per hour for
`scribe_v2` and $0.39 per hour for `scribe_v2_realtime`, keyterms $0.05 per hour on top.

| Usage | Batch only | Batch + keyterms | Plus realtime preview |
|---|---|---|---|
| 50 dictations a day | $0.95 / month | $1.17 / month | $2.86 / month |
| 100 dictations a day | $1.91 / month | $2.34 / month | $5.73 / month |

### Billing settled, from the account's own analytics

`POST /v1/workspace/analytics/query/usage-by-product-over-time` returns `total_usage` (credits),
`total_minutes`, `total_cost` (usd) and `usage_count` per one-minute bucket, capped at 1000 buckets
per query so a 24-hour window is rejected and an 8-hour one is not. One day of this project's own
traffic, probes included:

```
87 requests    16.10 min audio    778 credits    $0.0785
```

**The minimum billing unit is the second, not the minute.** 87 requests averaging 11.1 s billed as
16.10 minutes. Rounding each request up to a whole minute would have read 87 minutes; the ratio is
0.185. So the earlier worry that every cost figure here might multiply by six is closed: it does not.

**Credits per minute of speech to text is about 48, not the 330 the pricing page implies.** 778
credits for 16.10 minutes. That 330 figure describes the credit-metered Creative products, and
reading it as the API's STT rate understates the free tier by a factor of seven: 10,000 credits buys
roughly **207 minutes** of audio, not 30.

Blended cost came out at **$0.293 per hour**, which sits where it should between batch at $0.22 and
realtime at $0.39, since this day used both on the same audio.

### What the free tier actually covers

At this user's median 9.9 s dictation, with the realtime preview on (which bills the same audio a
second time):

| Dictations a day | Batch + preview | Batch only |
|---|---|---|
| 10 | 4,784 credits | 2,392 credits |
| 20 | 9,568 credits | 4,784 credits |
| 50 | 23,920 credits | 11,960 credits |
| 100 | 47,840 credits | 23,920 credits |

So the free 10,000 credits a month cover about **20 dictations a day with the preview on**, or 40
with it off. Beyond that the account needs credits bought.

`GET /v1/user/subscription` on this account reports `tier: free`, `max_credit_limit_extension: 0` and
`can_extend_character_limit: false`, which together mean usage-based billing is off: running out
stops the transcription rather than producing a bill.

Every plan's "hours included" is just the plan price divided by the hourly rate (27 x 0.22 = 5.94 for
the $6 Starter, 100 x 0.22 = 22 for the $22 Creator, 450 x 0.22 = 99 for the $99 Pro), so a plan buys
no discount over pay-as-you-go. Groq's free tier remains $0, so this is a bill accepted for accuracy,
not a saving.

## Reproducing

The probes were throwaway and are not in the repository. The batch side is one `curl` with the fields
listed above. The realtime side needs a WebSocket client that streams 16 kHz mono PCM16 in
base64 `input_audio_chunk` messages and sends `{"commit": true}` with an empty payload at the end;
`ElevenLabsLivePreview` is that client, and `audioChunkMessage` and `pcm16Data` are the two pieces
worth reusing.

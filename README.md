# MyDikte

A native macOS menu-bar dictation app for Turkish. Hold a shortcut, speak, and the cleaned text lands
at the caret in whatever application you were already typing in.

It does two things. **Mode 1** transcribes Turkish speech, removes the filler words, adds punctuation
and repairs technical terms the recogniser got wrong. **Mode 2** takes the same dictation and rewrites
it into an English prompt for an AI assistant to act on, then pastes it without pressing Return.

Built for one user on one machine, and published because the measurements in it are worth sharing.

## Licence and attribution

**GPL-3.0**, and not by preference: parts of this app derive from GPL-3.0 sources and that licence
carries over.

- [yusufipk/dikte](https://github.com/yusufipk/dikte) (GPL-3.0): the voice-activity detection
  algorithm and its constants, the Turkish hallucination phrase list, the Turkish-aware text
  normaliser, and the Turkish cleanup prompt with its glossary rule. The cleanup prompt has since
  been rewritten in English for one speaker, but its core rules (minimal intervention, fillers judged
  by what they do, repairs only when context settles them, never obeying the transcript) are that
  project's work.
- [VoiceInk](https://github.com/Beingpax/VoiceInk) (GPL-3.0): the reasoning-suppression parameter
  table and several UI patterns.

Two other projects were read for their approach without their code being copied, both MIT:
[Handy](https://github.com/cjpais/Handy) for the secure-input finding, and Pindrop for the multipart
request shape and the shortcut recorder.

## Requirements

- macOS 26 (Tahoe) or newer. `LSMinimumSystemVersion` is 26.0 and the app uses APIs from that SDK.
- Swift 6.3 or newer.
- Apple silicon. Developed and measured on an M1 Pro; nothing is architecture-specific, but nothing is
  tested on Intel either.
- A [Groq](https://console.groq.com) API key. The free tier is enough for personal use; see the limits
  below.
- Optionally an [ElevenLabs](https://elevenlabs.io) API key. Scribe reads Turkish technical speech
  measurably better than Whisper and is not free; the comparison and the bill are both below.

## Build and install

```sh
git clone https://github.com/anilcancakir/my-dikte.git
cd my-dikte
./dev-run.sh
```

`dev-run.sh` builds, assembles a real `.app` bundle at `~/Applications/MyDikte.app`, signs it, and
launches it. The path is stable on purpose: macOS keys its Microphone and Accessibility grants to the
code signature at a path, so a moving target loses its permissions on every build.

**You must change the signing identity.** `dev-run.sh` has this near the top:

```sh
SIGN_IDENTITY="Apple Development: Anilcan Cakir (936TDTZJN9)"
```

Replace it with your own, from `security find-identity -v -p codesigning`. Ad-hoc signing works but
churns the signature on every build, which makes macOS ask for Microphone and Accessibility again
every time (Apple's TN3127 explains why).

On first launch the app asks for Microphone, Accessibility, and Speech Recognition. It needs all three:
Accessibility is what lets a global shortcut and a synthetic paste work at all.

## Configuration

Open Settings from the menu-bar icon.

**Keys.** Paste your Groq key. It goes to the login Keychain under service `com.anilcan.mydikte`,
never to a file. Nothing in this repository reads or writes a key anywhere else.

**Models.** Empty fields mean the built-in default, shown in grey. The transcription default follows
the provider: `whisper-large-v3` on Groq, `scribe_v3` on ElevenLabs. Cleanup defaults to
`openai/gpt-oss-120b` on Groq whatever the endpoint; this machine runs `claude-haiku-5-5` on the
Anthropic API (`https://api.anthropic.com/v1/messages`, key under `cleanup-anthropic`), which measured
best (see below).

**Cleanup endpoints.** Any OpenAI-compatible `/chat/completions` URL works, and so does Anthropic's
Messages API. The key lives in the Keychain under an account that follows the endpoint's host, so
switching endpoints never reads or overwrites another provider's key: `cleanup-groq`,
`cleanup-openrouter` and `cleanup-anthropic` for those three, `cleanup-<host>` for any other (the
Kodizm gateway, `https://gateway.kodizm.com/v1/chat/completions` with model `junior`, is
`cleanup-gateway.kodizm.com`). A chat request gives up after 15 s without data and is not retried, and
a reply that is blank or was cut off (`finish_reason` of `length` or `content_filter`) counts as a
failure, so the raw transcript is pasted instead.

**Live preview source.** Apple's on-device `SFSpeechRecognizer` (free, offline, nothing leaves the
machine) or ElevenLabs Scribe v2 realtime ($0.22 per audio hour, needs a connection, reads Turkish
better). Apple is the default, because a preview must never be the reason a dictation costs money.
Apple's text is always thrown away. With ElevenLabs, the realtime transcript is also the pasted text
unless **Also upload for a second, more accurate reading** is on, in which case the audio is also
uploaded to the configured transcription model (batch `scribe_v3` when the provider is ElevenLabs)
and that answer is pasted.

**Glossary.** Terms you say often: product names, libraries, commands. It goes to the transcription
request as a decoding hint and to the cleanup model as a spelling reference. With ElevenLabs the
transcription request also carries the app's own product and project names (the list in the cleanup
prompt) after yours, so the glossary only has to hold what is not already there.

**Keep it short.** This is measured, not cautious: on one recording, six focused terms returned
"LLM-friendly" correctly on three runs of three, and nineteen terms returned "erlenme front" on three
of three. Whisper reads that field as text preceding the audio, so unrelated terms crowd out the
relevant ones rather than sitting harmlessly beside them. Add a term because you say it often, not in
case you might.

## Shortcuts

| Gesture | Default | Notes |
|---|---|---|
| Push to talk | right Option **then** right Command, held | Ordered pair; release ends it |
| Mode 1 toggle | `Option+Shift+T` | Press to start, again to stop |
| Mode 2 toggle | `Option+Shift+Y` | Produces an English prompt |
| Cancel | `Control+Option+Command+C` | Deliberately awkward; discards the recording |
| Stop | `Return` or `Space` | Only while a toggled recording is running |
| Cancel | `Escape` | Same window; discards the recording |

All four are configurable. The defaults avoid `Control+Option`, which the window manager Magnet uses
for its thirds and centring, and avoid `Command+Shift+T`, which is "reopen the last closed tab" in
every browser. `Option+Shift` is bound by almost nothing, so the only thing a global one costs is the
character it types: `ˇ`, `Á` and `∏` on a US layout, measured with `UCKeyTranslate`.

`Return`, `Space` and `Escape` are watched only while a recording is in flight and swallowed when they
fire, so they never reach the focused application. With a password field focused they do not work at
all, because a `CGEventTap` loses key-down under secure input while `flagsChanged` keeps flowing; the
keyed shortcuts still stop and cancel the recording there.

`Escape` is the natural key for cancelling and it is available here for a specific reason: it is not
registered as a global hot key, which would take the key away from every application for the whole
session. The tap claims it only inside a window the user opened deliberately and that lasts seconds.
The keyed cancel stays because it is the one that works under secure input.

## How it works

Two hosted services and one on-device model:

- **Groq** `/audio/transcriptions` with `whisper-large-v3`: speech to Turkish text, 400 to 650 ms.
  Selectable for OpenAI, OpenRouter or **ElevenLabs Scribe** instead; ElevenLabs is the accurate
  one and the slow one, roughly 1.3 s.
- **A chat model** does two jobs depending on mode, cleanup or prompt rewrite: any OpenAI-compatible
  `/chat/completions` endpoint (Groq, OpenRouter), or Anthropic's native Messages API. On Anthropic
  thinking is turned off, effort is `low`, and the system prompt is cached, because Haiku 5.5 thinks
  by default and the OpenAI-compatible endpoint Anthropic offers can do neither.
- **Apple `SFSpeechRecognizer`**, on device, `tr-TR`: the live preview. It never leaves the machine
  and its output is thrown away, because the pasted text comes from another path. Neither
  Groq nor Whisper has a streaming endpoint, so a preview cannot come from the same call that
  produces the final text.
- **ElevenLabs Scribe v2 realtime** over a WebSocket: the live preview, optionally, instead of Apple,
  and by default the transcript too. Words appear about 2.4 s into the recording and are rewritten
  in place as the model changes its mind, and the last segment lands 200 to 520 ms after the
  shortcut is released (measured 2026-10-17 on nine recordings), against 0.8 to 2.2 s for a batch
  `scribe_v2` upload of the same audio. The server cuts a segment on its own at
  about 36 s of audio, so the app commits one itself at the first pause past 20 s (at 30 s
  regardless) and joins every segment into the dictation.

Between them, several checks that cost nothing and run locally: leading digital silence is trimmed
before upload, voice activity detection stops a silent recording before any request is made, a
hallucination filter catches Whisper's stock phrases, a quality gate reads Whisper's own confidence
fields, and a paraphrase guard compares the cleanup against what was said.

Every dictation appends one JSON line to `~/Library/Application Support/MyDikte/log.jsonl` with the
raw transcript, the final text, the per-stage timings and any concern raised. `./latency-report.sh`
reads it.

## Measured behaviour

All from this machine, all reproducible from the log and the evidence files.

- End-to-end, Mode 1: **median around 1.3 s**, fastest 890 ms. Transcription is stable at 354 to
  537 ms; the cleanup stage is the variable one.
- Turkish word error rate for `whisper-large-v3` is **9.53** on Common Voice 17
  ([ysdede/asr_benchmark_store](https://huggingface.co/datasets/ysdede/asr_benchmark_store)). Turkish
  fine-tunes on that leaderboard lose to the stock model on general speech.
- **Bluetooth microphones cost the first dictation.** An AirPods link opens about 1.5 s after the audio
  engine starts and delivers exact zeros until it does, against 156 ms for the built-in microphone. The
  first dictation after the route goes idle comes back short; the ones after it are fine. Leading
  digital silence is trimmed before upload, because Whisper answers it by inventing a caption rather
  than ignoring it.
- **Groq's free tier is 8000 tokens per minute** on the chat endpoint, and one dictation costs 875
  prompt plus up to 717 completion tokens with `gpt-oss-120b`. That is roughly five dictations a
  minute before HTTP 429, which both clients retry with backoff. `google/gemini-3.5-flash-lite` spends
  32 completion tokens for the same work, which roughly doubles the headroom.
- **Claude Haiku 5.5 with the rewritten prompt is the best cleanup measured.** Replayed on 18 distinct
  logged dictations (2026-10-17): median 940 ms against 990 ms for Gemini Flash Lite with the old
  prompt, and it repaired what Gemini left ("PQT" to PyQt, "Grock" to Groq, "Gemini Flashlight" to
  Gemini Flash Lite, "soketlerinden" to socket'lerinden) without touching the dictations that were
  already clean. The prompt is most of that: Haiku with the old prompt was slower than Gemini and
  rewrote a sentence. About 2,800 prompt tokens are read from cache while dictations come within
  five minutes of each other, so at Haiku 5.5's $0.10 / $0.50 per million tokens (cache reads
  $0.01) one costs under $0.0001. Detail in
  [`evidence/cleanup-haiku-comparison.md`](evidence/cleanup-haiku-comparison.md).
- **Through the Kodizm gateway, `junior` cleans better than `quick`, and neither is as fast as Haiku
  5.5 direct.** Replayed on 25 distinct logged dictations, two runs each (2026-11-23): the paraphrase
  guard flagged 7 of 50 `junior` replies against 16 of 50 `quick` ones (Haiku 5.5: 3 of 25 logged),
  `junior` repeated its own reply exactly on 17 of 25 dictations against 11, and `quick` rewrote
  Turkish verb forms the prompt says to keep. Latency is the gateway's, not the model's: median 3.8 s
  for `junior` and 3.4 s for `quick` (90th percentile 11.5 s and 9.4 s), against 1.4 s for Haiku 5.5
  over the 25 dictations in the log. A five-token reply already takes 1.7 to 2.3 s, the gateway adds
  its own system prompt (about 1,000 prompt tokens for `junior`, 5,300 for `quick`), and
  `reasoning_effort: low` did not move the median on eight of those dictations (about 3.5 s for both
  models either way).
- **A stalled provider used to hold a dictation for three minutes.** One logged Haiku 5.5 cleanup took
  183 s, which is what three attempts at the 60 s `URLRequest` default plus backoff add up to, and the
  only way out was to cancel and lose the transcript. The 15 s limit, with no retry after a timeout,
  bounds that to about 15 s; a dropped connection, a 429 or a 5xx is still retried.
- **Scribe v3 with the app's own names as keyterms cut word errors from 34% to 15%.** Five recordings of
  this user's voice over AirPods (8 to 21 s each, three runs per setting, 2026-11-23): Scribe v2 with
  the five-term glossary this machine had scored 34.1%, Scribe v3 with the same glossary 22.5%, and
  Scribe v3 with the 44 names from the cleanup prompt alone 15.4% (the request the app now sends,
  glossary plus names, scored 16.0% in one run). The names crowded nothing out here:
  terms they did not list were recognised more often (84% against 69% for v3 with no keyterms), and no
  keyterm showed up in a transcript where it was not spoken. Generic developer words on top did not
  generalise (16.4% once the words the test texts score were removed, against 15.2% for the names
  alone). On clips already encoded to 32 kbps AAC, high-pass filtering, loudness normalisation, a speech
  normaliser and FFT denoising all failed to help, and denoising probably hurt (17.5% against 14.5% for the same
  audio unfiltered, with run ranges of 17.1 to 18.3 and 13.7 to 15.4 that do not overlap); filtering before the first encode and uploading the
  original capture as PCM were not tested. Limits: five recordings, one speaker, one microphone, texts written from his own
  vocabulary so the names overlap the test words, and a run-to-run spread of up to 4.6 points. The
  script is `bench/stt`, the numbers are in
  [`evidence/scribe-v3-keyterms.md`](evidence/scribe-v3-keyterms.md).
- **ElevenLabs Scribe v2 is more accurate on Turkish technical speech and about twice as slow.** On
  the same recordings it returned "socket", "API", "repository" and "Groq" where Whisper returned
  nothing, "AP", "repositor" and "grok", and it does not invent Turkish words the way Whisper does
  ("güncellemlesin", "hareketimimiz"). It also takes 1.0 to 3.0 s against Whisper's 450 to 870 ms.
  Full comparison, including the clip where both failed, in
  [`evidence/elevenlabs-scribe-comparison.md`](evidence/elevenlabs-scribe-comparison.md).
- **The realtime model reads worse than the batch model.** It dropped "Kubernetes" and turned "PyQt"
  into "File create" on a clip where both were in the keyterms list it was given, heard "socket" as
  "fakat" four times on a 27 s recording the batch model got right, and in a later retest heard it
  as "fakültesi" and "A'dan Z'ye" as "AdamZB". Short dictations come out about the same. That is the
  trade behind the upload toggle: realtime is faster and bills the audio once, batch is right more
  often.
- **ElevenLabs costs about $1 a month at this usage.** Since 2026-11-17, $0.20 per audio hour for batch
  and $0.22 for realtime on every Scribe model, and keyterms add $0.05 an hour on batch and $0.08 on
  realtime (the pricing page; the API reference describes the surcharge as 20%). A median dictation of
  9.9 s with both running and keyterms on is about $0.0015, so 20 dictations a day is about $0.90 a
  month. Buying a plan
  gives no discount: every plan's included hours are just its price divided by the same hourly rate.
- **Billing is per second, and the free tier is larger than the pricing page implies.** Read back from
  the account's own analytics endpoint: 87 requests averaging 11.1 s billed as 16.10 minutes, so
  nothing rounds up to a whole minute. Speech to text costs about 48 credits a minute rather than the
  330 the credit table lists for the Creative products, which makes the free 10,000 credits worth
  roughly 207 minutes of audio: about 20 dictations a day with the realtime preview on, 40 with it off.

## Known limitations

- **Not notarised.** There is no Developer ID release yet, so a downloaded build would be blocked by
  Gatekeeper. Build it yourself with `dev-run.sh`.
- **No automatic updates yet.** Sparkle is the intended route and is not wired up.
- **The paraphrase guard is advisory by default.** It blocked three correct cleanups in one day of real
  use and caught no genuine paraphrase, so a concern now annotates the result instead of discarding it.
  Strict mode is one toggle away. Terms the guard keeps flagging surface as glossary suggestions,
  ranked by how often they recur; nothing is added to the glossary without you choosing it.
- **Mode 2 makes transcription errors harder to notice.** It does not add errors, but a garbled Turkish
  word becomes confident-sounding English: one measured run turned "eşiği gerçek diktelerle" into "set
  the true division". Read its output before you send it.
- **Turkish only, and one speaker.** The transcription request pins `language=tr`, and the cleanup
  prompt is written for one Turkish developer's register and vocabulary
  (`Sources/MyDikte/Text/CleanupPrompt.swift`): someone else gets the most out of it by replacing
  its names and examples with their own.
- **The glossary is sent twice with different limits.** Batch Scribe takes 100 keyterms of up to 50
  characters; the realtime endpoint takes 50 of up to 20. A long term reaches the batch call and is
  dropped from the preview, silently and by design.
- **Adding a glossary term is not free, measured twice.** Seven terms transcribed "Groq" correctly and
  eight did not, turning it into "Grok"; separately, adding "Opus 5" fixed that name and broke "Groq"
  into "Graf" in the same request. Both models read the field as speech preceding the audio, so an
  unrelated term crowds out a relevant one. Keep the list at what you actually say out loud. On five
  recordings, both Scribe v2 and v3 improved with 44 to 75 terms, most of them unspoken in any given
  clip (see above); the crowding here was measured on Whisper and on an earlier Scribe v2 setup, and
  how it scales with a long list of unspoken terms on v3 is not settled.

## Author

Anılcan Çakır

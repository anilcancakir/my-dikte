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
  normaliser, and the Turkish cleanup prompt with its glossary rule. Those prompts are the product
  more than the code is, and they are that project's work.
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
- Optionally an [ElevenLabs](https://elevenlabs.io) API key. Scribe v2 reads Turkish technical speech
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

**Models.** Empty fields mean the built-in default, shown in grey, and the default follows the
provider: `whisper-large-v3` on Groq, `scribe_v2` on ElevenLabs. Cleanup defaults to
`openai/gpt-oss-120b` on Groq, though `google/gemini-3.5-flash-lite` through OpenRouter measured
better on all three axes (see below).

**Live preview source.** Apple's on-device `SFSpeechRecognizer` (free, offline, nothing leaves the
machine) or ElevenLabs Scribe v2 realtime ($0.39 per audio hour, needs a connection, reads Turkish
better). Apple is the default, because a preview must never be the reason a dictation costs money.
Either way the text that reaches the caret comes from the batch call, not the preview.

**Glossary.** Terms you say often: product names, libraries, commands. It goes to the transcription
request as a decoding hint and to the cleanup model as a spelling reference.

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

All four are configurable. The defaults avoid `Control+Option`, which the window manager Magnet uses
for its thirds and centring, and avoid `Command+Shift+T`, which is "reopen the last closed tab" in
every browser. `Option+Shift` is bound by almost nothing, so the only thing a global one costs is the
character it types: `ˇ`, `Á` and `∏` on a US layout, measured with `UCKeyTranslate`.

`Return` and `Space` are watched only while a recording is in flight and swallowed when they fire, so
they never reach the focused application. With a password field focused they do not work at all,
because a `CGEventTap` loses key-down under secure input while `flagsChanged` keeps flowing; the keyed
shortcut still stops the recording there.

## How it works

Two hosted services and one on-device model:

- **Groq** `/audio/transcriptions` with `whisper-large-v3`: speech to Turkish text, 400 to 650 ms.
  Selectable for OpenAI, OpenRouter or **ElevenLabs Scribe v2** instead; ElevenLabs is the accurate
  one and the slow one, roughly 1.3 s.
- **Groq** `/chat/completions`: the same model does two jobs depending on mode, cleanup or prompt
  rewrite. Swappable for any OpenAI-compatible endpoint.
- **Apple `SFSpeechRecognizer`**, on device, `tr-TR`: the live preview. It never leaves the machine
  and its output is thrown away, because the authoritative text comes from the batch path. Neither
  Groq nor Whisper has a streaming endpoint, so a preview cannot come from the same call that
  produces the final text.
- **ElevenLabs Scribe v2 realtime** over a WebSocket: the live preview, optionally, instead of Apple.
  Words appear about 2.4 s into the recording and are rewritten in place as the model changes its
  mind, and the last segment lands roughly 210 ms after the shortcut is released. Its text is still
  thrown away: measured on nine recordings the realtime model is worse than the batch model at the
  thing that matters here, so the preview is early and the paste is right.

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
- **ElevenLabs Scribe v2 is more accurate on Turkish technical speech and about twice as slow.** On
  the same recordings it returned "socket", "API", "repository" and "Groq" where Whisper returned
  nothing, "AP", "repositor" and "grok", and it does not invent Turkish words the way Whisper does
  ("güncellemlesin", "hareketimimiz"). It also takes 1.0 to 3.0 s against Whisper's 450 to 870 ms.
  Full comparison, including the clip where both failed, in
  [`evidence/elevenlabs-scribe-comparison.md`](evidence/elevenlabs-scribe-comparison.md).
- **The realtime model is not a substitute for the batch model.** It dropped "Kubernetes" and turned
  "PyQt" into "File create" on a clip where both were in the keyterms list it was given, and heard
  "socket" as "fakat" four times on a 27 s recording the batch model got right. That measurement is
  why the preview and the final text come from different calls.
- **ElevenLabs costs about $1 to $2 a month at this usage.** $0.22 per audio hour for batch, $0.39 for
  realtime, $0.05 on top for keyterms, against a measured median dictation of 9.9 s. Buying a plan
  gives no discount: every plan's included hours are just its price divided by the same hourly rate.

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
- **Turkish only**, in the sense that the prompts and the glossary rule are written in Turkish. The
  transcription request pins `language=tr`.
- **ElevenLabs' minimum billing unit is unverified.** The docs say "billed per audio minute" without
  saying whether a 10 s request is billed as 10 s or rounded up to a minute. If it rounds, the monthly
  figures above multiply by about six.
- **The glossary is sent twice with different limits.** Batch Scribe takes 100 keyterms of up to 50
  characters; the realtime endpoint takes 50 of up to 20. A long term reaches the batch call and is
  dropped from the preview, silently and by design.

## Author

Anılcan Çakır

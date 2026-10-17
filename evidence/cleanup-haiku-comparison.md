# Cleanup: Claude Haiku 5.5 against Gemini Flash Lite, on this user's own dictations

Measured 2026-10-17 from this machine. Every distinct Mode 1 raw transcript in `log.jsonl` (18) was
sent three ways, each with the user's glossary (prompt, Dart, commit, cache, deploy):

- **A**: `google/gemini-3.5-flash-lite` via OpenRouter, the previous prompt, `temperature` 0.3,
  `reasoning_effort` minimal. The production setup until this change.
- **B**: `claude-haiku-5-5` via the Messages API, the previous prompt.
- **C**: `claude-haiku-5-5` via the Messages API, the rewritten prompt. Thinking disabled, effort
  `low`, no `temperature`, system prompt cached.

## Latency (request round trip, ms)

| | A | B | C |
|---|---|---|---|
| median | 990 | 1145 | 939 |
| min | 704 | 869 | 689 |
| max | 1328 | 1491 | 1137 |

C after the first request: 2801 tokens read from cache, 138 uncached input,
7 to 178 output tokens. No request failed in any setup.

## Where A and C differ

Fragments only: the transcripts are the user's real dictations and are not reproduced here. 10 of the
18 came back differently; the other 8 were identical from both.

| # | Raw fragment | A (Gemini, old prompt) | C (Haiku, new prompt) |
|---|---|---|---|
| 0 | "PQT ile arayüzü" | PQT ile | PyQt ile |
| 1 | "soketlerinden ... endpoint atmanız" | soketlerinden, atmanız | socket'lerinden, açmanız |
| 3 | "promptlu speech to text" | promptlu speech to text | prompt'lu speech-to-text |
| 4 | "Grock'un ... Gemini Flashlight" | Grok'un, Gemini Flashlight | Groq'un, Gemini Flash Lite |
| 5 | "real time güncellensin" | real time | real-time |
| 9 | "Grok'un limitini" (rate limit, beside Gemini) | Grok'un | Groq'un |
| 11 | "komut edip, bir deneyelim" | commit edip bir | commit edip, bir |
| 14 | "data centerde", a long run-on sentence | data center'da, colon added | data center'da, sentence kept |
| 15 | a quoted song line, then real text | lyric kept, quotes dropped | lyric and quotes kept |
| 16 | two garbled lyric sentences, then real text, "4.25" | lyrics dropped, 4.25 | lyrics dropped, 4,25 |

## Reading

C fixed what A left: PyQt, Groq, Gemini Flash Lite, socket'lerinden, açmanız and the Turkish
decimal comma; both dropped the garbled lyrics at the head of #16. C kept the coherent quoted lyric
in #15, which the prompt's "when unsure, keep it" rule asks for, and kept a comma A removed in #11.
B is not listed; with the previous prompt Haiku was slower than A and rewrote #14, so the gain is the
prompt as much as the model.

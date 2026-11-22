"""Compares ElevenLabs Scribe models on clips of a fixed set of Turkish developer texts.

    python3 stt_bench.py texts          print the texts to read aloud
    python3 stt_bench.py run [options]  transcribe ~/stt-bench/clips/NN.<ext> and score every variant

A clip is named after its text id (01.m4a, 02.wav, ...). The script sends what the app sends (`language_code=tr`,
`no_verbatim`, one `keyterms` field per term), so a variant differs from production only in what it names.

A variant is a model plus options joined with "+": `v2` or `v3`, then a keyterm source, `en`, `pcm` and audio
filters. Keyterm sources: `gl` the glossary from the app's settings; `names` the app's own product and project
names; `prod` the glossary plus the names exactly as the app sends them; `dev` the names plus common developer
words; `devx` the same without the words the texts score, to see whether extra words help terms they do not
name; `all` every scored term of every text, an upper bound. `en` sends `secondary_language_codes=en`, which
only Scribe v3 reads. `pcm` sends the clip decoded to raw 16 kHz PCM (`file_format=pcm_s16le_16`). The audio
filters are `hp` high-pass, `norm` loudness, `sn` speech normaliser and `dn` denoise, and imply `pcm`; they run on
the decoded clip, which was already AAC-encoded when it was recorded. Example: `v3+prod+hp+norm`.
`names` and `dev` come from glossaries.json; `names` mirrors `CleanupPrompt.names` in the app.
"""

import argparse
import http.client
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path

API_URL = "https://api.elevenlabs.io/v1/speech-to-text"
KEYCHAIN_SERVICE = "com.anilcan.mydikte"
KEYCHAIN_ACCOUNT = "transcription-elevenlabs"
SETTINGS_PATH = Path.home() / "Library" / "Application Support" / "MyDikte" / "settings.json"
DEFAULT_ROOT = Path.home() / "stt-bench"
TEXTS_PATH = Path(__file__).with_name("texts.json")
GLOSSARIES_PATH = Path(__file__).with_name("glossaries.json")
AUDIO_EXTENSIONS = (".m4a", ".wav", ".mp3", ".aac", ".mp4", ".caf", ".aiff", ".flac", ".ogg")
REQUEST_TIMEOUT_SECONDS = 90

MODELS = {
    "v2": "scribe_v2",
    "v3": "scribe_v3",
}
TERM_SOURCES = {
    "gl": "glossary",
    "names": "names",
    "dev": "dev",
    "devx": "dev-held-out",
    "prod": "production",
    "all": "texts",
}
# Applied in the order they are written; every one is an ffmpeg audio filter that keeps speech and changes level
# or noise only, so each could be done in the app before encoding.
FILTERS = {
    "hp": "highpass=f=80",
    "norm": "loudnorm=I=-20:TP=-2:LRA=11",
    "sn": "speechnorm=e=6:r=0.0001:l=1",
    "dn": "afftdn=nf=-25",
}
SECONDARY_LANGUAGES = {
    "en": "en",
}
DEFAULT_VARIANTS = ["v2+gl", "v3+gl", "v3+names", "v3+dev"]

KEYTERM_LIMIT = 100
KEYTERM_CHARACTER_LIMIT = 50
KEYTERM_WORD_LIMIT = 5
KEYTERM_FORBIDDEN_CHARACTERS = frozenset("<>{}[]\\")

# A term written across word boundaries ("web socket", "real-time") still counts, up to this many tokens.
TERM_MAX_TOKENS = 5
# From this many letters a suffix without an apostrophe still counts ("kubernetese"); below it "wind" would
# match "window", so a short term has to be a whole token.
TERM_STEM_MIN_LENGTH = 5
# The longest tail that still reads as a Turkish suffix ("kubernetesler"); a longer one is another word.
TERM_SUFFIX_MAX_LENGTH = 3

_TURKISH_CASE = str.maketrans({"İ": "i", "I": "ı"})


@dataclass(frozen=True)
class TextItem:
    """One text to read aloud and the terms scored in it."""

    id: str
    text: str
    terms: list[str]


@dataclass(frozen=True)
class Variant:
    """One way of calling the API: a model, where its keyterms come from, its secondary languages and its audio."""

    name: str
    model_id: str
    term_source: str
    secondary_languages: list[str]
    filters: list[str]
    pcm: bool


@dataclass(frozen=True)
class Score:
    """Word edits against the reference and which of its scored terms the hypothesis contains.

    A term is "listed" when it was also sent as a keyterm. Unlisted recall is the crowding check: the terms the
    variant was not told about, which a long keyterm list may push out. A spurious term is a keyterm that appears
    in the hypothesis although the text never said it: the false-positive side of biasing.
    """

    edits: int
    reference_words: int
    term_hits: int
    term_total: int
    hits_listed: int
    total_listed: int
    hits_unlisted: int
    total_unlisted: int
    hit_terms: list[str]
    unlisted_terms: list[str]
    spurious_terms: list[str]


@dataclass(frozen=True)
class Audio:
    """What is uploaded for one clip and variant: the bytes, the file name and the fields that describe them."""

    content: bytes
    filename: str
    fields: list[tuple[str, str]]
    content_type: str


@dataclass(frozen=True)
class Transcription:
    """A reply: its text and wall-clock seconds, or the reason it failed."""

    text: str
    seconds: float
    error: str | None


@dataclass(frozen=True)
class Row:
    """One call of one variant on one clip in one run; `outcome` is None when the call failed."""

    variant: str
    id: str
    run: int
    text: str
    seconds: float
    error: str | None
    keyterms_sent: int
    outcome: Score | None


def normalise(text: str) -> list[str]:
    """Lowercases with Turkish rules and splits on everything that is not a letter or digit.

    Apostrophes split too, so "Kubernetes'e" is two tokens and the model's apostrophe habit is scored as words.
    """
    return re.findall(r"[^\W_]+", text.translate(_TURKISH_CASE).lower())


def edit_count(reference: list[str], hypothesis: list[str]) -> int:
    """Word-level Levenshtein distance: substitutions, deletions and insertions cost one each."""
    previous = list(range(len(hypothesis) + 1))
    for row, reference_word in enumerate(reference, start=1):
        current = [row]
        for column, hypothesis_word in enumerate(hypothesis, start=1):
            current.append(
                min(
                    previous[column] + 1,
                    current[column - 1] + 1,
                    previous[column - 1] + (reference_word != hypothesis_word),
                )
            )
        previous = current

    return previous[-1]


def term_hit(transcript: str, term: str) -> bool:
    """Whether `transcript` contains `term`, ignoring where the model put its spaces, hyphens and apostrophes."""
    tokens = normalise(transcript)
    target = "".join(normalise(term))
    if not target:
        return False

    for start in range(len(tokens)):
        joined = ""
        for token in tokens[start:start + TERM_MAX_TOKENS]:
            joined += token
            if joined == target:
                return True
            if len(joined) >= len(target):
                tail = len(joined) - len(target)
                if len(target) >= TERM_STEM_MIN_LENGTH and joined.startswith(target) and tail <= TERM_SUFFIX_MAX_LENGTH:
                    return True
                break

    return False


def term_key(term: str) -> str:
    """A term with its case, spacing and punctuation removed, so "Web Socket" and "websocket" are one key."""
    return "".join(normalise(term))


def score(reference: str, terms: list[str], hypothesis: str, keyterms: list[str] | None = None) -> Score:
    reference_tokens = normalise(reference)
    sent = {term_key(term) for term in keyterms or []}
    hit_terms = [term for term in terms if term_hit(hypothesis, term)]
    unlisted_terms = [term for term in terms if term_key(term) not in sent]
    spurious_terms = [
        term for term in keyterms or [] if term_hit(hypothesis, term) and not term_hit(reference, term)
    ]

    return Score(
        edits=edit_count(reference_tokens, normalise(hypothesis)),
        reference_words=len(reference_tokens),
        term_hits=len(hit_terms),
        term_total=len(terms),
        hits_listed=sum(term_key(term) in sent for term in hit_terms),
        total_listed=len(terms) - len(unlisted_terms),
        hits_unlisted=sum(term in unlisted_terms for term in hit_terms),
        total_unlisted=len(unlisted_terms),
        hit_terms=hit_terms,
        unlisted_terms=unlisted_terms,
        spurious_terms=spurious_terms,
    )


def paired_unlisted_recall(rows: list["Row"], variant: str, bare: str) -> tuple[int, int, int]:
    """On the terms `variant` was not told about: its hits, the bare variant's hits on the same terms, the total.

    Pairs the runs of each clip, and leaves a pair out whole when either call failed.
    """
    bare_by_key = {(row.id, row.run): row.outcome for row in rows if row.variant == bare and row.outcome}
    variant_hits = bare_hits = total = 0
    for row in rows:
        partner = bare_by_key.get((row.id, row.run))
        if row.variant != variant or row.outcome is None or partner is None:
            continue
        unlisted = row.outcome.unlisted_terms
        variant_hits += sum(term in row.outcome.hit_terms for term in unlisted)
        bare_hits += sum(term in partner.hit_terms for term in unlisted)
        total += len(unlisted)

    return variant_hits, bare_hits, total


def parse_variant(name: str) -> Variant:
    """Reads "v3+gl+en" into a Variant; an unknown token is an error, never a silent default."""
    model_token, *options = name.split("+")
    if model_token not in MODELS:
        raise ValueError(f"variant {name!r} must start with one of {sorted(MODELS)}")

    term_source = "none"
    secondary_languages: list[str] = []
    filters: list[str] = []
    pcm = False
    for option in options:
        if option in TERM_SOURCES:
            term_source = TERM_SOURCES[option]
        elif option in SECONDARY_LANGUAGES:
            secondary_languages.append(SECONDARY_LANGUAGES[option])
        elif option in FILTERS:
            filters.append(option)
            pcm = True
        elif option == "pcm":
            pcm = True
        else:
            known = sorted([*TERM_SOURCES, *SECONDARY_LANGUAGES, *FILTERS, "pcm"])
            raise ValueError(f"variant {name!r} has unknown option {option!r}; known options: {known}")

    return Variant(
        name=name,
        model_id=MODELS[model_token],
        term_source=term_source,
        secondary_languages=secondary_languages,
        filters=filters,
        pcm=pcm,
    )


def filter_chain(filters: list[str]) -> str:
    """The ffmpeg `-af` argument for the filters, in order; empty for none."""
    return ",".join(FILTERS[name] for name in filters)


def eligible_keyterms(terms: list[str]) -> list[str]:
    """Drops what the API rejects (length, word count, forbidden characters) before the count cap applies."""
    eligible = [
        term
        for term in terms
        if 0 < len(term) <= KEYTERM_CHARACTER_LIMIT
        and len(term.split()) <= KEYTERM_WORD_LIMIT
        and not KEYTERM_FORBIDDEN_CHARACTERS.intersection(term)
    ]

    return eligible[:KEYTERM_LIMIT]


def build_multipart(
    boundary: str,
    fields: list[tuple[str, str]],
    file_field: str,
    filename: str,
    content: bytes,
    content_type: str = "application/octet-stream",
) -> bytes:
    """A multipart/form-data body; a repeated field name is a repeated part, which is how `keyterms` is sent."""
    parts: list[bytes] = []
    for name, value in fields:
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
        )
    parts.append(
        (
            f'--{boundary}\r\nContent-Disposition: form-data; name="{file_field}"; filename="{filename}"\r\n'
            f"Content-Type: {content_type}\r\n\r\n"
        ).encode()
        + content
        + b"\r\n"
    )
    parts.append(f"--{boundary}--\r\n".encode())

    return b"".join(parts)


def load_texts() -> list[TextItem]:
    return [TextItem(**item) for item in json.loads(TEXTS_PATH.read_text(encoding="utf-8"))]


def load_glossary_sets() -> dict[str, list[str]]:
    return json.loads(GLOSSARIES_PATH.read_text(encoding="utf-8"))


def read_glossary() -> list[str]:
    """The glossary the app sends as keyterms; empty when the app has no settings file yet."""
    if not SETTINGS_PATH.exists():
        return []

    return json.loads(SETTINGS_PATH.read_text(encoding="utf-8")).get("glossaryTerms", [])


def read_api_key() -> str:
    """`ELEVENLABS_API_KEY`, else the app's own Keychain item. The key is never printed."""
    from_environment = os.environ.get("ELEVENLABS_API_KEY", "").strip()
    if from_environment:
        return from_environment

    completed = subprocess.run(
        ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w"],
        capture_output=True,
        text=True,
        check=False,
    )
    key = completed.stdout.strip()
    if completed.returncode != 0 or not key:
        raise SystemExit(
            "No ElevenLabs key: set ELEVENLABS_API_KEY, or store one in the app's Settings "
            f"(Keychain account {KEYCHAIN_ACCOUNT!r})."
        )

    return key


def find_clip(clips_directory: Path, text_id: str) -> Path | None:
    for extension in AUDIO_EXTENSIONS:
        candidate = clips_directory / f"{text_id}{extension}"
        if candidate.exists():
            return candidate

    return None


def decode_pcm(clip: Path, filters: list[str]) -> bytes:
    """The clip through the filters as raw 16 kHz mono 16-bit little-endian PCM, the `pcm_s16le_16` input."""
    command = ["ffmpeg", "-v", "error", "-nostdin", "-i", str(clip)]
    if filters:
        command += ["-af", filter_chain(filters)]
    command += ["-ar", "16000", "-ac", "1", "-f", "s16le", "-"]
    completed = subprocess.run(command, capture_output=True, check=False)
    if completed.returncode != 0 or not completed.stdout:
        detail = completed.stderr.decode("utf-8", errors="replace")[:300]
        raise SystemExit(f"ffmpeg failed on {clip.name}: {detail}")

    return completed.stdout


def prepare_audio(clip: Path, variant: Variant, cache: dict[tuple[Path, tuple[str, ...]], bytes]) -> Audio:
    """The clip as recorded, or decoded and filtered once per filter chain when the variant sends PCM."""
    if not variant.pcm:
        content_type = "audio/mp4" if clip.suffix == ".m4a" else "application/octet-stream"
        return Audio(content=clip.read_bytes(), filename=clip.name, fields=[], content_type=content_type)

    key = (clip, tuple(variant.filters))
    if key not in cache:
        cache[key] = decode_pcm(clip, variant.filters)

    return Audio(
        content=cache[key],
        filename=f"{clip.stem}.pcm",
        fields=[("file_format", "pcm_s16le_16")],
        content_type="application/octet-stream",
    )


def transcribe(api_key: str, audio: Audio, variant: Variant, keyterms: list[str]) -> Transcription:
    """One batch call as the app makes it. A failure comes back as a value so the report can show it."""
    fields = [
        ("model_id", variant.model_id),
        ("language_code", "tr"),
        ("no_verbatim", "true"),
        ("tag_audio_events", "false"),
        ("timestamps_granularity", "none"),
        *audio.fields,
    ]
    fields += [("secondary_language_codes", code) for code in variant.secondary_languages]
    fields += [("keyterms", term) for term in keyterms]

    boundary = uuid.uuid4().hex
    request = urllib.request.Request(
        API_URL,
        data=build_multipart(boundary, fields, "file", audio.filename, audio.content, audio.content_type),
        headers={
            "xi-api-key": api_key,
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "User-Agent": "stt-bench/1.0",
        },
        method="POST",
    )

    started = time.perf_counter()
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            text = json.loads(response.read())["text"]
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")[:300]
        return Transcription(text="", seconds=time.perf_counter() - started, error=f"HTTP {error.code}: {detail}")
    except (OSError, ValueError, KeyError, http.client.HTTPException) as error:
        return Transcription(text="", seconds=time.perf_counter() - started, error=repr(error))

    return Transcription(text=text.strip(), seconds=time.perf_counter() - started, error=None)


def keyterms_for(
    variant: Variant,
    glossary: list[str],
    texts: list[TextItem],
    sets: dict[str, list[str]],
) -> list[str]:
    """The keyterms a variant sends: the app's glossary, a named set, or every scored term as an upper bound."""
    if variant.term_source == "glossary":
        return eligible_keyterms(glossary)
    if variant.term_source == "names":
        return eligible_keyterms(sets["names"])
    if variant.term_source == "production":
        seen: set[str] = set()
        merged: list[str] = []
        for term in [*glossary, *sets["names"]]:
            if term.lower() not in seen:
                seen.add(term.lower())
                merged.append(term)
        return eligible_keyterms(merged)
    if variant.term_source == "dev":
        return eligible_keyterms(list(dict.fromkeys([*sets["names"], *sets["extras"]])))
    if variant.term_source == "dev-held-out":
        scored = {term_key(term) for item in texts for term in item.terms}
        extras = [term for term in sets["extras"] if term_key(term) not in scored]
        return eligible_keyterms(list(dict.fromkeys([*sets["names"], *extras])))
    if variant.term_source == "texts":
        return eligible_keyterms(sorted({term for item in texts for term in item.terms}))

    return []


def percent(part: int, whole: int) -> str:
    return f"{100 * part / whole:5.1f}%" if whole else "    n/a"


def run_wer(rows: list[Row]) -> list[float]:
    """The word error rate of each run, so the spread across runs shows how much of a difference is noise."""
    rates = []
    for run in sorted({row.run for row in rows}):
        scored = [row.outcome for row in rows if row.run == run and row.outcome]
        words = sum(outcome.reference_words for outcome in scored)
        if words:
            rates.append(100 * sum(outcome.edits for outcome in scored) / words)

    return rates


def bare_name(variant: Variant) -> str:
    return variant.name.split("+")[0]


def print_report(rows: list[Row], variants: list[Variant], items: list[TextItem], show: bool) -> None:
    names = {variant.name for variant in variants}
    print(
        f"\n{'variant':<22} {'WER':>6} {'run range':>13} {'listed':>9} {'unlisted':>9} "
        f"{'paired / bare':>15} {'spur':>5} {'med s':>6} {'err':>4}"
    )
    for variant in variants:
        mine = [row for row in rows if row.variant == variant.name]
        scored = [row.outcome for row in mine if row.outcome]
        words = sum(outcome.reference_words for outcome in scored)
        edits = sum(outcome.edits for outcome in scored)
        rates = run_wer(mine)
        listed = percent(sum(o.hits_listed for o in scored), sum(o.total_listed for o in scored))
        unlisted = percent(sum(o.hits_unlisted for o in scored), sum(o.total_unlisted for o in scored))
        against_bare = "n/a"
        if bare_name(variant) in names and bare_name(variant) != variant.name:
            hits, bare_hits, total = paired_unlisted_recall(rows, variant.name, bare_name(variant))
            if total:
                against_bare = f"{percent(hits, total).strip()} / {percent(bare_hits, total).strip()}"
        failed = len(mine) - len(scored)
        spurious = sum(len(outcome.spurious_terms) for outcome in scored)
        latency = statistics.median(row.seconds for row in mine if row.outcome) if scored else float("nan")
        spread = f"{min(rates):.1f}-{max(rates):.1f}" if rates and not failed else "n/a"
        # A failed call leaves its clip out, and the clips that fail are the hard ones, so no rate is shown.
        wer = percent(edits, words) if not failed else "n/a"
        print(
            f"{variant.name:<22} {wer:>6} {spread:>13} {listed:>9} {unlisted:>9} "
            f"{against_bare:>15} {spurious:>5} {latency:>6.2f} {failed:>4}"
        )

    print("\nWER per clip, mean over runs (lower is better)")
    print(f"{'variant':<22} " + " ".join(f"{item.id:>6}" for item in items))
    for variant in variants:
        cells = []
        for item in items:
            scored = [row.outcome for row in rows if row.variant == variant.name and row.id == item.id and row.outcome]
            cells.append(percent(sum(o.edits for o in scored), sum(o.reference_words for o in scored)))
        print(f"{variant.name:<22} " + " ".join(cells))

    for row in rows:
        if row.error:
            print(f"\nERROR {row.variant} {row.id} run {row.run}: {row.error}")
    if show:
        for item in items:
            print(f"\n[{item.id}] reference: {item.text}")
            for row in (r for r in rows if r.id == item.id and r.run == 1 and not r.error):
                print(f"  {row.variant:<20} {row.text}")


def command_texts() -> int:
    for item in load_texts():
        print(f"[{item.id}] {item.text}\n")

    return 0


def command_run(arguments: argparse.Namespace) -> int:
    items = load_texts()
    clips_directory = Path(arguments.clips).expanduser()
    variants = [parse_variant(name.strip()) for name in arguments.variants.split(",") if name.strip()]

    # 1. Only texts that have a clip take part, and a missing clip is said out loud rather than skipped quietly.
    available: list[tuple[TextItem, Path]] = []
    for item in items:
        clip = find_clip(clips_directory, item.id)
        if clip is None:
            print(f"no clip for text {item.id} in {clips_directory}", file=sys.stderr)
        else:
            available.append((item, clip))
    if not available:
        print(f"nothing to do: put {items[0].id}.m4a and the others in {clips_directory}", file=sys.stderr)
        return 2
    if any(variant.pcm for variant in variants) and shutil.which("ffmpeg") is None:
        raise SystemExit("`ffmpeg` not found: brew install ffmpeg")

    # 2. The glossary is what production sends; with none stored, the "gl" variants collapse into the bare ones.
    glossary = read_glossary()
    sets = load_glossary_sets()
    if any(variant.term_source == "glossary" for variant in variants) and not eligible_keyterms(glossary):
        print("warning: the app's glossary is empty, so the 'gl' variants send no keyterms", file=sys.stderr)
    api_key = read_api_key()

    # 3. Sequential on purpose: the batch limit is 8 concurrent requests and latency is part of the answer. The
    #    runs are the outer loop, so a slow minute at the provider lands on every variant alike.
    rows: list[Row] = []
    audio_cache: dict[tuple[Path, tuple[str, ...]], bytes] = {}
    for run in range(1, arguments.runs + 1):
        for variant in variants:
            keyterms = keyterms_for(variant, glossary, items, sets)
            for item, clip in available:
                result = transcribe(api_key, prepare_audio(clip, variant, audio_cache), variant, keyterms)
                outcome = score(item.text, item.terms, result.text, keyterms) if result.error is None else None
                seconds = round(result.seconds, 3)
                rows.append(
                    Row(variant.name, item.id, run, result.text, seconds, result.error, len(keyterms), outcome)
                )
                status = result.error or "ok"
                print(f"run {run} {variant.name:<22} {item.id} {seconds:5.2f}s {status}", file=sys.stderr)

    print_report(rows, variants, [item for item, _ in available], arguments.show)

    # 4. Keep the raw hypotheses next to the numbers; a number alone cannot say what the model heard.
    results_directory = Path(arguments.out).expanduser()
    results_directory.mkdir(parents=True, exist_ok=True)
    destination = results_directory / f"{datetime.now():%Y%m%d-%H%M%S}.json"
    destination.write_text(json.dumps([asdict(row) for row in rows], ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\nsaved {destination}")

    return 1 if any(row.error for row in rows) else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("texts", help="print the texts to read aloud")
    run = commands.add_parser("run", help="transcribe the clips and score every variant")
    run.add_argument("--clips", default=str(DEFAULT_ROOT / "clips"), help="directory holding 01.m4a, 02.m4a, ...")
    run.add_argument("--out", default=str(DEFAULT_ROOT / "results"), help="directory for the JSON results")
    run.add_argument("--variants", default=",".join(DEFAULT_VARIANTS), help="comma-separated, e.g. v2+gl,v3+dev+hp")
    run.add_argument("--runs", type=int, default=3, help="repeat every call this many times (default 3)")
    run.add_argument("--show", action="store_true", help="print every hypothesis of run 1 under its reference")
    arguments = parser.parse_args()

    if arguments.command == "texts":
        return command_texts()

    return command_run(arguments)


if __name__ == "__main__":
    sys.exit(main())

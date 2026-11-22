"""Records the benchmark texts one by one from the default input, AirPods included: Enter starts, Enter stops.

    python3 record_clips.py [--clips DIR] [--only 01,03] [--force]

Capture is `rec` (sox) streaming raw 16 kHz mono PCM, so the samples are seen as they arrive. A Bluetooth headset
delivers exact zeros for about 1.5 s after the input opens, so the "recording" cue plays only once the signal is
live, and the zeros are cut (keeping the app's 0.15 s pre-roll) before the clip is encoded to the 32 kbps AAC the
app uploads. Existing clips are kept unless `--force` or `--only` names them.
"""

import argparse
import math
import shutil
import subprocess
import sys
import tempfile
import textwrap
import threading
import wave
from array import array
from pathlib import Path

from stt_bench import DEFAULT_ROOT, TextItem, load_texts

SAMPLE_RATE = 16_000
CHUNK_SAMPLES = 320
CHUNK_BYTES = CHUNK_SAMPLES * 2
# The app's own floor (LeadingSilence.silenceRMS, 0.0005 of full scale) in 16-bit units.
LIVE_RMS = 0.0005 * 32_768
PRE_ROLL_SAMPLES = int(0.15 * SAMPLE_RATE)
LIVE_TIMEOUT_SECONDS = 10
AAC_BITRATE = 32_000
CUE_SOUND = Path("/System/Library/Sounds/Hero.aiff")
CLIPPING_PEAK = 32_000
SHORTEST_CLIP_SECONDS = 2.0

RECORD_COMMAND = [
    "rec",
    "-q",
    "-t", "raw",
    "-r", str(SAMPLE_RATE),
    "-c", "1",
    "-b", "16",
    "-e", "signed-integer",
    "-L",
    "-",
]


def chunk_rms(samples: array) -> float:
    """Root-mean-square level of 16-bit samples, in the same units as the samples."""
    if not samples:
        return 0.0

    return math.sqrt(sum(sample * sample for sample in samples) / len(samples))


def first_live_sample(samples: array) -> int | None:
    """Index of the first 20 ms chunk above the app's silence floor, or None while the input is still dead."""
    for start in range(0, len(samples), CHUNK_SAMPLES):
        if chunk_rms(samples[start:start + CHUNK_SAMPLES]) > LIVE_RMS:
            return start

    return None


def trim_to_live(samples: array) -> array:
    """Drops the dead lead-in but keeps a short pre-roll; a clip that never went live comes back empty."""
    start = first_live_sample(samples)
    if start is None:
        return array("h")

    return samples[max(0, start - PRE_ROLL_SAMPLES):]


def parse_only(raw: str) -> list[str]:
    return [part.strip() for part in raw.split(",") if part.strip()]


class Recorder:
    """One `rec` process streaming 16 kHz mono PCM into memory until stopped."""

    def __init__(self) -> None:
        self.samples = array("h")
        self.live = threading.Event()
        self._process = subprocess.Popen(RECORD_COMMAND, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self._reader = threading.Thread(target=self._read, daemon=True)
        self._reader.start()

    def _read(self) -> None:
        stream = self._process.stdout
        assert stream is not None
        while chunk := stream.read(CHUNK_BYTES):
            samples = array("h")
            samples.frombytes(chunk[: len(chunk) - len(chunk) % 2])
            self.samples.extend(samples)
            if not self.live.is_set() and chunk_rms(samples) > LIVE_RMS:
                self.live.set()

    def failure(self) -> str | None:
        """What `rec` said if it already exited, else None."""
        if self._process.poll() is None:
            return None
        assert self._process.stderr is not None

        return self._process.stderr.read().decode("utf-8", errors="replace").strip() or "rec exited"

    def stop(self) -> array:
        if self._process.poll() is None:
            self._process.terminate()
        self._reader.join(timeout=5)
        self._process.wait(timeout=5)

        return self.samples


def encode(samples: array, destination: Path) -> None:
    """Writes the samples as the AAC m4a the app uploads (mono, 16 kHz, 32 kbps)."""
    with tempfile.TemporaryDirectory() as scratch:
        wav_path = Path(scratch) / "clip.wav"
        with wave.open(str(wav_path), "wb") as writer:
            writer.setnchannels(1)
            writer.setsampwidth(2)
            writer.setframerate(SAMPLE_RATE)
            writer.writeframes(samples.tobytes())
        subprocess.run(
            ["afconvert", "-f", "m4af", "-d", "aac", "-b", str(AAC_BITRATE), str(wav_path), str(destination)],
            check=True,
        )


def play_cue() -> None:
    if CUE_SOUND.exists():
        subprocess.Popen(["afplay", str(CUE_SOUND)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def record_one(item: TextItem, destination: Path) -> bool:
    """Records one clip. False when the user quits, True once it is saved."""
    print(f"\n[{item.id}]\n{textwrap.fill(item.text, width=100, initial_indent='  ', subsequent_indent='  ')}\n")

    while True:
        if input("Enter to start (q to quit) ").strip().lower() == "q":
            return False

        # 1. Open the input and wait for the signal: a Bluetooth headset is silent for about 1.5 s first.
        print("opening the microphone...", flush=True)
        recorder = Recorder()
        went_live = False
        for _ in range(LIVE_TIMEOUT_SECONDS * 10):
            if recorder.live.wait(timeout=0.1):
                went_live = True
                break
            if recorder.failure() is not None:
                break
        if not went_live:
            reason = recorder.failure() or f"no signal within {LIVE_TIMEOUT_SECONDS} s"
            recorder.stop()
            print(f"could not record: {reason}", file=sys.stderr)
            continue

        # 2. The cue means speak now, so nothing said before it is lost.
        play_cue()
        print("RECORDING: read the text, then Enter to stop", flush=True)
        input()

        # 3. Cut the dead lead-in, check the clip is usable, and encode it as the app would upload it.
        samples = trim_to_live(recorder.stop())
        seconds = len(samples) / SAMPLE_RATE
        peak = max((abs(sample) for sample in samples), default=0)
        if seconds < SHORTEST_CLIP_SECONDS:
            print(f"only {seconds:.1f} s recorded; try that one again", file=sys.stderr)
            continue
        if peak >= CLIPPING_PEAK:
            print("the signal clipped (too loud); the clip is kept, but speaking a little back helps", file=sys.stderr)
        encode(samples, destination)
        print(f"saved {destination.name}: {seconds:.1f} s, peak {20 * math.log10(max(peak, 1) / 32_768):.0f} dBFS")

        return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--clips", default=str(DEFAULT_ROOT / "clips"), help="where the clips go")
    parser.add_argument("--only", default="", help="record just these ids, e.g. 03 or 01,04 (overwrites them)")
    parser.add_argument("--force", action="store_true", help="overwrite clips that already exist")
    arguments = parser.parse_args()

    if shutil.which("rec") is None:
        raise SystemExit("`rec` not found: brew install sox")
    if sys.byteorder != "little":
        raise SystemExit("the raw capture is little-endian and this machine is not")

    clips_directory = Path(arguments.clips).expanduser()
    clips_directory.mkdir(parents=True, exist_ok=True)
    only = parse_only(arguments.only)
    unknown = sorted(set(only) - {item.id for item in load_texts()})
    if unknown:
        raise SystemExit(f"unknown text ids: {', '.join(unknown)}")

    for item in load_texts():
        if only and item.id not in only:
            continue
        destination = clips_directory / f"{item.id}.m4a"
        if destination.exists() and not (arguments.force or only):
            print(f"[{item.id}] already recorded, skipping (--force or --only {item.id} to redo)")
            continue
        try:
            if not record_one(item, destination):
                return 0
        except KeyboardInterrupt:
            print("\nstopped")
            return 130

    print(f"\ndone: python3 stt_bench.py run --show   (clips in {clips_directory})")

    return 0


if __name__ == "__main__":
    sys.exit(main())

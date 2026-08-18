#!/usr/bin/env bash
# latency-report.sh: read log.jsonl and report what the dictations actually cost.
#
# Every dictation appends one JSON line with its per-stage timings, so the question "is this fast
# enough" is answered from real use rather than from a benchmark. This script is the reader.
#
# Usage:
#   ./latency-report.sh              # every record
#   ./latency-report.sh dictate      # Mode 1 only
#   ./latency-report.sh prompt       # Mode 2 only
#   ./latency-report.sh dictate 10   # the last 10 Mode 1 records
set -euo pipefail

MODE="${1:-all}"
LAST="${2:-0}"

exec python3 - "$MODE" "$LAST" <<'PY'
import json
import pathlib
import statistics
import sys

mode_filter, last = sys.argv[1], int(sys.argv[2])
log = pathlib.Path.home() / "Library/Application Support/MyDikte/log.jsonl"

if not log.exists():
    sys.exit(f"No log at {log}. Dictate something first.")

records, malformed = [], []
for number, line in enumerate(log.read_text().splitlines(), 1):
    if not line.strip():
        continue
    try:
        records.append(json.loads(line))
    except json.JSONDecodeError as error:
        # Reported rather than skipped silently: a line that does not parse means the writer has a
        # bug, and the whole point of this file is that an offline reader can trust it.
        malformed.append((number, str(error)))

if mode_filter != "all":
    records = [r for r in records if r.get("mode") == mode_filter]
if last:
    records = records[-last:]

if not records:
    sys.exit(f"No records match mode={mode_filter}.")

STAGES = ("captureMs", "encodeMs", "transcribeMs", "cleanupMs", "insertMs")

print(f"{len(records)} record(s), mode={mode_filter}" + (f", last {last}" if last else ""))
if malformed:
    print(f"MALFORMED LINES: {len(malformed)}")
    for number, error in malformed:
        print(f"  line {number}: {error}")
print()

print(f"{'when':<17} {'mode':<8} {'audio':>6} {'total':>8} {'cap':>6} {'enc':>6} "
      f"{'stt':>7} {'clean':>8} {'ins':>6}  note")
for record in records:
    timings = record["timings"]
    # A rejected dictation still inserted the raw transcript, so it is a slow success and not a
    # failure. Flagged rather than dropped, because dropping it would flatter the median.
    reason = record.get("paraphraseRejectionReason")
    note = "" if reason is None else reason
    # The candidate the guard turned down. Printed because the reason alone quotes word counts and
    # cannot say whether the guard was right; this is the line that makes the threshold tunable.
    rejected = record.get("rejectedCleanup")
    if rejected:
        note += f"\n{'':>17} {'':>8} {'':>6} {'':>8} rejected candidate: {rejected}"
    print(
        f"{record['timestamp'][:16].replace('T', ' '):<17} "
        f"{record['mode']:<8} "
        f"{record.get('duration', 0):>5.1f}s "
        f"{timings['totalMs']:>7.0f}ms "
        f"{timings['captureMs']:>5.0f} "
        f"{timings['encodeMs']:>5.0f} "
        f"{timings['transcribeMs']:>6.0f} "
        f"{timings['cleanupMs']:>7.0f} "
        f"{timings['insertMs']:>5.0f}  {note}"
    )

# Runs that never reached the network are excluded from the latency summary: a room-tone rejection
# costs 7 ms and would drag the median far below anything the user experiences.
completed = [r for r in records if r["timings"]["transcribeMs"] > 0]
rejected = len(records) - len(completed)

print()
if rejected:
    print(f"{rejected} record(s) never reached the network (silence rejected before the API call), "
          f"excluded from the summary below.")
if not completed:
    sys.exit("No completed dictations to summarise.")

totals = sorted(r["timings"]["totalMs"] for r in completed)
median = statistics.median(totals)
index = min(int(len(totals) * 0.9), len(totals) - 1)

print(f"completed: {len(completed)}")
print(f"  median total : {median:>8.0f} ms")
print(f"  p90 total    : {totals[index]:>8.0f} ms")
print(f"  fastest      : {totals[0]:>8.0f} ms")
print(f"  slowest      : {totals[-1]:>8.0f} ms")
print()
print("  stage medians:")
for stage in STAGES:
    values = [r["timings"][stage] for r in completed]
    share = statistics.median(values) / median * 100 if median else 0
    print(f"    {stage:<13}{statistics.median(values):>8.0f} ms  ({share:>4.1f}% of the median)")

# The plan's Definition of Done. Stated as a verdict rather than a number to read, so a regression
# is visible without doing the comparison by hand every time.
print()
budget = 1500
verdict = "PASS" if median < budget else "FAIL"
print(f"Definition of Done, median under {budget} ms: {verdict} ({median:.0f} ms)")

# Non-zero stage check, also from the plan. A stage that ran must have a measurable cost; a
# zero there means the timer was never started, which is a bug in the writer rather than a fast run.
zeroed = {
    stage: sum(1 for r in completed if r["timings"][stage] == 0)
    for stage in STAGES
}
suspicious = {stage: count for stage, count in zeroed.items() if count}
if suspicious:
    print("Stages reading exactly 0 ms on a completed dictation:")
    for stage, count in suspicious.items():
        print(f"  {stage}: {count} of {len(completed)}")
else:
    print("Every stage of every completed dictation has a non-zero timing.")
PY

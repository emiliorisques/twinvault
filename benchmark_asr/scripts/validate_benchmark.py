#!/usr/bin/env python3
"""Validate structure, audio encoding and reference consistency."""

from __future__ import annotations

import csv
import json
import sys
import wave
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    checks: list[tuple[bool, str]] = []
    with (root / "manifest.csv").open(encoding="utf-8", newline="") as stream:
        rows = list(csv.DictReader(stream))
    durations = []
    for row in rows:
        filename = row["file"]
        audio = root / "audio" / filename
        checks.append((audio.exists(), f"{filename}: WAV exists"))
        if not audio.exists():
            continue
        try:
            with wave.open(str(audio), "rb") as wav:
                duration = wav.getnframes() / wav.getframerate()
                checks.extend([
                    (wav.getframerate() == 16_000, f"{filename}: sample rate is 16000 Hz"),
                    (wav.getnchannels() == 1, f"{filename}: mono"),
                    (wav.getsampwidth() == 2 and wav.getcomptype() == "NONE",
                     f"{filename}: uncompressed PCM 16-bit"),
                    (55 <= duration <= 185, f"{filename}: duration {duration:.3f}s is approximately 1–3 min"),
                ])
                durations.append(duration)
        except wave.Error as error:
            checks.append((False, f"{filename}: readable WAV ({error})"))
            continue
        stem = Path(filename).stem
        json_path, txt_path = root / "reference" / f"{stem}.json", root / "reference" / f"{stem}.txt"
        checks.extend([(json_path.exists(), f"{filename}: JSON reference exists"),
                       (txt_path.exists(), f"{filename}: TXT reference exists")])
        if not json_path.exists():
            continue
        reference = json.loads(json_path.read_text(encoding="utf-8"))
        segments = reference.get("segments", [])
        checks.append((all(0 <= item["start"] <= item["end"] <= duration + 0.02 for item in segments),
                       f"{filename}: timestamps are within audio duration"))
        segment_languages = list(dict.fromkeys(item["language"] for item in segments))
        checks.append((reference.get("languages") == segment_languages,
                       f"{filename}: declared languages match segment languages"))
    total = sum(durations)
    checks.extend([
        (8 <= len(rows) <= 10, f"Manifest contains {len(rows)} generated audio cases (required 8–10)"),
        (900 <= total <= 1500, f"Total duration {total:.3f}s is within 15–25 min"),
        ((root / "08_entities_SCRIPT.txt").exists(), "Manual entities recording script exists"),
    ])
    failures = [message for passed, message in checks if not passed]
    report = ["TwinVault multilingual ASR benchmark validation", "", *[
        f"{'PASS' if passed else 'FAIL'}: {message}" for passed, message in checks
    ], "", "Human review status:",
        "PENDING: Dataset-provided transcripts have not been verified by listening word-for-word.",
        "PENDING: 08_entities_SCRIPT.txt must be recorded before case 08 can be benchmarked.",
        "OMITTED: Case 09 accented English was not generated; see SOURCES.md.",
        "", f"STRUCTURAL RESULT: {'PASS' if not failures else 'FAIL'} ({len(failures)} failed checks)",
        "RELEASE READINESS: PENDING HUMAN TRANSCRIPT REVIEW",
    ]
    (root / "validation_report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    print("\n".join(report))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

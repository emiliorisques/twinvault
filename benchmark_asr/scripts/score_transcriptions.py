#!/usr/bin/env python3
"""Score TwinVault benchmark provider JSON against the dataset references."""

from __future__ import annotations

import argparse
import csv
import json
import re
import unicodedata
from pathlib import Path


def normalized_words(text: str) -> list[str]:
    normalized = unicodedata.normalize("NFKC", text).lower().replace("’", "'")
    return re.findall(r"[^\W_]+(?:'[^\W_]+)?", normalized, flags=re.UNICODE)


def edit_counts(reference: list[str], hypothesis: list[str]) -> tuple[int, int, int]:
    # Each cell stores (total edits, substitutions, deletions, insertions).
    previous = [(index, 0, index, 0) for index in range(len(reference) + 1)]
    for hyp_index, hyp_word in enumerate(hypothesis, 1):
        current = [(hyp_index, 0, 0, hyp_index)]
        for ref_index, ref_word in enumerate(reference, 1):
            if ref_word == hyp_word:
                current.append(previous[ref_index - 1])
                continue
            substitution = previous[ref_index - 1]
            deletion = current[ref_index - 1]
            insertion = previous[ref_index]
            candidates = [
                (substitution[0] + 1, substitution[1] + 1, substitution[2], substitution[3]),
                (deletion[0] + 1, deletion[1], deletion[2] + 1, deletion[3]),
                (insertion[0] + 1, insertion[1], insertion[2], insertion[3] + 1),
            ]
            current.append(min(candidates, key=lambda item: (item[0], item[2], item[3], item[1])))
        previous = current
    _, substitutions, deletions, insertions = previous[-1]
    return substitutions, deletions, insertions


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--benchmark", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    output = args.output or args.results
    output.mkdir(parents=True, exist_ok=True)
    providers = ("parakeet", "whisperkit")
    rows = []
    for reference_path in sorted((args.benchmark / "reference").glob("*.json")):
        reference = json.loads(reference_path.read_text(encoding="utf-8"))
        reference_words = [
            word for segment in reference["segments"] for word in normalized_words(segment["text"])
        ]
        for provider in providers:
            result_path = args.results / f"{provider}-{reference_path.stem}.json"
            if not result_path.exists():
                raise FileNotFoundError(result_path)
            result = json.loads(result_path.read_text(encoding="utf-8"))
            hypothesis_words = [
                word for segment in result["segments"] for word in normalized_words(segment["text"])
            ]
            substitutions, deletions, insertions = edit_counts(reference_words, hypothesis_words)
            edits = substitutions + deletions + insertions
            duration = float(reference["duration_seconds"])
            elapsed = float(result["elapsedSeconds"])
            rows.append({
                "case": reference_path.stem,
                "languages": "+".join(reference["languages"]),
                "provider": provider,
                "duration_seconds": duration,
                "elapsed_seconds": elapsed,
                "realtime_factor_x": duration / elapsed,
                "reference_words": len(reference_words),
                "hypothesis_words": len(hypothesis_words),
                "substitutions": substitutions,
                "deletions": deletions,
                "insertions": insertions,
                "word_edits": edits,
                "wer_percent": edits * 100 / max(1, len(reference_words)),
            })

    fields = list(rows[0])
    with (output / "comparison_results.csv").open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)

    report = [
        "# TwinVault ASR comparison",
        "",
        "Directional WER: references are dataset-provided and still require human review.",
        "AMI contains overlapping speech, so its linear WER is especially conservative.",
        "",
        "| Case | Languages | Parakeet WER / time | WhisperKit WER / time |",
        "|---|---|---:|---:|",
    ]
    for case in sorted({row["case"] for row in rows}):
        by_provider = {row["provider"]: row for row in rows if row["case"] == case}
        parakeet, whisper = by_provider["parakeet"], by_provider["whisperkit"]
        report.append(
            f"| {case} | {parakeet['languages']} | {parakeet['wer_percent']:.1f}% / "
            f"{parakeet['elapsed_seconds']:.2f}s | {whisper['wer_percent']:.1f}% / "
            f"{whisper['elapsed_seconds']:.2f}s |"
        )
    report.extend(["", "## Aggregate", ""])
    for provider in providers:
        selected = [row for row in rows if row["provider"] == provider]
        reference_words = sum(row["reference_words"] for row in selected)
        edits = sum(row["word_edits"] for row in selected)
        elapsed = sum(row["elapsed_seconds"] for row in selected)
        duration = sum(row["duration_seconds"] for row in selected)
        report.append(
            f"- {provider}: {edits / reference_words * 100:.1f}% micro-WER; "
            f"{elapsed:.2f}s runtime; {duration / elapsed:.1f}x real time."
        )
    report.extend(["", "## Decision slices", ""])
    groups = {
        "ES/EN clean or code-switched (01–03)": {"01_es_clean", "02_en_clean", "03_es_en"},
        "Catalan present (04, 05, 06, 10)": {
            "04_ca_es", "05_es_ca_en", "06_noise", "10_stress_test"
        },
        "Overlapping AMI meeting (07)": {"07_meeting"},
    }
    for label, cases in groups.items():
        values = []
        for provider in providers:
            selected = [
                row for row in rows if row["provider"] == provider and row["case"] in cases
            ]
            reference_words = sum(row["reference_words"] for row in selected)
            edits = sum(row["word_edits"] for row in selected)
            values.append(f"{provider} {edits / reference_words * 100:.1f}%")
        report.append(f"- {label}: {'; '.join(values)}.")
    (output / "comparison_report.md").write_text("\n".join(report) + "\n", encoding="utf-8")
    print("\n".join(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

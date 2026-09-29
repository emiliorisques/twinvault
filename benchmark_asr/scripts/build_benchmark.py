#!/usr/bin/env python3
"""Build the small TwinVault ASR benchmark from selectively downloaded sources.

This script never downloads data. See SOURCES.md for the exact source layout.
It requires ffmpeg and Python 3.11+ but no third-party Python packages.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import struct
import subprocess
import wave
from array import array
from pathlib import Path

RATE = 16_000
SILENCE_SECONDS = 0.35
AMI_START = 900.0
AMI_END = 1050.0
FLEURS_CONFIGS = {"es": "es_419", "ca": "ca_es", "en": "en_us"}


def decode_pcm16(path: Path) -> array:
    completed = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(RATE),
         "-f", "s16le", "-acodec", "pcm_s16le", "-"],
        check=True,
        stdout=subprocess.PIPE,
    )
    samples = array("h")
    samples.frombytes(completed.stdout)
    if struct.pack("=h", 1) != struct.pack("<h", 1):
        samples.byteswap()
    return samples


def write_wav(path: Path, samples: array) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(RATE)
        output.writeframes(samples.tobytes())


def silence(seconds: float) -> array:
    return array("h", [0]) * round(seconds * RATE)


def add_noise_at_snr(speech: array, noise: array, snr_db: float) -> array:
    if not noise:
        raise ValueError("The MUSAN noise file is empty")
    speech_rms = math.sqrt(sum(value * value for value in speech) / max(1, len(speech)))
    noise_rms = math.sqrt(sum(value * value for value in noise) / len(noise))
    gain = speech_rms / (noise_rms * (10 ** (snr_db / 20))) if noise_rms else 0.0
    mixed = [speech[i] + noise[i % len(noise)] * gain for i in range(len(speech))]
    peak = max(1.0, max(abs(value) for value in mixed))
    limiter = min(1.0, 32700.0 / peak)
    return array("h", (round(value * limiter) for value in mixed))


def write_reference(root: Path, filename: str, languages: list[str], segments: list[dict],
                    provenance: list[dict], duration: float) -> None:
    stem = Path(filename).stem
    payload = {
        "audio": filename,
        "duration_seconds": round(duration, 3),
        "languages": languages,
        "reference_status": "dataset_provided_unreviewed",
        "requires_human_review": True,
        "segments": segments,
        "entities": {"names": [], "dates": [], "amounts": [], "commitments": []},
        "provenance": provenance,
    }
    reference = root / "reference"
    reference.mkdir(parents=True, exist_ok=True)
    (reference / f"{stem}.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    lines = []
    for item in segments:
        start, end = item["start"], item["end"]
        lines.append(f"[{timestamp(start)}–{timestamp(end)}] {item['language'].upper()}: {item['text']}")
    (reference / f"{stem}.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def timestamp(seconds: float) -> str:
    minutes = int(seconds // 60)
    return f"{minutes:02d}:{seconds - minutes * 60:05.2f}"


def build_fleurs_case(root: Path, sources: Path, case: dict, noise_path: Path | None) -> dict:
    combined = array("h")
    segments: list[dict] = []
    provenance: list[dict] = []
    for index, clip in enumerate(case["clips"]):
        if index:
            combined.extend(silence(SILENCE_SECONDS))
        source = sources / "fleurs" / clip["language_code"] / clip["source_file"]
        pcm = decode_pcm16(source)
        start = len(combined) / RATE
        combined.extend(pcm)
        end = len(combined) / RATE
        segments.append({
            "start": round(start, 3), "end": round(end, 3),
            "language": clip["language_code"], "speaker": None,
            "text": clip["raw_transcription"],
            "source_id": f"{clip['language_code']}:{clip['id']}:{clip['source_file']}",
        })
        provenance.append({
            "dataset": "Google FLEURS", "config": FLEURS_CONFIGS[clip["language_code"]],
            "split": "validation", "row_id": clip["id"], "source_file": clip["source_file"],
        })
    snr = None
    if noise_path is not None:
        snr = 10.0
        combined = add_noise_at_snr(combined, decode_pcm16(noise_path), snr)
        provenance.append({"dataset": "MUSAN", "source_file": noise_path.name, "snr_db": snr})
    filename = case["file"]
    write_wav(root / "audio" / filename, combined)
    languages = list(dict.fromkeys(item["language"] for item in segments))
    duration = len(combined) / RATE
    write_reference(root, filename, languages, segments, provenance, duration)
    return {
        "file": filename, "duration_seconds": f"{duration:.3f}",
        "languages": "+".join(languages), "speakers": "unknown (FLEURS has no stable speaker ID)",
        "noise": "MUSAN" if snr is not None else "none", "snr": f"{snr:.0f} dB" if snr else "",
        "source_dataset": "Google FLEURS" + (" + MUSAN" if snr is not None else ""),
        "source_ids": ";".join(item["source_id"] for item in segments),
        "license": "CC BY 4.0; MUSAN clip CC BY 3.0" if snr is not None else "CC BY 4.0",
        "test_type": Path(filename).stem,
    }


def build_ami_case(root: Path, sources: Path) -> dict:
    ami = sources / "ami"
    text_by_id = {}
    for line in (ami / "text").read_text(encoding="utf-8").splitlines():
        utterance, text = line.split(maxsplit=1)
        text_by_id[utterance] = text

    pattern = re.compile(
        r"eval_ami_es2004a_h\d\d_([^_]+)_(\d{7})_(\d{7})\.wav$", re.IGNORECASE
    )
    selected = []
    for path in sorted((ami / "extracted" / "ES2004a").glob("*.wav")):
        match = pattern.match(path.name)
        if not match:
            continue
        speaker, start_raw, end_raw = match.groups()
        start, end = int(start_raw) / 100, int(end_raw) / 100
        if start < AMI_END and end > AMI_START:
            utterance = f"AMI_ES2004a_{path.name.split('_')[3].upper()}_{speaker.upper()}_{start_raw}_{end_raw}"
            if utterance in text_by_id:
                selected.append((path, utterance, speaker.upper(), start, end, text_by_id[utterance]))
    if not selected:
        raise ValueError("No AMI ES2004a headset clips found in the selected window")

    length = round((AMI_END - AMI_START) * RATE)
    accumulator = [0.0] * length
    segments = []
    for path, utterance, speaker, start, end, text in selected:
        pcm = decode_pcm16(path)
        clipped_start = max(start, AMI_START)
        clipped_end = min(end, AMI_END)
        source_offset = round((clipped_start - start) * RATE)
        destination = round((clipped_start - AMI_START) * RATE)
        count = min(round((clipped_end - clipped_start) * RATE), len(pcm) - source_offset)
        for index in range(max(0, count)):
            accumulator[destination + index] += pcm[source_offset + index]
        segments.append({
            "start": round(clipped_start - AMI_START, 3),
            "end": round(clipped_end - AMI_START, 3),
            "language": "en", "speaker": speaker, "text": text, "source_id": utterance,
        })
    peak = max(1.0, max(abs(value) for value in accumulator))
    gain = min(1.0, 32700.0 / peak)
    output = array("h", (round(value * gain) for value in accumulator))
    filename = "07_meeting.wav"
    write_wav(root / "audio" / filename, output)
    segments.sort(key=lambda item: (item["start"], item["end"]))
    provenance = [{
        "dataset": "AMI Meeting Corpus", "meeting": "ES2004a",
        "partition": "eval", "window_seconds": [AMI_START, AMI_END],
        "microphones": "individual headset channels mixed on the original timeline",
        "source_ids": [item["source_id"] for item in segments],
    }]
    write_reference(root, filename, ["en"], segments, provenance, len(output) / RATE)
    return {
        "file": filename, "duration_seconds": f"{len(output) / RATE:.3f}", "languages": "en",
        "speakers": "+".join(sorted({item["speaker"] for item in segments})),
        "noise": "room/meeting", "snr": "", "source_dataset": "AMI Meeting Corpus",
        "source_ids": "ES2004a:900.00-1050.00",
        "license": "CC BY 4.0", "test_type": "meeting_overlap",
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sources", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.output.resolve()
    root.joinpath("audio").mkdir(parents=True, exist_ok=True)
    plan = json.loads(Path(__file__).with_name("source_plan.json").read_text(encoding="utf-8"))
    noise = args.sources / "musan" / "noise-sound-bible-0009.wav"
    rows = []
    for case in plan["cases"]:
        rows.append(build_fleurs_case(root, args.sources, case, noise if case["file"] in {
            "06_noise.wav", "10_stress_test.wav"
        } else None))
    rows.append(build_ami_case(root, args.sources))
    rows.sort(key=lambda item: item["file"])
    fields = ["file", "duration_seconds", "languages", "speakers", "noise", "snr",
              "source_dataset", "source_ids", "license", "test_type"]
    with (root / "manifest.csv").open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    print(f"Built {len(rows)} audio files ({sum(float(row['duration_seconds']) for row in rows):.1f} s)")


if __name__ == "__main__":
    main()

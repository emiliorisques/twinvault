# TwinVault multilingual ASR benchmark

Small, local benchmark focused on Spanish, Catalan and English code-switching. The
generated set contains eight WAV files and lasts about 17.8 minutes. Audio is PCM,
mono, 16 kHz and 16-bit. No TTS or private recording is included.

## Build

The public source clips are deliberately not committed. Arrange the selective downloads
as described in `SOURCES.md`, then run:

```bash
python3 scripts/build_benchmark.py --sources /path/to/source-clips
python3 scripts/validate_benchmark.py
python3 scripts/score_transcriptions.py --results /path/to/provider-json
```

The build is deterministic for the listed source files. Cases 06 and 10 mix a MUSAN
noise clip at a calculated 10 dB SNR. Case 07 reconstructs a 150-second AMI meeting
window on its original timeline from individual headset segments, preserving overlap.
The scorer expects `parakeet-<case>.json` and `whisperkit-<case>.json` files in the
results directory and writes `comparison_results.csv` plus `comparison_report.md`.

## Reference status

The JSON/TXT text is copied from dataset-provided references without translation or
summarization. It has **not yet been verified word-for-word by a human listener**.
Therefore every JSON marks `requires_human_review: true`; structural validation does
not mean the references are release-ready.

Case 08 is supplied as a human-recording script because the selected datasets do not
provide a reliable entity-rich sample. Case 09 is intentionally omitted; see
`SOURCES.md`. After manually recording case 08, its WAV and reviewed reference can be
added without replacing any existing case.

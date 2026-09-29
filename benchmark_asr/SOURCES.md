# Sources and provenance

All final audio can be traced through `manifest.csv` and each JSON reference. Only the
needed files were downloaded; no complete corpus was fetched.

## Cases 01–06 and 10 — Google FLEURS

- Dataset: `google/fleurs`, validation splits `es_419`, `ca_es`, and `en_us`.
- Dataset page: <https://huggingface.co/datasets/google/fleurs>
- Material used: the exact `audio.path` filenames and row IDs listed in each reference
  JSON and in `manifest.csv`.
- Retrieval representation: Hugging Face conversion revision `refs/convert/parquet`.
- License: Creative Commons Attribution 4.0 (CC BY 4.0), as declared by the dataset card.
- Transformations: decoded, converted to mono 16 kHz PCM 16-bit, concatenated in the
  listed order with 350 ms digital silence between clips. No text was translated.
- Speaker limitation: FLEURS validation metadata exposes a gender category but no
  stable speaker identifier. References therefore use `speaker: null`; the manifest
  does not claim a verified speaker count.

## Noise in cases 06 and 10 — MUSAN

- Dataset: MUSAN, FreeSound/SoundBible noise collection.
- Official page: <https://www.openslr.org/17/>
- Selected file: `noise-sound-bible-0009.wav`, retrieved from the selective
  `alexwengg/musan_mini100` Hugging Face mirror.
- Exact mirror URL: <https://huggingface.co/datasets/alexwengg/musan_mini100/resolve/main/noise/noise-sound-bible-0009.wav>
- License: Attribution 3.0 (CC BY 3.0). The bundled MUSAN SoundBible license identifies
  this exact clip as “Buzz Fade Out”, recorded by Mike Koenig, with source page
  <http://soundbible.com/1198-Buzz-Fade-Out.html>.
- Transformation: repeated to match speech duration and mixed at a calculated 10 dB
  SNR (RMS speech versus RMS noise), then peak-limited only if required to avoid clipping.

## Case 07 — AMI Meeting Corpus

- Dataset: AMI Meeting Corpus, evaluation meeting `ES2004a`.
- Official corpus: <https://groups.inf.ed.ac.uk/ami/download/>
- Selective mirror: `edinburghcstr/ami` at revision
  `a03099e8a90490943fb9fb992899fc583fce39e1` for audio and revision
  `fc3b6e8c8cbdcfa11d476e07aa338d937586bd1c` for Kaldi annotations.
- Source archive: `audio/sdm/eval/ES2004a.tar.gz`; annotation files:
  `annotations/eval/text`, `segments`, and `utt2spk`.
- Fragment: original meeting timeline 900.00–1050.00 seconds. Exact utterance IDs are
  embedded in `reference/07_meeting.json`.
- License: CC BY 4.0, as declared by AMI and the dataset card.
- Transformation: the individual headset utterances are placed at their original
  timestamps and mixed; this retains interruptions and overlapping speech. Output is
  normalized to mono 16 kHz PCM 16-bit.

## Case 08 — entity script only

No reliable entity-rich recording was selected. `08_entities_SCRIPT.txt` is an original
script intended for manual human recording. It contains deliberately designed entities,
but there is no WAV/reference yet and it is not counted as a generated benchmark case.

## Case 09 — accented English omitted

VoxPopuli provides an `en_accented/en_es` evaluation subset, but the available selective
representation required fetching a multi-gigabyte parquet shard for a 1–2 minute case.
That conflicts with the requirement not to download a full/large dataset unnecessarily.
The case is therefore explicitly omitted rather than substituting unverified audio.
Potential source: <https://huggingface.co/datasets/facebook/voxpopuli> (CC0).

## Human verification still required

FLEURS and AMI text is dataset-provided, not invented. It remains unverified by a human
listener in this package. Before using the set for a product decision, listen to every
segment and correct only genuine dataset/audio mismatches while retaining an audit trail.

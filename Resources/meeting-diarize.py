#!/usr/bin/env python3
"""Local-only speaker diarization. Never resolves speaker identities or uploads audio."""
import argparse
import json
import math
import os
from pathlib import Path
import sys
import tempfile

# Bound CPU usage before importing inference libraries.
os.environ.setdefault("OMP_NUM_THREADS", "2")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "2")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audio", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--models", required=True, type=Path)
    parser.add_argument("--speakers", type=int, default=-1,
                        help="Known remote speaker count; default automatically clusters voices")
    args = parser.parse_args()
    if args.speakers != -1 and not 1 <= args.speakers <= 100:
        raise ValueError("Speaker count must be -1 or between 1 and 100")
    import numpy as np
    import soundfile as sf
    import sherpa_onnx
    segmentation = args.models / "segmentation.onnx"
    embedding = args.models / "embedding.onnx"
    if not segmentation.is_file() or not embedding.is_file():
        raise RuntimeError("Meeting speaker models are missing. Run setup-meeting-models.sh")
    info = sf.info(str(args.audio))
    if info.samplerate != 16000 or info.channels != 1 or info.frames < 1:
        raise ValueError("Expected a nonempty 16000 Hz mono WAV")
    if info.format not in ("WAV", "WAVEX"):
        raise ValueError("Expected WAV audio")
    audio, _ = sf.read(str(args.audio), dtype="float32")
    if not np.isfinite(audio).all():
        raise ValueError("Audio contains invalid samples")
    config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
                model=str(segmentation), window_shift_ratio=0.1),
            num_threads=2, provider="cpu"),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=str(embedding), num_threads=2, provider="cpu"),
        clustering=sherpa_onnx.FastClusteringConfig(
            num_clusters=args.speakers, threshold=0.5),
        min_duration_on=0.3, min_duration_off=0.5)
    if not config.validate():
        raise RuntimeError("Speaker model configuration is invalid")
    model = sherpa_onnx.OfflineSpeakerDiarization(config)
    if model.sample_rate != info.samplerate:
        raise RuntimeError("Speaker model requires a different sample rate")
    # Silence legitimately produces an empty result; failed inference never invents speakers.
    results = model.process(audio).sort_by_start_time()
    labels = {}
    segments = []
    duration = info.frames / info.samplerate
    for row in results:
        start, end = float(row.start), float(row.end)
        if not math.isfinite(start) or not math.isfinite(end) or end <= start:
            raise RuntimeError("Speaker model returned an invalid segment")
        if start >= duration:
            continue
        label = labels.setdefault(row.speaker, "話者" + str(len(labels) + 1))
        segments.append({"start": round(max(0, start), 3),
                         "end": round(min(duration, end), 3), "speaker": label})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".diarization-", dir=str(args.output.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(segments, stream, ensure_ascii=False)
            stream.write("\n")
        os.replace(temporary, args.output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # No audio samples, transcription text, or source path are logged.
        print("Speaker diarization failed (" + type(error).__name__ + ")", file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Local speech detection, returning intervals only; no transcript or audio is uploaded."""
import argparse
import json
import numpy as np
import soundfile as sf
import sherpa_onnx


def intervals(path, model):
    audio, rate = sf.read(path, dtype='float32')
    if rate != 16000 or audio.ndim != 1 or not np.isfinite(audio).all():
        raise ValueError('Expected finite 16kHz mono audio')
    config = sherpa_onnx.VadModelConfig()
    config.silero_vad.model = model
    config.silero_vad.min_speech_duration = 0.25
    config.silero_vad.min_silence_duration = 0.5
    config.silero_vad.max_speech_duration = 30
    config.sample_rate = rate
    detector = sherpa_onnx.VoiceActivityDetector(config, buffer_size_in_seconds=60)
    found = []
    def drain():
        while not detector.empty():
            row = detector.front
            start = max(0, row.start / rate - 0.15)
            end = min(len(audio) / rate, (row.start + len(row.samples)) / rate + 0.15)
            if found and start <= found[-1]['end']:
                found[-1]['end'] = max(end, found[-1]['end'])
            else:
                found.append({'start': start, 'end': end})
            detector.pop()
    for offset in range(0, len(audio), 512):
        detector.accept_waveform(audio[offset:offset+512])
        drain()
    detector.flush()
    drain()
    return found


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--audio', required=True)
    parser.add_argument('--model', required=True)
    args = parser.parse_args()
    print(json.dumps(intervals(args.audio, args.model)))

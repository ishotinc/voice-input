"""Run with the meeting-runtime Python; uses temporary synthetic silence/noise only."""
import importlib.util
import pathlib
import tempfile
import numpy as np
import soundfile as sf

root = pathlib.Path(__file__).parent
spec = importlib.util.spec_from_file_location('meeting_vad', root/'Resources/meeting-vad.py')
vad = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vad)
model = str(pathlib.Path.home()/'.voice-input/meeting-models/silero_vad.onnx')
with tempfile.TemporaryDirectory() as directory:
    for name, samples in [('silence', np.zeros(400000, dtype='float32')),
                          ('click', np.pad(np.array([0.8], dtype='float32'), (1000,398999))),
                          ('tone', (0.08*np.sin(np.arange(400000)*2*np.pi*880/16000)).astype('float32'))]:
        audio = str(pathlib.Path(directory)/(name+'.wav'))
        sf.write(audio, samples, 16000)
        assert vad.intervals(audio, model) == [], name
        print('PASS: '+name+'を発話として扱わない')

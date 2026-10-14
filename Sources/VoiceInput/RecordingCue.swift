import AVFoundation
import CoreAudio

/// Play through normal audio output, retaining the player until playback completes.
final class RecordingCue: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private let startSchedule = CueSchedule()

    func cancelStart() { startSchedule.cancel() }

    func playStart(_ name: String, stillRecording: @escaping () -> Bool) {
        guard !name.isEmpty else { cancelStart(); return }
        // Input PCM can arrive before the Bluetooth output route has settled.
        // Keep recording immediately; defer only the short audible notification.
        let delay: TimeInterval = Self.bluetoothOutput ? 1.0 : 0
        Log.write("録音開始音: 出力待機 \(delay)秒")
        startSchedule.schedule(after: delay) { [weak self] in
            guard stillRecording() else { return }
            self?.play(name)
        }
    }

    private static var bluetoothOutput: Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        address.mSelector = kAudioDevicePropertyTransportType
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    func play(_ name: String) {
        cancelStart()
        guard !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent else { return }
        let url = URL(fileURLWithPath: "/System/Library/Sounds").appendingPathComponent(name + ".aiff")
        do {
            let sound = try AVAudioPlayer(contentsOf: url)
            sound.delegate = self
            sound.volume = 0.8
            sound.prepareToPlay()
            player?.stop(); player = sound
            Log.write("録音効果音 \(name): \(sound.play() ? "再生開始" : "再生失敗")")
        } catch { Log.write("録音効果音 \(name): 音源を読み込めません") }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Log.write("録音効果音: \(flag ? "再生完了" : "再生失敗")")
        if self.player === player { self.player = nil }
    }
}

import AnkiKit
import AVFoundation

/// Plays a card's sound files and TTS tags in order.
@MainActor
final class AudioPlayer: NSObject {
    private var queue: [AVTag] = []
    private var mediaFolder: URL?
    private var player: AVAudioPlayer?
    private let speech = AVSpeechSynthesizer()

    override init() {
        super.init()
        speech.delegate = self
    }

    func play(_ tags: [AVTag], mediaFolder: URL) {
        stop()
        guard !tags.isEmpty else { return }
        // Play even with the ring/silent switch on, like a media app.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        self.mediaFolder = mediaFolder
        queue = tags
        playNext()
    }

    func stop() {
        queue.removeAll()
        player?.stop()
        player = nil
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
    }

    private func playNext() {
        guard !queue.isEmpty, let mediaFolder else { return }
        let tag = queue.removeFirst()
        switch tag {
        case let .file(name):
            let url = mediaFolder.appendingPathComponent(name)
            guard let player = try? AVAudioPlayer(contentsOf: url) else {
                // Missing or unsupported (e.g. video); skip it.
                playNext()
                return
            }
            player.delegate = self
            self.player = player
            player.play()
        case let .tts(text, language, _, speed):
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: language.replacingOccurrences(of: "_", with: "-"))
            if speed > 0 {
                utterance.rate = min(max(AVSpeechUtteranceDefaultSpeechRate * speed, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
            }
            speech.speak(utterance)
        }
    }
}

extension AudioPlayer: AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playNext() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.playNext() }
    }
}

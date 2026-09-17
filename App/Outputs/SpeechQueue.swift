import AgentAlarmCore
import AVFoundation

/// 串行播报，300 毫秒内到达的多条合并成一句。
@MainActor
final class SpeechQueue: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var pending: [SpeechItem] = []
    private var speaking = false
    private var pumpScheduled = false

    var voiceIdentifier: String = ""
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func enqueue(_ item: SpeechItem) {
        pending.append(item)
        schedulePump()
    }

    /// 设置页试听用，直接播放，不参与合并。
    func speakNow(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        speaking = true
        synthesizer.speak(makeUtterance(text))
    }

    static func availableVoices() -> [(id: String, label: String)] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
            .map { ($0.identifier, "\($0.name)（\($0.language)）") }
    }

    private func schedulePump() {
        guard !pumpScheduled else { return }
        pumpScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            pumpScheduled = false
            pump()
        }
    }

    private func pump() {
        guard !speaking, !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        speaking = true
        synthesizer.speak(makeUtterance(SpeechComposer.sentence(for: batch)))
    }

    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        if !voiceIdentifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }
        utterance.rate = rate
        return utterance
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false; self.pump() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false; self.pump() }
    }
}

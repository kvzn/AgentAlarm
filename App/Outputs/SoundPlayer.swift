import AppKit

@MainActor
final class SoundPlayer {
    private var current: NSSound?

    static func systemSoundNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        return names.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
    }

    func play(name: String, volume: Double) {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = Float(max(0, min(1, volume)))
        current?.stop()
        current = sound
        sound.play()
    }
}

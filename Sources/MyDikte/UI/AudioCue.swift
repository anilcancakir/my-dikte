import AppKit
import os

/// The two sounds a dictation makes: one when recording starts, a different one when the text has
/// landed at the caret.
///
/// These matter more than the indicator panel does. The user's eyes are on the caret, not on a
/// corner of the screen, so sound is what closes the feedback loop where pixels cannot: it tells
/// the user the microphone is live without asking them to look away from what they are writing.
@MainActor
enum AudioCue: String, CaseIterable {
    case recordStart
    case insertComplete

    /// Nothing is played for longer than this. Every sound in `/System/Library/Sounds` is longer
    /// than the plan's 150 ms budget as a file (measured with `afinfo`: Tink 0.564 s, Pop 1.627 s),
    /// while both reach their peak inside the first 10 ms, so the cue is cut here rather than
    /// occupying the ear for half a second after the event it is reporting.
    private static let maximumDuration: Duration = .milliseconds(150)

    /// Two clearly different sounds, since telling "recording started" from "text inserted" by ear
    /// is the entire point of having two.
    private var systemSoundName: NSSound.Name {
        switch self {
        case .recordStart:
            return NSSound.Name("Tink")
        case .insertComplete:
            return NSSound.Name("Pop")
        }
    }

    /// Loaded once and kept: `NSSound(named:)` reads a file, and a cue that pays for that read is
    /// late for the event it is reporting.
    private static var loadedSounds: [AudioCue: NSSound] = [:]

    private static let logger = Logger(subsystem: BundleInfo.bundleIdentifier, category: "AudioCue")

    /// Plays the cue, or does nothing when the user has turned cues off in `Settings`.
    static func play(_ cue: AudioCue, enabled: Bool) {
        guard enabled else {
            return
        }
        guard let sound = sound(for: cue) else {
            return
        }

        // A cue can be asked for again before the previous one has finished (a fast cancel and
        // restart), and `NSSound.play()` refuses while the sound is already playing.
        if sound.isPlaying {
            sound.stop()
        }
        guard sound.play() else {
            logger.warning("cue \(cue.rawValue, privacy: .public) refused to play")
            return
        }

        Task { @MainActor in
            // `sleep` only throws on cancellation, and this task is never cancelled; a cue that
            // somehow outlives its own stop simply finishes at its natural length, which is
            // harmless.
            do {
                try await Task.sleep(for: maximumDuration)
            } catch {
                return
            }
            sound.stop()
        }
    }

    private static func sound(for cue: AudioCue) -> NSSound? {
        if let loaded = loadedSounds[cue] {
            return loaded
        }
        guard let sound = NSSound(named: cue.systemSoundName) else {
            // A missing system sound is not worth failing a dictation over, but it must not pass
            // unseen either: it is the reason the user would hear nothing.
            logger.error("system sound \(cue.systemSoundName, privacy: .public) is unavailable")
            return nil
        }
        loadedSounds[cue] = sound
        return sound
    }
}

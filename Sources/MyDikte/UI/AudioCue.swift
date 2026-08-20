import AppKit
import os

/// The two sounds a dictation makes: one when the microphone is actually live, a different one when
/// the text has landed at the caret.
///
/// These matter more than the indicator panel does. The user's eyes are on the caret, not on a
/// corner of the screen, so sound is what closes the feedback loop where pixels cannot: it tells
/// the user the microphone is live without asking them to look away from what they are writing.
///
/// **Both cues were reworked after the user reported not being able to tell either moment apart.**
/// Two things were wrong. `Tink` and `Pop` are both short percussive clicks, so distinguishing them
/// by ear in a quiet room was harder than having one sound would have been. And the 150 ms cut meant
/// neither reached the ear as more than a tick. `DictationPipeline` fixed the third and worst part:
/// the start cue used to fire when the audio engine was told to begin, which on a Bluetooth
/// microphone is about 1.5 s before any audio is actually delivered, so it was announcing readiness
/// that had not arrived.
@MainActor
enum AudioCue: String, CaseIterable {
    /// The microphone is delivering audio now. Deliberately not "recording started": those are the
    /// same moment on the built-in microphone and 1.5 s apart on AirPods, and the one worth a sound
    /// is the one after which speaking actually records.
    case micLive
    case insertComplete

    /// Nothing is played for longer than this. Every sound in `/System/Library/Sounds` is longer than
    /// this as a file (measured with `afinfo`: Tink 0.564 s, Submarine 1.492 s), and both reach their
    /// peak inside the first 10 ms, so a cue is cut rather than left occupying the ear after the
    /// event it reports.
    ///
    /// Raised from 150 ms, which was inaudible enough that the user asked for cues that already
    /// existed. 400 ms is long enough for Submarine's decay to read as a deliberate sound and still
    /// short enough to be over before a normal person starts speaking.
    private static let maximumDuration: Duration = .milliseconds(400)

    /// Two sounds chosen for contrast in character rather than in pitch alone: a thin metallic tick
    /// to open, a deep resonant ping to close. The previous pair were both bright clicks.
    private var systemSoundName: NSSound.Name {
        switch self {
        case .micLive:
            return NSSound.Name("Tink")
        case .insertComplete:
            return NSSound.Name("Submarine")
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

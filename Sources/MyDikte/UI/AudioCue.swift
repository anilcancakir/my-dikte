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
    /// this as a file (Hero 1.06 s, Submarine 1.49 s), so a cue is cut rather than left occupying the
    /// ear after the event it reports.
    ///
    /// Raised twice. 150 ms was inaudible enough that the user asked for cues that already existed;
    /// 400 ms was audible but still easy to miss. 600 ms lets Hero's rise and Submarine's decay both
    /// land as deliberate sounds, and is still over before a normal person starts speaking.
    private static let maximumDuration: Duration = .milliseconds(600)

    /// Two sounds chosen for loudness first and contrast second, both measured rather than guessed.
    ///
    /// Every sound in `/System/Library/Sounds` was converted to 44.1 kHz mono and its RMS taken over
    /// the window this cue actually plays. The spread is wide enough to matter: Hero leads at 0.0962,
    /// Submarine sits at 0.0685, and `Tink`, which opened the dictation until now, measured 0.0436.
    /// That is less than half of Hero, which is most of why the user could not hear the start.
    ///
    /// `NSSound` cannot amplify past a file's own level, so choosing the loudest file is the only
    /// lever short of synthesising a tone. Hero rises and Submarine falls, so the pair stay
    /// distinguishable as well as loud.
    private var systemSoundName: NSSound.Name {
        switch self {
        case .micLive:
            return NSSound.Name("Hero")
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
        // Set every time rather than once at load: `stop()` above does not touch it, but a cached
        // sound outlives any number of dictations and this is the one property that decides whether
        // the user hears the cue at all.
        sound.volume = 1.0
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

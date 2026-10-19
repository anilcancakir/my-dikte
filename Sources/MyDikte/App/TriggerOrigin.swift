/// Which Mac's shortcut started a dictation. The microphone and the pipeline are always this Mac's;
/// the origin only decides where the text lands and whose keys may end the recording.
enum TriggerOrigin: Sendable, Equatable {
    case local
    case remote
}

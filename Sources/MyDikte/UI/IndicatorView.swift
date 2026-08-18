import SwiftUI

/// The contents of the recording indicator: a red dot, a live level bar, the elapsed time and the
/// current stage, with a failure message taking the stage's place when a run ends badly, plus the
/// live preview text on a second line while the user is speaking.
///
/// The pill hugs its content rather than filling the panel, so the second line appears and
/// disappears without the panel being resized: the panel is a fixed size with room for both lines,
/// and the empty part of it is transparent and click-through like the rest.
///
/// Deliberately not interactive. SwiftUI hit-testing is disabled inside a `nonactivatingPanel`
/// (`references/pindrop/Pindrop/UI/FloatingIndicatorShared.swift:104-128`), so a control here would
/// look alive and do nothing; the panel keeps `ignoresMouseEvents` on instead.
struct IndicatorView: View {
    /// Everything the panel shows, in one observable box so the audio thread's level callback and
    /// the pipeline's stage transitions can both write to it from the main actor without the view
    /// being rebuilt.
    @MainActor
    @Observable
    final class Model {
        var stage: PipelineStage = .idle
        /// 0 to 1, straight from `AudioCapture`'s gain-scaled level callback.
        var level: Float = 0
        var elapsed: TimeInterval = 0
        /// Set when a run failed or was short-circuited; replaces the stage line while it is set.
        var message: String?
        /// What the on-device preview heard, already bounded by `LivePreview.displayText`. Empty
        /// whenever there is no preview, which is also what hides the second line.
        var previewText: String = ""
    }

    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            statusRow

            if !model.previewText.isEmpty {
                // The preview, never the result: it carries no punctuation and is thrown away, so it
                // is drawn quieter than the stage line above it.
                Text(model.previewText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
                .opacity(model.stage == .recording ? 1 : 0.3)

            levelBar

            Text(String(format: "%.1f s", model.elapsed))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(model.message ?? model.stage.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(model.message == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    /// A bar rather than a waveform: it is read from the corner of the eye, and the level arrives
    /// once per converted buffer (about every 85 ms), which is too coarse to draw a waveform from.
    private var levelBar: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.secondary.opacity(0.25))
            Capsule()
                .fill(Color.red.opacity(0.85))
                .frame(width: 46 * CGFloat(min(max(model.level, 0), 1)))
        }
        .frame(width: 46, height: 5)
    }
}

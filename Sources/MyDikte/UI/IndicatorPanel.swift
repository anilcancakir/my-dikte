import AppKit
import SwiftUI

/// The recording indicator: a small panel in a screen corner that must never take focus and never
/// swallow a click aimed at whatever is underneath it.
///
/// Every line of the configuration below is load-bearing, because the failure this panel exists to
/// avoid is caused by getting any one of them wrong. `nonactivatingPanel` keeps the click that
/// lands on it from activating MyDikte; `canBecomeKey` and `canBecomeMain` returning false keep it
/// out of the key-window chain, which is what stops it stealing focus from the editor being
/// dictated into (omit them and the panel does exactly that:
/// `references/pindrop/Pindrop/UI/FloatingIndicator.swift:137-166`); `ignoresMouseEvents` sends
/// every click through to the window underneath; `ignoresCycle` keeps it out of Cmd-Tab;
/// `canJoinAllSpaces` plus `stationary` make it follow a Space switch mid-recording; and
/// `fullScreenAuxiliary` is what lets it appear over a full-screen app at all.
///
/// It is deliberately not interactive. An interactive non-activating panel would have to override
/// `sendEvent` and route events itself, because SwiftUI hit-testing is disabled inside one
/// (`references/pindrop/Pindrop/UI/FloatingIndicatorShared.swift:104-128`). That override is
/// therefore absent on purpose, and adding a control to `IndicatorView` without adding it is how a
/// later change would produce a panel whose buttons silently do nothing.
final class IndicatorPanel: NSPanel {
    /// Tall enough for the status row plus two lines of live preview text, and fixed at that size
    /// whether or not the preview has anything to show. The alternative was resizing the panel when
    /// the first partial result arrives, which is a visible jump mid-sentence; the pill inside hugs
    /// its content instead, so the unused part of the panel is transparent and, since
    /// `ignoresMouseEvents` covers the whole panel, still click-through.
    private static let panelSize = NSSize(width: 320, height: 96)

    /// Distance from the corner of the screen's visible area. `visibleFrame` already excludes the
    /// menu bar and the notch, so the panel needs neither of the reference's notch helpers to stay
    /// clear of them.
    private static let screenInset: CGFloat = 16

    /// The elapsed-time tick. The level callback arrives about every 85 ms
    /// (`evidence/step-08-format-probe.txt`), and redrawing faster than the data changes is what
    /// the plan rules out, so this is deliberately slower than the callback.
    private static let tickInterval: TimeInterval = 0.1

    /// How long a failure message stays on screen. There is no alert and no modal for a pipeline
    /// failure by design, so this panel is where the reason is read.
    private static let failureDisplaySeconds: Double = 4.0

    private let model = IndicatorView.Model()
    private var tickTimer: Timer?
    private var hideTask: Task<Void, Never>?
    private var startedAt: ContinuousClock.Instant?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Without this, closing the panel releases it and the next `orderFront` is a use after
        // free. Nothing here ever calls `close()`, but the default is the trap either way.
        isReleasedWhenClosed = false
        // The default panel fade costs a visible fraction of a second at both ends of a run whose
        // whole budget is 1.5 s.
        animationBehavior = .none

        contentView = NSHostingView(rootView: IndicatorView(model: model))
    }

    /// A panel that can become key steals focus from the application being dictated into, and the
    /// dictation then lands nowhere. This is the single most important line in the file.
    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    /// Puts the panel on screen for a fresh run and starts the elapsed clock.
    func beginRun(stage: PipelineStage) {
        hideTask?.cancel()
        hideTask = nil

        model.stage = stage
        model.level = 0
        model.elapsed = 0
        model.message = nil
        model.previewText = ""
        startedAt = ContinuousClock.now

        moveToCorner()
        // `orderFront`, never `makeKeyAndOrderFront`: the second one is the focus theft this whole
        // type is configured to avoid.
        orderFront(nil)
        startTicking()
    }

    func update(level: Float) {
        model.level = level
    }

    func update(stage: PipelineStage) {
        model.stage = stage
    }

    /// The on-device preview's current text. Display only: it is never read back out of here, and
    /// nothing downstream of the panel can reach it.
    func update(previewText: String) {
        model.previewText = previewText
    }

    /// Ends the run. A message (a failure, a room-tone report, a cancel) keeps the panel up for a
    /// few seconds, because the plan rules out an alert or any modal for a pipeline failure and this
    /// is therefore the only place the reason can be read.
    func endRun(message: String?) {
        stopTicking()
        model.level = 0
        // The preview belonged to the audio that just stopped, so it goes with it: leaving it up
        // under a failure message would read as the text that was inserted.
        model.previewText = ""

        guard let message else {
            hide()
            return
        }

        model.stage = .idle
        model.message = message
        // A failure can arrive before the panel was ever shown (a warm-up that could not start), and
        // a message nobody can see is the silent failure this whole channel exists to avoid.
        moveToCorner()
        orderFront(nil)
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            // `sleep` only throws on cancellation, and a cancelled hide means a new run has already
            // taken the panel over, so returning is the whole handling.
            do {
                try await Task.sleep(for: .seconds(Self.failureDisplaySeconds))
            } catch {
                return
            }
            self?.hide()
        }
    }

    func hide() {
        stopTicking()
        hideTask?.cancel()
        hideTask = nil
        model.message = nil
        model.previewText = ""
        model.level = 0
        orderOut(nil)
    }

    private func startTicking() {
        stopTicking()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            // The timer fires on the main run loop, so this is the main actor; the annotation just
            // cannot be expressed on a `Timer` block.
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        // Common modes, or the elapsed time freezes for as long as a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        guard let startedAt else {
            return
        }
        model.elapsed = StageTimings.seconds(startedAt.duration(to: ContinuousClock.now))
    }

    /// Top-right of the active screen's visible area. The caret being dictated into is usually
    /// mid-screen, and the menu-bar item this app already owns is in the same corner, so the two
    /// pieces of state sit together.
    private func moveToCorner() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return
        }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - Self.panelSize.width - Self.screenInset,
            y: visible.maxY - Self.panelSize.height - Self.screenInset
        )
        setFrameOrigin(origin)
    }
}

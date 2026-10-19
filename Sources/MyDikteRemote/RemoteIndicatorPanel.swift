import AppKit
import MyDikteKit

/// The work Mac's only piece of run feedback: a small text pill in a screen corner that never takes
/// focus, because the paste goes to the application the user was in.
///
/// The configuration follows the main app's `IndicatorPanel`. `canBecomeKey` and `canBecomeMain`
/// returning false are what stop the panel from stealing focus; `ignoresMouseEvents` sends clicks
/// through to the window underneath; `fullScreenAuxiliary` lets it appear over a full-screen app.
final class RemoteIndicatorPanel: NSPanel {
    private static let textInset: CGSize = CGSize(width: 16, height: 10)
    private static let maximumTextWidth: CGFloat = 340
    private static let screenInset: CGFloat = 16
    private static let messageDisplaySeconds: Double = 6.0

    private let label: NSTextField = NSTextField(wrappingLabelWithString: "")
    private var hideTask: Task<Void, Never>?
    private var isShowingMessage: Bool = false

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 40),
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
        // Closing would release the panel and the next `orderFront` would use it after free.
        isReleasedWhenClosed = false
        animationBehavior = .none

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.maximumNumberOfLines = 4
        label.preferredMaxLayoutWidth = Self.maximumTextWidth

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.addSubview(label)
        contentView = background
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    func show(stage: RemoteMessage.Stage) {
        switch stage {
        case .recording:
            present("Recording", autoHide: false)
        case .processing:
            present("Processing", autoHide: false)
        case .idle:
            // A failure or paste error arrives just before the idle stage and must stay readable.
            if !isShowingMessage {
                hide()
            }
        }
    }

    func show(message: String) {
        present(message, autoHide: true)
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        isShowingMessage = false
        orderOut(nil)
    }

    private func present(_ text: String, autoHide: Bool) {
        hideTask?.cancel()
        hideTask = nil
        isShowingMessage = autoHide

        label.stringValue = text
        let textSize: NSSize = label.intrinsicContentSize
        label.frame = NSRect(
            x: Self.textInset.width,
            y: Self.textInset.height,
            width: textSize.width,
            height: textSize.height
        )
        setContentSize(NSSize(
            width: textSize.width + Self.textInset.width * 2,
            height: textSize.height + Self.textInset.height * 2
        ))

        moveToCorner()
        // `orderFront`, never `makeKeyAndOrderFront`: the second one takes focus from the target.
        orderFront(nil)

        guard autoHide else {
            return
        }
        hideTask = Task { @MainActor [weak self] in
            // `sleep` only throws on cancellation, and a cancelled hide means newer content owns the panel.
            do {
                try await Task.sleep(for: .seconds(Self.messageDisplaySeconds))
            } catch {
                return
            }
            self?.hide()
        }
    }

    private func moveToCorner() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return
        }
        let visible: NSRect = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: visible.maxX - frame.width - Self.screenInset,
            y: visible.maxY - frame.height - Self.screenInset
        ))
    }
}

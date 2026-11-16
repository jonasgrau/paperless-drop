import AppKit
import Observation
import SwiftUI

/// Borderless panels can't become key by default; we need key status for Esc
/// and keyboard access. As a non-activating panel it still won't steal focus.
private final class KeyPanel: NSPanel {
    var onCancel: () -> Void = {}
    /// Top edge in screen coordinates; resizes grow downwards from here.
    var anchorTop: CGFloat?

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }

    /// The app isn't active while this panel is key, so ⌘O, ⌘, and ⌘Q would never
    /// reach the main menu on their own.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        super.performKeyEquivalent(with: event) || (NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if let anchorTop { frame.origin.y = anchorTop - frame.height }
        super.setFrame(frame, display: flag)
    }
}

/// Lets the first click on a row act immediately, even though the panel isn't key yet.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Drives the show/hide animation: the panel grows out of the menu bar icon
/// and shrinks back into it, so entering and leaving follow the same path.
@MainActor
@Observable
final class PanelPresentation {
    var isShown = false
}

/// Floating panel below the menu bar icon: a drop target plus per-file status.
/// Opened by a drag, it closes ~1 s after the mouse leaves it and the icon.
/// Opened by a click on the icon, it stays until Esc, a click outside or another
/// click on the icon, so it also works with the keyboard and VoiceOver.
@MainActor
final class DropPanelController {
    enum Trigger { case drag, menu }

    private let panel: KeyPanel
    private var anchorFrame: NSRect = .zero
    private var trigger: Trigger = .drag
    private var timer: Timer?
    private var clickMonitor: Any?
    private var idleTicks = 0
    private let presentation = PanelPresentation()
    private var hideTask: Task<Void, Never>?

    init(queue: UploadQueue,
         onDrop: @escaping ([URL]) -> Void,
         onChoose: @escaping () -> Void,
         onSettings: @escaping () -> Void) {
        panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: DropPanelView.width, height: 200),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The system shadow treats the glass as a rectangle and draws a dark square-cornered
        // outline around the rounded panel. The glass has its own light edge instead.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.onCancel = { [weak self] in self?.hide() }

        let root = DropPanelView(queue: queue, presentation: presentation, onDrop: onDrop,
                                 onChoose: onChoose, onSettings: onSettings) { [weak self] height in
            self?.resize(to: height)
        }
        panel.contentView = FirstMouseHostingView(rootView: root)
    }

    /// A click on the icon: opens the panel for good, or closes it if it was opened that way.
    func toggle(below button: NSStatusBarButton) {
        if panel.isVisible, presentation.isShown, trigger == .menu {
            hide()
        } else {
            show(below: button, trigger: .menu)
        }
    }

    /// Shows the panel centered below the given status bar button.
    func show(below button: NSStatusBarButton, trigger: Trigger) {
        guard let window = button.window, let screen = window.screen ?? NSScreen.main else { return }
        hideTask?.cancel() // showing again while it is still fading out simply reverses the animation
        hideTask = nil
        // A drag never downgrades a panel the user opened on purpose.
        if !(panel.isVisible && self.trigger == .menu) { self.trigger = trigger }
        anchorFrame = window.frame
        let visible = screen.visibleFrame
        var x = anchorFrame.midX - DropPanelView.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - DropPanelView.width - 8)
        panel.anchorTop = anchorFrame.minY - 4
        panel.setFrame(NSRect(x: x, y: 0, width: DropPanelView.width, height: panel.frame.height), display: true)
        panel.orderFrontRegardless()
        if self.trigger == .menu { panel.makeKey() }
        // One run-loop hop, so SwiftUI has rendered the hidden state it animates from.
        Task { presentation.isShown = true }

        idleTicks = 0
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.trigger == .menu else { return }
                    if !self.anchorFrame.contains(NSEvent.mouseLocation) { self.hide() }
                }
            }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        presentation.isShown = false
        hideTask?.cancel()
        hideTask = Task { [panel] in
            try? await Task.sleep(for: .milliseconds(250)) // let the exit animation finish
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }

    private func resize(to height: CGFloat) {
        var frame = panel.frame
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    private func tick() {
        guard trigger == .drag else { return }
        let mouse = NSEvent.mouseLocation
        let hovering = panel.frame.insetBy(dx: -10, dy: -10).contains(mouse) || anchorFrame.contains(mouse)
        let dragging = NSEvent.pressedMouseButtons != 0
        if hovering || dragging {
            idleTicks = 0
            return
        }
        idleTicks += 1
        if idleTicks >= 2 { hide() } // ticks are 0.5 s
    }
}

struct DropPanelView: View {
    static let width: CGFloat = 340
    private static let padding: CGFloat = 12
    private static let emptyHeight: CGFloat = 108
    private static let summaryHeight: CGFloat = 18
    private static let summaryGap: CGFloat = 6
    private static let rowHeight: CGFloat = 42
    private static let footerHeight: CGFloat = 24
    private static let footerGap: CGFloat = 6
    private static let visibleRows = 5

    let queue: UploadQueue
    let presentation: PanelPresentation
    let onDrop: ([URL]) -> Void
    let onChoose: () -> Void
    let onSettings: () -> Void
    let onHeightChange: (CGFloat) -> Void
    @State private var isTargeted = false
    @State private var isHoveringEmptyState = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Rows that need attention come first: running work, then failures, then
    /// duplicates and skipped files, and the successes last.
    private var sortedItems: [UploadQueue.Item] {
        func rank(_ status: UploadQueue.Status) -> Int {
            switch status {
            case .uploading, .processing: 0
            case .queued: 1
            case .failed: 2
            case .duplicate, .skipped: 3
            case .done: 4
            }
        }
        return queue.items.enumerated()
            .sorted { (rank($0.element.status), $0.offset) < (rank($1.element.status), $1.offset) }
            .map(\.element)
    }

    private var listHeight: CGFloat {
        CGFloat(min(queue.items.count, Self.visibleRows)) * Self.rowHeight
    }

    private var height: CGFloat {
        let footer = Self.footerGap + Self.footerHeight
        if queue.items.isEmpty { return Self.padding * 2 + Self.emptyHeight + footer }
        return Self.padding * 2 + Self.summaryHeight + Self.summaryGap + listHeight + footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if queue.items.isEmpty {
                emptyState
            } else {
                summary
                    .frame(height: Self.summaryHeight)
                    .padding(.bottom, Self.summaryGap)
                list
            }
            footer
        }
        .padding(Self.padding)
        .frame(width: Self.width, height: height, alignment: .top)
        .modifier(PanelSurface(isTargeted: isTargeted))
        .overlay { dropOutline }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            onDrop(files)
            return true
        } isTargeted: { isTargeted = $0 }
        .onChange(of: height, initial: true) { _, newHeight in onHeightChange(newHeight) }
        // Grows out of the icon (top edge) and shrinks back; reduced motion only fades.
        .scaleEffect(reduceMotion || presentation.isShown ? 1 : 0.94, anchor: .top)
        .opacity(presentation.isShown ? 1 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0),
                   value: presentation.isShown)
        // The panel is rarely the key window; without this its controls draw in inactive grey.
        .environment(\.controlActiveState, .key)
    }

    /// The whole panel is the drop target, so the dashed outline only appears
    /// while a file is over it. Radius 16 = panel radius 22 minus the 6 pt inset (concentric).
    private var dropOutline: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return shape
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .background(Color.accentColor.opacity(0.08), in: shape)
            .padding(6)
            .opacity(isTargeted ? 1 : 0)
            .animation(.smooth(duration: 0.15), value: isTargeted)
            .allowsHitTesting(false)
    }

    /// Nothing listed yet: a large target that also works as a button for the file chooser.
    private var emptyState: some View {
        let color = isTargeted ? Color.accentColor : (isHoveringEmptyState ? Color.primary : Color.secondary)
        return Button(action: onChoose) {
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 28))
                Text("Drop PDFs here").font(.callout)
                Text("or click to choose").font(.caption)
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: Self.emptyHeight)
        .onHover { isHoveringEmptyState = $0 }
        .help("Choose PDFs…")
        .accessibilityLabel("Choose PDFs to upload")
    }

    /// Choose-hint on the left (once files are listed), Settings and Quit on the
    /// right. Both are also in the menu bar icon's right-click menu.
    private var footer: some View {
        HStack(spacing: 10) {
            if !queue.items.isEmpty {
                Button(action: onChoose) {
                    Text("Drop more PDFs here or choose…").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .accessibilityLabel("Choose PDFs to upload")
            }
            Spacer(minLength: 0)
            RowButton(symbol: "gearshape", label: "Settings", help: "Settings (⌘,)", action: onSettings)
            // Dimmed until hovered: Quit is rare and has no confirmation when nothing is uploading.
            RowButton(symbol: "power", label: "Quit Paperless Drop", help: "Quit (⌘Q)", dimmed: true) {
                NSApp.terminate(nil)
            }
        }
        .frame(height: Self.footerHeight)
        .padding(.top, Self.footerGap)
    }

    private var summary: some View {
        let items = queue.items
        let count = { (match: (UploadQueue.Status) -> Bool) in items.filter { match($0.status) }.count }
        let added = count { if case .done = $0 { true } else { false } }
        let duplicates = count { if case .duplicate = $0 { true } else { false } }
        let failed = count { $0.isFailure }
        let skipped = count { if case .skipped = $0 { true } else { false } }
        let uploads = items.count - skipped

        var parts: [String] = []
        if queue.isBusy {
            parts.append("\(uploads - count(\.isActive)) of \(uploads) finished")
        } else if added > 0 {
            parts.append("\(added) added")
        }
        if duplicates > 0 { parts.append(duplicates == 1 ? "1 duplicate" : "\(duplicates) duplicates") }
        if failed > 0 { parts.append("\(failed) failed") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        let text = parts.joined(separator: " · ")

        return HStack(spacing: 8) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
                .help(text)
            Spacer(minLength: 0)
            if items.contains(where: { !$0.status.isActive }) {
                Button("Clear") { queue.clearFinished() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHint("Removes finished files from the list")
            }
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder private var list: some View {
        let rows = VStack(spacing: 0) {
            ForEach(sortedItems) { item in
                ItemRow(
                    item: item,
                    documentURL: queue.documentURL(for: item),
                    retry: { queue.retry(item.id) },
                    cancel: { queue.cancel(item.id) },
                    openSettings: onSettings
                )
                .frame(height: Self.rowHeight)
            }
        }
        if queue.items.count > Self.visibleRows {
            ScrollView { rows }
                .frame(height: listHeight)
                .mask {
                    // Fade the bottom edge so cut-off rows read as "more below".
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 24)
                    }
                }
        } else {
            rows
        }
    }
}

/// The panel's one glass layer. Rows sit on top as plain content: glass on glass
/// would wash out. The outer radius is 22 so the 16 pt drop outline, inset 6 pt, is concentric.
private struct PanelSurface: ViewModifier {
    let isTargeted: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(.separator))
        } else if #available(macOS 26, *) {
            content.glassEffect(
                .regular.tint(isTargeted ? Color.accentColor.opacity(0.18) : nil),
                in: shape
            )
            .animation(.smooth(duration: 0.2), value: isTargeted)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private struct ItemRow: View {
    let item: UploadQueue.Item
    let documentURL: URL?
    let retry: () -> Void
    let cancel: () -> Void
    let openSettings: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileURL.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
            }
            Spacer(minLength: 0)
            if isHovered || (isUploading && canCancel) { action }
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered && isClickable ? Color.primary.opacity(0.07) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: activate)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.fileURL.lastPathComponent), \(statusText)")
        .accessibilityAddTraits(isClickable ? .isButton : [])
        .accessibilityAction(.default, activate)
        .accessibilityActions {
            if item.status.isFailure { Button("Retry", action: retry) }
            if item.needsSettings { Button("Open Settings", action: openSettings) }
            if canCancel { Button("Cancel upload", action: cancel) }
        }
    }

    private var isUploading: Bool {
        if case .uploading = item.status { true } else { false }
    }

    /// Once the last byte is sent the file is on the server, so there is nothing left to cancel.
    private var canCancel: Bool {
        switch item.status {
        case .queued: true
        case .uploading(let progress): progress < 1
        default: false
        }
    }

    /// Finished rows open the document; a failure caused by URL or token opens Settings.
    private var isClickable: Bool { documentURL != nil || item.needsSettings }

    private func activate() {
        if let documentURL {
            NSWorkspace.shared.open(documentURL)
        } else if item.needsSettings {
            openSettings()
        }
    }

    @ViewBuilder private var action: some View {
        switch item.status {
        case .failed:
            if item.needsSettings {
                RowButton(symbol: "gearshape", label: "Open Settings", action: openSettings)
            }
            RowButton(symbol: "arrow.clockwise", label: "Retry", action: retry)
        case .queued, .uploading:
            if canCancel { RowButton(symbol: "xmark", label: "Cancel upload", action: cancel) }
        case .done, .duplicate:
            if documentURL != nil {
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var detail: some View {
        if case .uploading(let progress) = item.status {
            HStack(spacing: 6) {
                // Drawn by hand: the system bar and spinner pick wrong, low-contrast colors on glass.
                Capsule()
                    .fill(.primary.opacity(0.2))
                    .overlay(alignment: .leading) {
                        GeometryReader { geometry in
                            Capsule()
                                .fill(.primary)
                                .frame(width: geometry.size.width * progress)
                                .animation(.linear(duration: 0.2), value: progress)
                        }
                    }
                    .frame(height: 4)
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder private var icon: some View {
        switch item.status {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .uploading: Image(systemName: "arrow.up.circle").foregroundStyle(.primary)
        case .processing:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.primary)
                .symbolEffect(.pulse, options: .repeating)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .duplicate: Image(systemName: "equal.circle.fill").foregroundStyle(.orange)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }

    private var statusText: String {
        switch item.status {
        case .queued: "Waiting"
        case .uploading(let progress): "Uploading \(Int(progress * 100)) percent"
        case .processing: "Processing in Paperless…"
        case .done: item.distinctTitle.map { "Added as “\($0)”" } ?? "Added to Paperless"
        case .duplicate(let id, _):
            if let title = item.distinctTitle {
                "Already in Paperless as “\(title)”"
            } else if let id {
                "Already in Paperless (#\(id))"
            } else {
                "Already in Paperless"
            }
        case .skipped(let message), .failed(let message, _): message
        }
    }

    private var statusColor: Color {
        item.status.isFailure ? .red : .secondary
    }

    /// Tooltip with the full text, since the status line is truncated to one line.
    private var helpText: String {
        if documentURL != nil { return "\(statusText) – click to open in Paperless" }
        if item.needsSettings { return "\(statusText) – click to open Settings" }
        return statusText
    }
}

private struct RowButton: View {
    let symbol: String
    let label: String
    var help: String?
    /// Rarely wanted actions rest in secondary color and light up on hover.
    var dimmed = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(dimmed && !isHovered ? Color.secondary : Color.primary)
        .onHover { isHovered = $0 }
        .help(help ?? label)
        .accessibilityLabel(label)
    }
}

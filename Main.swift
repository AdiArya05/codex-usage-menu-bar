import AppKit
import CoreText
import QuartzCore
import SwiftUI

@MainActor
private func codexIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let outline = NSBezierPath()
        let scale = size / 16
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * scale, y: y * scale) }
        outline.move(to: point(3.2, 5.6))
        outline.curve(to: point(3.9, 12), controlPoint1: point(0.1, 6.9), controlPoint2: point(0.7, 10.8))
        outline.curve(to: point(10, 13.5), controlPoint1: point(4.7, 15.2), controlPoint2: point(8, 15.8))
        outline.curve(to: point(14.2, 9.5), controlPoint1: point(13, 14.2), controlPoint2: point(15, 12.3))
        outline.curve(to: point(12, 3.9), controlPoint1: point(16.6, 7.3), controlPoint2: point(15.5, 4.4))
        outline.curve(to: point(6.7, 2.8), controlPoint1: point(11.1, 1), controlPoint2: point(8.3, 1.1))
        outline.curve(to: point(3.2, 5.6), controlPoint1: point(4.5, 2.3), controlPoint2: point(2.8, 3.7))
        outline.close()
        let ink = outline.bounds
        let center = AffineTransform(translationByX: size / 2 - ink.midX,
                                     byY: size / 2 - ink.midY)
        NSColor.black.setStroke()
        outline.lineWidth = 1.25 * scale
        outline.lineCapStyle = .round
        outline.lineJoinStyle = .round

        outline.move(to: point(5.2, 10.3))
        outline.line(to: point(7, 8.3))
        outline.line(to: point(5.2, 6.4))
        outline.move(to: point(8.6, 6.4))
        outline.line(to: point(11, 6.4))
        outline.transform(using: center)
        outline.stroke()
        return true
    }
    image.isTemplate = true
    return image
}

private let loadingCycleDuration: TimeInterval = 1.3
private let loadingFrameCount = 156

private func loadingFrame(at elapsed: TimeInterval) -> Int {
    let phase = max(0, elapsed).truncatingRemainder(dividingBy: loadingCycleDuration) / loadingCycleDuration
    return Int((phase * Double(loadingFrameCount)).rounded()) % loadingFrameCount
}

@MainActor
private enum LoadingArtwork {
    static let frames = (0..<loadingFrameCount).map { frame in
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in
            for dot in 0..<6 {
                let phase = 2 * Double.pi * (0.25 - Double(frame) / Double(loadingFrameCount) - Double(dot) / 6)
                let center = NSPoint(x: bounds.midX + CGFloat(cos(phase)) * 5.1,
                                     y: bounds.midY + CGFloat(sin(phase)) * 5.1)
                let strength = 1 - CGFloat(dot) / 5
                let radius = 0.81 + 0.73 * strength
                if dot < 2 {
                    let glow = NSGradient(starting: .black.withAlphaComponent(0.26 * strength), ending: .clear)
                    glow?.draw(fromCenter: center, radius: radius, toCenter: center, radius: radius + 1.1)
                }
                NSColor.black.withAlphaComponent(0.35 + 0.65 * strength).setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                            width: 2 * radius, height: 2 * radius)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.cacheMode = .always
        return image
    }
}

private func requestFastRefresh(_ link: CADisplayLink) {
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    link.add(to: .main, forMode: .common)
}

struct Dashboard: View {
    @ObservedObject var usage: Usage

    private var priorityRows: [QuotaRow] {
        let available = usage.rows.filter { $0.window.remaining > 0 }.prefix(3)
        let depleted = usage.rows.filter { $0.window.remaining == 0 }.prefix(2)
        return Array(available) + depleted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if usage.lastSync == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(usage.error ?? "Connecting to Codex…").font(.headline)
                    Text(usage.error == nil ? "Reading your personal usage." : "Check that Codex is installed and signed in, then refresh.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            } else {
                if priorityRows.isEmpty {
                    Text("No active quota windows").foregroundStyle(.secondary)
                } else {
                    section("Usage")
                    VStack(spacing: 12) {
                        ForEach(priorityRows) { quota($0) }
                    }
                }
                if usage.activity.working {
                    workingOn
                }
                Divider()
                resetDetails
            }

            HStack(spacing: 8) {
                if usage.syncing { ProgressView().controlSize(.small) }
                Text(syncLabel)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Menu {
                    Button("Refresh now") { usage.refresh() }
                    Divider()
                    Button("Quit Codex Usage") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .modifier(GlassSurface(radius: 17, interactive: true))
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Usage options")
            }
        }
        .padding(20)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var workingOn: some View {
        let chats = usage.activity.workingChats
        return VStack(alignment: .leading, spacing: 8) {
            section("Working on")
            if chats.isEmpty {
                Text("Codex task").font(.system(size: 16, weight: .semibold))
            }
            ForEach(chats.prefix(3)) { chat in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(chat.title)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .help(chat.title)
                    Spacer(minLength: 0)
                    if let directory = chat.directory {
                        Label(URL(fileURLWithPath: directory).lastPathComponent, systemImage: "folder")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 135, alignment: .trailing)
                            .help(directory)
                    }
                }
                .font(.system(size: 16))
            }
            if chats.count > 3 {
                Text("+\(chats.count - 3) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(chats.dropFirst(3).map(\.title).joined(separator: "\n"))
            }
        }
    }

    private var syncLabel: String {
        if usage.syncing { return "Syncing…" }
        if let error = usage.error {
            return usage.lastSync == nil ? "Retrying shortly" : "\(error) · showing last update"
        }
        if let date = usage.nextSync {
            let seconds = Int(ceil(date.timeIntervalSince(usage.now)))
            return seconds > 0 ? "Next update in \(seconds)s" : "Updating shortly"
        }
        return "Connecting…"
    }

    private var resetDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            section("Resets")
            detail("Earned resets left", usage.resets.map { String($0.availableCount) } ?? "Unavailable")
                .help("Codex does not provide the date of your last earned reset.")
            if let expiry = usage.nextExpiry {
                detail("Next earned reset expires", countdown(expiry, now: usage.now))
                    .help(expiry.formatted(date: .abbreviated, time: .shortened))
            }

        }
    }

    private func section(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).monospacedDigit()
        }
        .font(.system(size: 15))
    }

    private func quota(_ row: QuotaRow) -> some View {
        let value = row.window.remaining
        return HStack(spacing: 12) {
            ZStack {
                Circle().strokeBorder(.secondary.opacity(0.26), lineWidth: 4)
                if value > 0 {
                    Circle().inset(by: 2).trim(from: 0, to: CGFloat(value) / 100)
                        .stroke(.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                if usage.expanded && usage.activity.working && row.id == usage.headline?.id {
                    LoadingSpinner().frame(width: 20, height: 20)
                } else {
                    Image(nsImage: codexIcon(size: 20))
                }
            }
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.window.label).font(.headline)
                Text(row.name == "Codex" ? usage.account : row.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(value)% left")
                    .font(.headline)
                    .monospacedDigit()
                if let reset = row.window.reset {
                    Text(countdown(reset, now: usage.now))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
        .help(row.window.reset.map {
            "Resets \($0.formatted(date: .abbreviated, time: .shortened))"
        } ?? row.window.label)
    }
}

private struct LoadingSpinner: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> LoadingImageView {
        let view = LoadingImageView()
        view.image = LoadingArtwork.frames[0]
        view.imageScaling = .scaleProportionallyUpOrDown
        view.contentTintColor = .labelColor
        return view
    }

    func updateNSView(_ view: LoadingImageView, context: Context) {
        view.motionEnabled = !reduceMotion
    }

    static func dismantleNSView(_ view: LoadingImageView, coordinator: ()) {
        view.motionEnabled = false
    }
}

private final class LoadingImageView: NSImageView {
    var motionEnabled = true {
        didSet { updateDisplayLink() }
    }

    private var link: CADisplayLink?
    private var startedAt: TimeInterval?
    private var lastFrame = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDisplayLink()
    }

    private func updateDisplayLink() {
        guard window != nil && motionEnabled else {
            link?.invalidate()
            link = nil
            startedAt = nil
            lastFrame = 0
            image = LoadingArtwork.frames[0]
            return
        }
        guard link == nil else { return }
        let displayLink = displayLink(target: self, selector: #selector(advance(_:)))
        link = displayLink
        requestFastRefresh(displayLink)
    }

    @objc private func advance(_ link: CADisplayLink) {
        let start = startedAt ?? link.targetTimestamp
        startedAt = start
        let frame = loadingFrame(at: link.targetTimestamp - start)
        guard frame != lastFrame else { return }
        lastFrame = frame
        image = LoadingArtwork.frames[frame]
    }
}

private struct GlassSurface: ViewModifier {
    let radius: CGFloat
    var interactive = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        if #available(macOS 26.0, *) {
            content.glassEffect(.clear.interactive(interactive), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private final class ActivityDot: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PriorityPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let usage = Usage()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var dashboard = NSHostingView(rootView: Dashboard(usage: usage))
    private lazy var panel = makePanel()
    private let statusIcon = codexIcon(size: 16)
    private var lastStatus: String?
    private var animation: CADisplayLink?
    private var loadingStartedAt: CFTimeInterval?
    private var frames: [NSImage] = []
    private var frameIndex = 0
    private var attentionDot: NSView?
    private lazy var activityMonitor = ActivityMonitor { [weak self] in self?.setActivity($0) }
    private var localMonitor: Any?
    private var outsideMonitor: Any?
    private var anchor: NSRect?
    private var screenFrame: NSRect?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.target = self
        item.button?.action = #selector(toggle)
        usage.onChange = { [weak self] in
            guard let self else { return }
            self.updateStatus()
            if self.usage.expanded { self.positionPanel() }
        }
        updateStatus()
        usage.start()
        activityMonitor.start()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        if usage.expanded { dismiss() }
        animation?.invalidate()
        activityMonitor.stop()
        usage.stop()
    }

    @objc private func wake() { usage.wake() }

    private func makePanel() -> PriorityPanel {
        let panel = PriorityPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: true)
        panel.title = "Codex Usage"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 26
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true

        dashboard.frame = backdrop.bounds
        dashboard.autoresizingMask = [.width, .height]
        backdrop.addSubview(dashboard)
        panel.contentView = backdrop
        return panel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !usage.expanded { showPanel() }
        return false
    }

    @objc private func toggle() {
        if usage.expanded {
            dismiss()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = item.button, let window = button.window, let screen = window.screen else { return }
        anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        screenFrame = screen.visibleFrame
        usage.expanded = true
        refreshStatusPresentation()
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        usage.refresh()

        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.dismiss()
                return nil
            }
            return event
        }
    }

    private func positionPanel() {
        guard let anchor, let screenFrame else { return }
        let size = dashboard.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let x = max(screenFrame.minX + 8, min(anchor.midX - size.width / 2, screenFrame.maxX - size.width - 8))
        let y = min(anchor.minY - 5, screenFrame.maxY - 5) - size.height
        let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func dismiss() {
        guard usage.expanded else { return }
        usage.expanded = false
        panel.orderOut(nil)
        refreshStatusPresentation()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        localMonitor = nil
        outsideMonitor = nil
    }

    private func setActivity(_ value: CodexActivity) {
        let previous = usage.activity
        guard previous != value else { return }
        usage.activity = value
        if previous.working != value.working || previous.signal != value.signal {
            refreshStatusPresentation()
        }
        if usage.expanded && (previous.working != value.working || previous.workingChats != value.workingChats) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.usage.expanded else { return }
                self.positionPanel()
            }
        }
    }

    private func refreshStatusPresentation() {
        lastStatus = nil
        updateStatus()
        updateAnimation()
    }

    private func updateAnimation() {
        guard frames.count > 1, let button = item.button else {
            animation?.invalidate()
            animation = nil
            if !usage.activity.working { loadingStartedAt = nil }
            frameIndex = 0
            return
        }
        guard animation == nil else { return }

        let link = button.displayLink(target: self, selector: #selector(advanceLoading(_:)))
        animation = link
        requestFastRefresh(link)
    }

    @objc private func advanceLoading(_ link: CADisplayLink) {
        let timestamp = link.targetTimestamp
        let start = loadingStartedAt ?? timestamp
        loadingStartedAt = start
        let index = loadingFrame(at: timestamp - start)
        guard index != frameIndex, frames.indices.contains(index) else { return }
        frameIndex = index
        item.button?.image = frames[index]
    }

    private func updateStatus() {
        guard let button = item.button else { return }
        let value = usage.headline.map { "\($0.window.remaining)%" } ?? "—"
        guard value != lastStatus else { return }
        lastStatus = value
        let activity = usage.activity
        let showLoading = activity.working && !usage.expanded
        let animateLoading = showLoading && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let frameCount = animateLoading ? loadingFrameCount : 1
        let badgeWidth: CGFloat = activity.signal == nil ? 0 : 11
        frames = (0..<frameCount).map { frame in
            let icon = showLoading ? LoadingArtwork.frames[frame] : statusIcon
            return statusImage(icon: icon, value: value, leading: badgeWidth)
        }
        frameIndex %= frames.count
        let image = frames[frameIndex]
        button.image = image
        attentionDot?.removeFromSuperview()
        attentionDot = nil
        if let signal = activity.signal {
            let color: NSColor
            switch signal {
            case .needsInput: color = .systemYellow
            case .finished: color = .systemGreen
            case .failed: color = .systemRed
            }
            let dot = ActivityDot()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.wantsLayer = true
            dot.layer?.backgroundColor = color.cgColor
            dot.layer?.cornerRadius = 3
            button.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
                dot.centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: (6 - image.size.width) / 2),
                dot.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
            attentionDot = dot
        }
        let description = "Codex usage, \(value) left · \(activity.label)"
        button.setAccessibilityLabel(description)
        button.toolTip = description
    }

    private func statusImage(icon: NSImage, value: String, leading: CGFloat) -> NSImage {
        let label = NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.black
        ])
        let gap: CGFloat = 8
        let line = CTLineCreateWithAttributedString(label)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let labelWidth = ceil(label.size().width)
        let image = NSImage(size: NSSize(width: leading + icon.size.width + gap + labelWidth,
                                        height: 18), flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            icon.draw(at: NSPoint(x: leading, y: (bounds.height - icon.size.height) / 2),
                      from: .zero, operation: .sourceOver, fraction: 1)
            // Center the visible glyphs, independent of the font's line spacing.
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: leading + icon.size.width + gap + labelWidth / 2 - ink.midX,
                                           y: bounds.midY - ink.midY)
            CTLineDraw(line, context)
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        image.cacheMode = .always
        return image
    }
}

@main
struct CodexUsageApp {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

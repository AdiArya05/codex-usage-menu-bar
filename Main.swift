import AppKit
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
        outline.move(to: point(5.2, 10.3))
        outline.line(to: point(7, 8.3))
        outline.line(to: point(5.2, 6.4))
        outline.move(to: point(8.6, 6.4))
        outline.line(to: point(11, 6.4))
        NSColor.black.setStroke()
        outline.lineWidth = 1.25 * scale
        outline.lineCapStyle = .round
        outline.lineJoinStyle = .round
        outline.stroke()
        return true
    }
    image.isTemplate = true
    return image
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
                Image(nsImage: codexIcon(size: 20))
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        if usage.expanded { dismiss() }
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
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        localMonitor = nil
        outsideMonitor = nil
    }

    private func updateStatus() {
        guard let button = item.button else { return }
        let value = usage.headline.map { "\($0.window.remaining)%" } ?? "—"
        guard value != lastStatus else { return }
        lastStatus = value
        let label = NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.black
        ])
        let icon = statusIcon
        let gap: CGFloat = 8
        let labelSize = label.size()
        let image = NSImage(size: NSSize(width: ceil(icon.size.width + gap + labelSize.width),
                                        height: 20), flipped: false) { bounds in
            icon.draw(at: NSPoint(x: 0, y: (bounds.height - icon.size.height) / 2),
                      from: .zero, operation: .sourceOver, fraction: 1)
            label.draw(at: NSPoint(x: icon.size.width + gap,
                                   y: (bounds.height - labelSize.height) / 2))
            return true
        }
        image.isTemplate = true
        button.image = image
        let description = "Codex usage, \(value) left"
        button.setAccessibilityLabel(description)
        button.toolTip = description
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

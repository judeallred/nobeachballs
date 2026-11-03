import AppKit
import NoBeachballsCore
import Combine
import ServiceManagement
import SwiftUI

@main
enum NoBeachballsApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Monitor!
    private var statusItem: StatusItemController!
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--snapshot out.png` renders the window and `--icon-snapshot out.png` every icon state,
        // then exit (for docs and testing). Both only observe; they never throttle anything.
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--icon-snapshot"), flag + 1 < args.count {
            StatusItemController.renderStates(to: URL(fileURLWithPath: args[flag + 1]))
            NSApp.terminate(nil)
            return
        }
        if let flag = args.firstIndex(of: "--snapshot"), flag + 1 < args.count {
            monitor = Monitor(controlsProcesses: false)
            snapshot(to: URL(fileURLWithPath: args[flag + 1]))
            return
        }

        // Two copies would fight over the same processes and ledger, so only one runs.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty {
            NSLog("nobeachballs: another copy is already running (pid \(others[0].processIdentifier)); exiting")
            NSApp.terminate(nil)
            return
        }

        monitor = Monitor()

        statusItem = StatusItemController(monitor: monitor)

        // `kill`, logout and `launchctl` stop us with signals; resume everything first.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [monitor] in
                monitor?.releaseAllSync()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.releaseAllSync()
    }

    private func snapshot(to url: URL) {
        monitor.isVisible = true
        let view = NSHostingView(rootView: MonitorView(monitor: monitor))
        view.frame = NSRect(x: 0, y: 0, width: 940, height: 760)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            NSApp.terminate(nil)
        }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("nobeachballs: login item change failed: \(error)")
        }
    }
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private let monitor: Monitor
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let listState = ProcessListState()
    private var cancellables: Set<AnyCancellable> = []
    private var lastIconKey: String?

    init(monitor: Monitor) {
        self.monitor = monitor
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentSize = NSSize(width: 940, height: 760)

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
        }

        monitor.$snapshot
            .sink { [weak self] snapshot in
                self?.updateIcon(report: snapshot.report, usage: Self.usage(snapshot.system),
                                 throttling: !snapshot.autoPaused.isEmpty || !snapshot.deprioritized.isEmpty,
                                 pausedCount: snapshot.autoPaused.count)
            }
            .store(in: &cancellables)
    }

    /// What the needle shows: whichever of CPU or memory is closer to running out.
    /// Memory uses the kernel's "available" figure, since macOS keeps RAM nearly full by design.
    static func usage(_ system: SystemSample?) -> Double {
        guard let system else { return 0 }
        return max(system.cpuTotal, 1 - Double(system.memAvailablePercent) / 100)
    }

    static func gaugeSymbol(for usage: Double) -> String {
        let step = switch usage {
        case ..<0.17: "0"
        case ..<0.42: "33"
        case ..<0.58: "50"
        case ..<0.84: "67"
        default: "100"
        }
        return "gauge.with.dots.needle.\(step)percent"
    }

    private func updateIcon(report: HealthReport, usage: Double, throttling: Bool, pausedCount: Int) {
        guard let button = item.button else { return }
        let iconKey = "\(report.level):\(Self.gaugeSymbol(for: usage)):\(throttling)"
        if iconKey != lastIconKey {
            button.image = Self.icon(level: report.level, usage: usage, throttling: throttling)
            lastIconKey = iconKey
        }

        var tip = "No Beachballs — \(report.level.label)"
        tip += String(format: " (%.0f%% load)", usage * 100)
        if !report.reasons.isEmpty { tip += ": " + report.reasons.joined(separator: ", ") }
        if pausedCount > 0 { tip += "\n\(pausedCount) job(s) paused by auto-throttle" }
        button.toolTip = tip
    }

    /// The gauge, with its needle at `usage`, plus a colored badge in the bottom-right corner
    /// for alert and throttling states.
    static func icon(level: HealthLevel, usage: Double, throttling: Bool) -> NSImage? {
        guard let gauge = NSImage(systemSymbolName: gaugeSymbol(for: usage), accessibilityDescription: level.label)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) else { return nil }

        let badge: NSImage?
        switch level {
        case .lagging: badge = Self.badge("exclamationmark.triangle.fill", .systemRed)
        case .strained: badge = Self.badge("exclamationmark.triangle.fill", .systemOrange)
        case .elevated, .ok: badge = throttling ? Self.badge("tortoise.fill", .systemTeal, twoTone: false) : nil
        }
        guard let badge else {
            // Pure template image: the menu bar tints it for light/dark and highlight states.
            gauge.isTemplate = true
            return gauge
        }

        // A colored badge can't live in a template image, so the gauge is drawn in labelColor,
        // which resolves against the menu bar's appearance at draw time.
        let badgeSize = NSSize(width: 10, height: 9)
        let size = NSSize(width: gauge.size.width + 3, height: max(gauge.size.height, 16))
        let image = NSImage(size: size, flipped: false) { rect in
            let gaugeRect = NSRect(x: 0, y: (rect.height - gauge.size.height) / 2, width: gauge.size.width, height: gauge.size.height)
            gauge.draw(in: gaugeRect)
            NSColor.labelColor.set()
            gaugeRect.fill(using: .sourceAtop)

            let badgeRect = NSRect(x: rect.maxX - badgeSize.width, y: 0, width: badgeSize.width, height: badgeSize.height)
            // Knock out a thin ring around the badge so it separates from the gauge.
            badge.draw(in: badgeRect.insetBy(dx: -1.5, dy: -1.5), from: .zero, operation: .destinationOut, fraction: 1)
            badge.draw(in: badgeRect)
            return true
        }
        image.accessibilityDescription = level.label
        return image
    }

    /// Renders the icon in each state, on light and dark menu bars, to one PNG (for docs and testing).
    static func renderStates(to url: URL) {
        let states: [(HealthLevel, Double, Bool)] = [
            (.ok, 0.1, false), (.ok, 0.5, false), (.elevated, 0.75, false),
            (.elevated, 0.75, true), (.strained, 0.9, false), (.lagging, 1, true),
        ]
        let scale: CGFloat = 4, cell: CGFloat = 26
        let size = NSSize(width: cell * CGFloat(states.count) * scale, height: cell * 2 * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (row, (appearance, background)) in [(NSAppearance.Name.darkAqua, NSColor(white: 0.16, alpha: 1)),
                                                (.aqua, NSColor(white: 0.92, alpha: 1))].enumerated() {
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                let y = CGFloat(row) * cell * scale
                background.setFill()
                NSRect(x: 0, y: y, width: size.width, height: cell * scale).fill()
                for (i, state) in states.enumerated() {
                    guard let icon = icon(level: state.0, usage: state.1, throttling: state.2) else { continue }
                    let w = icon.size.width * scale, h = icon.size.height * scale
                    let x = CGFloat(i) * cell * scale + (cell * scale - w) / 2
                    if icon.isTemplate {
                        // Mimic the menu bar's template tinting.
                        let tinted = NSImage(size: icon.size, flipped: false) { r in
                            icon.draw(in: r)
                            NSColor.labelColor.set()
                            r.fill(using: .sourceAtop)
                            return true
                        }
                        tinted.draw(in: NSRect(x: x, y: y + (cell * scale - h) / 2, width: w, height: h))
                    } else {
                        icon.draw(in: NSRect(x: x, y: y + (cell * scale - h) / 2, width: w, height: h))
                    }
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func badge(_ symbol: String, _ color: NSColor, twoTone: Bool = true) -> NSImage? {
        // Two-tone: a white "!" on a colored triangle reads at 10pt on any menu bar.
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .black)
            .applying(.init(paletteColors: twoTone ? [.white, color] : [color]))
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            prepareDashboard()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate()
        }
    }

    var dashboardController: NSViewController? { popover.contentViewController }

    func prepareDashboard() {
        popover.contentViewController = NSHostingController(
            rootView: MonitorView(monitor: monitor, listState: listState))
        monitor.isVisible = true
    }

    func discardDashboard() {
        monitor.isVisible = false
        // A hidden hosting controller still observes and lays out the dashboard on every tick.
        popover.contentViewController = nil
    }

    func popoverDidClose(_ notification: Notification) {
        discardDashboard()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openFromMenu), keyEquivalent: "").target = self

        let modes = NSMenu()
        for mode in ThrottleMode.allCases {
            let entry = modes.addItem(withTitle: mode.label, action: #selector(setMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            entry.state = monitor.mode == mode ? .on : .off
        }
        let modeItem = menu.addItem(withTitle: "Auto-throttle", action: nil, keyEquivalent: "")
        modeItem.submenu = modes

        menu.addItem(withTitle: "Resume everything", action: #selector(resumeAll), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit No Beachballs", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openFromMenu() { togglePopover() }
    @objc private func resumeAll() { monitor.resumeEverything() }
    @objc private func toggleLogin() { LoginItem.set(!LoginItem.isEnabled) }

    @objc private func setMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = ThrottleMode(rawValue: raw) {
            monitor.mode = mode
        }
    }
}

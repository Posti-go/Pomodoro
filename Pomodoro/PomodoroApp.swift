import AppKit
import Combine
import SwiftUI

@main
struct PomodoroApp: App {
    @NSApplicationDelegateAdaptor(PomodoroAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
private final class PomodoroAppDelegate: NSObject, NSApplicationDelegate {
    private let timer = PomodoroTimerModel()
    private var statusItem: NSStatusItem?
    private var panel: TimerPanel?
    private var aboutWindow: NSWindow?
    private var timerStateCancellable: AnyCancellable?
    private var alarmStateCancellable: AnyCancellable?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.toolTip = "Pomodoro Timer"
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        statusItem = item
        updateStatusItemForAlarm(isPlaying: false)

        let timerPanel = TimerPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 466))
        let hostingView = NSHostingView(rootView: ContentView(timer: timer))
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 466)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 56
        hostingView.layer?.masksToBounds = true
        timerPanel.contentView = hostingView
        panel = timerPanel
        timerStateCancellable = timer.$isRunning
            .dropFirst()
            .sink { [weak self] isRunning in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.timer.isRunning == isRunning else { return }
                        self.resizePanel(isRunning: isRunning)
                    }
                }
            }
        alarmStateCancellable = timer.$isAlarmPlaying
            .dropFirst()
            .sink { [weak self] isAlarmPlaying in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.timer.isAlarmPlaying == isAlarmPlaying else { return }
                        self.updateStatusItemForAlarm(isPlaying: isAlarmPlaying)
                        if isAlarmPlaying {
                            self.presentAlarm()
                        }
                    }
                }
            }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            if event.type == .keyDown, event.keyCode == 53 {
                MainActor.assumeIsolated {
                    self?.hidePanel()
                }
                return nil
            }
            if event.type == .rightMouseDown {
                let showedMenu = MainActor.assumeIsolated {
                    self?.showStatusContextMenu(for: event) ?? false
                }
                if showedMenu { return nil }
            }
            MainActor.assumeIsolated {
                self?.hidePanelIfClickOutside()
            }
            return event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.hidePanelIfClickOutside()
            }
        }
    }

    @objc private func togglePanel(_ sender: Any?) {
        guard let panel else { return }
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    private func updateStatusItemForAlarm(isPlaying: Bool) {
        guard let statusItem, let button = statusItem.button else { return }

        if isPlaying {
            statusItem.length = NSStatusItem.variableLength
            button.image = nil
            button.imagePosition = .noImage
            button.title = "Time's up!"
            button.attributedTitle = NSAttributedString(
                string: "Time's up!",
                attributes: [
                    .foregroundColor: NSColor.white,
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium)
                ]
            )
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor(
                srgbRed: 231.0 / 255.0,
                green: 58.0 / 255.0,
                blue: 0,
                alpha: 1
            ).cgColor
            button.layoutSubtreeIfNeeded()
            button.layer?.cornerRadius = button.bounds.height / 2
            button.layer?.masksToBounds = true
            button.toolTip = "Time's up!"
        } else {
            statusItem.length = NSStatusItem.squareLength
            button.attributedTitle = NSAttributedString(string: "")
            button.title = ""
            button.imagePosition = .imageOnly
            if let icon = NSImage(named: "MenuBarIcon") {
                icon.isTemplate = true
                icon.size = NSSize(width: 18, height: 18)
                button.image = icon
            }
            button.layer?.backgroundColor = NSColor.clear.cgColor
            button.layer?.cornerRadius = 0
            button.layer?.masksToBounds = false
            button.toolTip = "Pomodoro Timer"
        }
    }

    private func showStatusContextMenu(for event: NSEvent) -> Bool {
        guard let button = statusItem?.button,
              let window = button.window,
              event.window === window else { return false }
        let point = button.convert(event.locationInWindow, from: nil)
        guard button.bounds.contains(point) else { return false }

        hidePanel()
        let menu = NSMenu()
        let aboutItem = NSMenuItem(title: "About Pomodoro", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Pomodoro", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.midX, y: button.bounds.minY), in: button)
        return true
    }

    @objc private func showAbout(_ sender: Any?) {
        if let aboutWindow {
            aboutWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 256),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.setFrame(NSRect(origin: .zero, size: NSSize(width: 320, height: 256)), display: false)
        window.title = "About Pomodoro"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.hasShadow = true
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.minSize = window.frame.size
        window.maxSize = window.frame.size

        let hostingView = NSHostingView(rootView: AboutView(version: version))
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        window.center()
        aboutWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showPanel() {
        guard let panel, let button = statusItem?.button, let statusWindow = button.window else { return }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = statusWindow.convertToScreen(buttonRect)
        let screen = statusWindow.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero

        var origin = NSPoint(
            x: screenRect.maxX - panel.frame.width,
            y: screenRect.minY - panel.frame.height - 6
        )
        origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - panel.frame.width)
        origin.y = max(origin.y, visibleFrame.minY)
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
    }

    private func presentAlarm() {
        guard let panel, !panel.isVisible else { return }

        var frame = panel.frame
        let fixedTop = frame.maxY
        frame.size.height = 466
        frame.origin.y = fixedTop - frame.height
        panel.setFrame(frame, display: true)
        showPanel()
    }

    private func resizePanel(isRunning: Bool) {
        guard let panel else { return }
        let targetHeight: CGFloat = isRunning ? 369.5 : 466
        var targetFrame = panel.frame
        let fixedTop = panel.frame.maxY
        targetFrame.origin.y = fixedTop - targetHeight
        targetFrame.size.height = targetHeight

        NSAnimationContext.runAnimationGroup { context in
            context.duration = TimerPanelTransition.duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    fileprivate func hidePanel() {
        panel?.orderOut(nil)
    }

    private func hidePanelIfClickOutside() {
        guard let panel, panel.isVisible else { return }
        let mouseLocation = NSEvent.mouseLocation
        if panel.frame.contains(mouseLocation) { return }

        if let button = statusItem?.button, let statusWindow = button.window {
            let rect = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
            if rect.contains(mouseLocation) { return }
        }
        hidePanel()
    }
}

private final class TimerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
    }
}

private struct AboutView: View {
    let version: String

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 104, height: 104)
                .padding(.top, 32)

            Text("Pomodoro")
                .font(.system(size: 18, weight: .bold))
                .padding(.top, 16)

            Text("Version \(version)")
                .font(.system(size: 14))
                .padding(.top, 8)

            Text("© Carlos Postigo")
                .font(.system(size: 14))
                .padding(.top, 8)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

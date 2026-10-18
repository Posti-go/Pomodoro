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
    private var timerStateCancellable: AnyCancellable?
    private var alarmStateCancellable: AnyCancellable?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let icon = NSImage(named: "MenuBarIcon") {
            icon.isTemplate = true
            icon.size = NSSize(width: 18, height: 18)
            item.button?.image = icon
        }
        item.button?.toolTip = "Pomodoro Timer"
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        statusItem = item

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
                guard isAlarmPlaying else { return }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.timer.isAlarmPlaying else { return }
                        self.presentAlarm()
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

    private func showStatusContextMenu(for event: NSEvent) -> Bool {
        guard let button = statusItem?.button,
              let window = button.window,
              event.window === window else { return false }
        let point = button.convert(event.locationInWindow, from: nil)
        guard button.bounds.contains(point) else { return false }

        hidePanel()
        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit Pomodoro", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.midX, y: button.bounds.minY), in: button)
        return true
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

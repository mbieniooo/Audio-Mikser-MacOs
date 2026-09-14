import AppKit
import SwiftUI
import MikserCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = MixerModel()
    private var control: ControlChannel?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var clickMonitor: Any?
    private var openRequestedAt: CFAbsoluteTime = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Mikser")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Mikser — per-app volume"
        }
        statusItem = item

        let hosting = NSHostingController(rootView: PopoverView(model: model, onQuit: { NSApp.terminate(nil) }))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        model.start()
        let channel = ControlChannel(model: model)
        channel.onQuit = { NSApp.terminate(nil) }
        channel.install()
        control = channel
        NSLog("Mikser started (running=\(model.isRunning) error=\(model.startError ?? "none"))")
    }

    func applicationWillTerminate(_ notification: Notification) {
        control?.remove()
        model.stop()
    }

    @objc private func togglePopover() {
        if popover.isShown { closePopover() } else { openPopover() }
    }

    private func openPopover() {
        guard let button = statusItem?.button else { return }
        openRequestedAt = CFAbsoluteTimeGetCurrent()
        model.freezeOrder()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.closePopover() }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    func popoverDidShow(_ notification: Notification) {
        let ms = (CFAbsoluteTimeGetCurrent() - openRequestedAt) * 1000
        NSLog("Mikser popover open in %.1f ms (%d rows)", ms, model.rows.count)
    }

    func popoverDidClose(_ notification: Notification) {
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor); clickMonitor = nil }
        model.unfreezeOrder()
    }
}

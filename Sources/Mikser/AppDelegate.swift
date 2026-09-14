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
    private var lastOpenMs: Double?

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

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        model.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.prepareContent() }
        let channel = ControlChannel(model: model)
        channel.onQuit = { NSApp.terminate(nil) }
        channel.popoverHandler = { [weak self] open in
            guard let self else { return nil }
            if open, !self.popover.isShown { self.openPopover() }
            if !open, self.popover.isShown { self.closePopover() }
            return self.lastOpenMs
        }
        channel.snapshotHandler = { [weak self] dir in self?.snapshotPopover(into: dir) ?? [] }
        channel.install()
        control = channel
        NSLog("Mikser started (running=\(model.isRunning) error=\(model.startError ?? "none"))")
    }

    func applicationWillTerminate(_ notification: Notification) {
        control?.remove()
        model.stop()
    }

    /// Builds and pre-warms the SwiftUI content once. The first layout costs ~120 ms, so it happens
    /// here, off the user's click. (Dropping the content after close was measured: it frees nothing.)
    private func prepareContent() {
        guard popover.contentViewController == nil else { return }
        let hosting = NSHostingController(rootView: PopoverView(model: model, onQuit: { NSApp.terminate(nil) }))
        hosting.sizingOptions = [.preferredContentSize]
        hosting.loadViewIfNeeded()
        hosting.view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        hosting.view.layoutSubtreeIfNeeded()
        popover.contentViewController = hosting
    }

    @objc private func togglePopover() {
        if popover.isShown { closePopover() } else { openPopover() }
    }

    private func openPopover() {
        guard let button = statusItem?.button else { return }
        openRequestedAt = CFAbsoluteTimeGetCurrent()
        prepareContent()
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

    /// Draws the popover content in light and dark appearance to PNG files (no screen-recording permission needed).
    private func snapshotPopover(into dir: URL) -> [String] {
        guard popover.isShown, let view = popover.contentViewController?.view else { return [] }
        var written: [String] = []
        let original = popover.appearance
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            popover.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            // The popover material supplies the real background; composite over the window colour so
            // the PNG is readable on its own in both appearances.
            let composed = NSImage(size: view.bounds.size)
            composed.lockFocus()
            (name == "dark" ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
            rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
            composed.unlockFocus()
            guard let tiff = composed.tiffRepresentation, let outRep = NSBitmapImageRep(data: tiff),
                  let png = outRep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { continue }
            let url = dir.appendingPathComponent("popover-\(name).png")
            if (try? png.write(to: url)) != nil { written.append(url.path) }
        }
        popover.appearance = original
        return written
    }

    func popoverDidShow(_ notification: Notification) {
        let ms = (CFAbsoluteTimeGetCurrent() - openRequestedAt) * 1000
        lastOpenMs = ms
        NSLog("Mikser popover open in %.1f ms (%d rows)", ms, model.rows.count)
    }

    func popoverDidClose(_ notification: Notification) {
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor); clickMonitor = nil }
        model.unfreezeOrder()
    }
}

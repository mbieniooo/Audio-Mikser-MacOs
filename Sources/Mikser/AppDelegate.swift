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
        channel.snapshotHandler = { [weak self] dir, done in
            if let self { self.snapshotPopover(into: dir, completion: done) } else { done([]) }
        }
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

    /// Captures the popover content in light and dark appearance (verification only). The SwiftUI view
    /// draws an opaque window background while `snapshotBackground` is set, so the PNG is readable alone.
    private func snapshotPopover(into dir: URL, completion: @escaping ([String]) -> Void) {
        guard popover.isShown, let view = popover.contentViewController?.view else { completion([]); return }
        let original = popover.appearance
        var written: [String] = []
        model.snapshotBackground = true
        func capture(_ name: String) {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { return }
            let url = dir.appendingPathComponent("popover-\(name).png")
            if (try? png.write(to: url)) != nil { written.append(url.path) }
        }
        popover.appearance = NSAppearance(named: .aqua)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            capture("light")
            self?.popover.appearance = NSAppearance(named: .darkAqua)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                capture("dark")
                self?.popover.appearance = original
                self?.model.snapshotBackground = false
                completion(written)
            }
        }
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

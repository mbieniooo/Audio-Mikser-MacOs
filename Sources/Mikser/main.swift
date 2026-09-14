import AppKit
import MikserCore

// Interim app entry (task T4 adds the popover UI): status item, model, control channel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MixerModel()
    var control: ControlChannel?
    var item: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item?.button?.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Mikser")
        model.start()
        let channel = ControlChannel(model: model)
        channel.onQuit = { NSApp.terminate(nil) }
        channel.install()
        control = channel
        NSLog("Mikser started (running=\(model.isRunning) error=\(model.startError ?? "none"))")
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

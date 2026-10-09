import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static var shared: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        shared = delegate // delegate is weak
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var model: MixerModel!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = MixerModel()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "Levels")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePanel)
        }

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        model.panelOpened()
        // rebuilt each open, dropped on close
        popover.contentViewController = MixerPanel(model: model)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        model.onChange = nil
        popover.contentViewController = nil
    }
}

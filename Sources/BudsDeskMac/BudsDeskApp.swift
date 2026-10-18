import AppKit
import Combine
import SwiftUI
import BudsCore

/// The app: one window, one menu-bar item, and the appearance it was verified in.
///
/// Written with AppKit directly rather than with a SwiftUI `App`, for two reasons that are both
/// load-bearing here and neither of which is taste:
///
/// - **The appearance is pinned.** The palette was contrast-audited against one appearance. A
///   second appearance that no one checked would be a claim with nothing behind it, so the app
///   asks for dark and stays there. That is a deliberate limit, and it is written down rather
///   than left to the user's system setting.
/// - **The menu-bar item has to be able to disappear.** When no device is paired there is nothing
///   to glance at, so the item is removed from the status bar rather than left showing nothing.
///   That is the honest reading of "the buds are away", and it is easier to get right with
///   `NSStatusBar` than to fake through a binding.
public enum BudsDeskApp {
    @MainActor public static func main() {
        let application = NSApplication.shared
        application.appearance = NSAppearance(named: .darkAqua)
        application.setActivationPolicy(.regular)

        let delegate = AppDelegate()
        application.delegate = delegate
        // Held for the process's lifetime: `NSApplication.delegate` is a weak reference, and a
        // delegate that deallocates is an app that does nothing.
        objc_setAssociatedObject(application, "budsdesk.delegate", delegate,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let model = AppModel()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        // A first launch with the earbuds away shows the window and says so; the item appears on
        // its own once they are found. Showing the window is right for a `.regular` app and for
        // someone who has just installed it and has no idea whether it is running.
        showWindow()
        model.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.refresh() }
        }.store(in: &cancellables)
        refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The window is the app. Closing it with the menu-bar item still there would leave a
        // process with an icon and no way to reach the controls; the menu item has a Quit.
        false
    }

    // MARK: - The window

    func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "BudsDesk"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: DeviceWindow(model: model))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - The menu bar

    /// Present only while the earbuds are. The item is added and removed from the status bar
    /// rather than merely hidden, so an app with nothing to show leaves no empty slot behind.
    private func refresh() {
        if model.isPresent {
            if statusItem == nil { installStatusItem() }
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        updateStatusItemAppearance()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "BudsDesk")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = "BudsDesk"
        item.menu = statusMenu()
        statusItem = item
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        button.title = statusTitle()
        // NSButton wants these as setters, not as properties.
        button.setAccessibilityLabel("BudsDesk")
        button.setAccessibilityValue(statusTitle().isEmpty ? "No earbuds connected"
                                                         : "Battery \(statusTitle())")
    }

    /// The glance: the two buds' charge, and nothing else. Percentages are what the hardware
    /// reports, not a re-scaled number.
    private func statusTitle() -> String {
        guard let session = model.session, session.isReady else { return "" }
        var parts: [String] = []
        if let left = session.battery.left { parts.append("L \(left)%") }
        if let right = session.battery.right { parts.append("R \(right)%") }
        return parts.joined(separator: "  ")
    }

    private func statusMenu() -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open BudsDesk", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        // Rebuilt on demand rather than kept in step: a status menu is built when it is opened, so
        // there is nothing to keep in sync.
        menu.delegate = self
        let quit = NSMenuItem(title: "Quit BudsDesk", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    @objc private func openWindow() { showWindow() }

    // MARK: - The main menu

    /// Built in code because there is no nib. Without it the app has no Cmd-Q, no Cmd-W and no
    /// way to copy the firmware string out of the window, which is the one thing in it a person
    /// is most likely to want to paste somewhere.
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About BudsDesk",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide BudsDesk",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit BudsDesk",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Filled every time it opens, because that is the only moment the numbers matter.
    func menuNeedsUpdate(_ menu: NSMenu) {
        // The static items are the first and last; everything between them is rebuilt.
        while menu.numberOfItems > 2 { menu.removeItem(at: 1) }
        guard let session = model.session, session.isReady else {
            let item = NSMenuItem(title: model.status, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.insertItem(item, at: 1)
            return
        }

        var index = 1
        func add(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.insertItem(item, at: index)
            index += 1
        }

        add("Battery — \(statusTitle().isEmpty ? "not reported" : statusTitle())")
        if let firmware = session.firmware { add("Firmware — \(firmware)") }
        if let codec = session.codec { add("Codec — \(codec.label)") }
        if let mode = session.mode {
            add("Noise — \(mode.label)" + (session.ancLevel.map { " (\($0.label))" } ?? ""))
        }
        if let preset = session.eqPreset { add("Equalizer — \(preset.label)") }
        if session.isCaseReported, session.battery.enclosure == nil {
            add("Case — present, no charge reported")
        }
        add("Model — \(model.profile?.model ?? "unknown")")
        menu.insertItem(.separator(), at: index)
    }
}

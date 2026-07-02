import AppKit
import Combine
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = AppStore()
    private var notch: NotchController?
    private var statusItem: NSStatusItem?
    private var contextMenu: NSMenu?
    private var hotKeyRef: EventHotKeyRef?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)   // Dock icon: clearly running + re-openable
        setupMainMenu()
        Notifier.requestAuthorization()
        store.start()

        let notch = NotchController(store: store)
        self.notch = notch
        // Show on launch so there is visible feedback even if the menu-bar icon is
        // tucked behind the notch; the close button / icon collapse it.
        notch.show()

        setupStatusItem()
        observeStore()
        registerGlobalHotkey()

        // Dev affordance: HUBPLUS_OPEN=stats|agents force-expands the panel on launch
        // so UI states can be screenshotted/verified without synthetic mouse events.
        switch ProcessInfo.processInfo.environment["HUBPLUS_OPEN"] {
        case "stats":  notch.openExpanded(showing: .stats)
        case "agents": notch.openExpanded(showing: .agents)
        default: break
        }
    }

    /// Clicking the Dock icon (no visible windows) re-opens the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        notch?.openExpanded()
        return true
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Hub+",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }

    /// ⌃⌥H toggles the panel regardless of whether the menu-bar icon is reachable
    /// (it can be tucked behind the notch). Carbon hot keys need no special permission.
    private func registerGlobalHotkey() {
        // Observer does the UI work on the main queue. The Carbon callback only posts.
        NotificationCenter.default.addObserver(
            forName: .hubPlusToggle, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.notch?.toggle() }
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            NotificationCenter.default.post(name: .hubPlusToggle, object: nil)
            return noErr
        }, 1, &eventType, nil, nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x48554250), id: 1)  // 'HUBP'
        RegisterEventHotKey(UInt32(kVK_ANSI_H),
                            UInt32(controlKey | optionKey),
                            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.menuBarIcon()
            button.imagePosition = .imageLeading
            button.action = #selector(statusClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Hub+", action: #selector(togglePanel), keyEquivalent: "")
        open.target = self
        let quitItem = NSMenuItem(title: "Quit Hub+", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        contextMenu = menu
    }

    /// Keep the menu-bar label in sync with sessions/usage.
    private func observeStore() {
        store.objectWillChange
            .sink { [weak self] in
                DispatchQueue.main.async { self?.updateStatusTitle() }
            }
            .store(in: &cancellables)
        updateStatusTitle()
    }

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        let badge = store.compactBadge()
        button.title = badge.text.isEmpty ? "" : " \(badge.text)"
        button.contentTintColor = badge.alert ? .systemRed : .systemOrange
    }

    private static func menuBarIcon() -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        for name in ["sparkle", "sparkles", "asterisk"] {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: "Hub+") {
                let configured = img.withSymbolConfiguration(cfg) ?? img
                configured.isTemplate = true
                return configured
            }
        }
        return nil
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            // Pop the context menu, then detach it so left-click keeps toggling.
            statusItem?.menu = contextMenu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            notch?.toggle()
        }
    }

    @objc private func togglePanel() { notch?.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension Notification.Name {
    static let hubPlusToggle = Notification.Name("HubPlusToggle")
}

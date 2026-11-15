//
//  StatusItemController.swift
//  Cue
//
//  §4.9's status menu, deliberately short. Settings, a hide-when-Music-quits
//  option and a global hotkey were all considered and dropped: the panel has
//  nowhere to put preferences that are not already one click away, and Music
//  owns the media keys while it is running.
//

import AppKit
import OSLog
import ServiceManagement

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let togglePanel: () -> Void
    private let quitApp: () -> Void

    /// Always on Top is the panel's business, so the controller owns the state
    /// and this only reflects and flips it.
    private let isAlwaysOnTop: () -> Bool
    private let setAlwaysOnTop: (Bool) -> Void

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nz.slstudio.Cue",
                                category: "StatusItem")

    private var alwaysOnTopItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?

    init(
        togglePanel: @escaping () -> Void,
        isAlwaysOnTop: @escaping () -> Bool,
        setAlwaysOnTop: @escaping (Bool) -> Void,
        quit: @escaping () -> Void
    ) {
        self.togglePanel = togglePanel
        self.isAlwaysOnTop = isAlwaysOnTop
        self.setAlwaysOnTop = setAlwaysOnTop
        self.quitApp = quit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        if let button = statusItem.button {
            button.image = Self.menuBarImage()
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(withTitle: "Show/Hide Panel", action: #selector(showWindow), keyEquivalent: "")

        menu.addItem(.separator())

        alwaysOnTopItem = menu.addItem(
            withTitle: "Always on Top",
            action: #selector(toggleAlwaysOnTop),
            keyEquivalent: ""
        )
        launchAtLoginItem = menu.addItem(
            withTitle: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Cue", action: #selector(terminate), keyEquivalent: "q")

        for item in menu.items where item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    /// Both ticks are read fresh each time the menu opens. Launch at Login in
    /// particular can be changed in System Settings behind our back, so a value
    /// cached at launch would drift out of step with reality.
    func menuNeedsUpdate(_ menu: NSMenu) {
        alwaysOnTopItem?.state = isAlwaysOnTop() ? .on : .off
        launchAtLoginItem?.state = Self.launchesAtLogin ? .on : .off
    }

    // MARK: - Actions

    @objc private func showWindow() { togglePanel() }
    @objc private func terminate() { quitApp() }

    @objc private func toggleAlwaysOnTop() {
        setAlwaysOnTop(!isAlwaysOnTop())
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if Self.launchesAtLogin {
                try SMAppService.mainApp.unregister()
                logger.notice("launch at login: unregistered")
            } else {
                try SMAppService.mainApp.register()
                logger.notice("launch at login: registered")
            }
        } catch {
            logger.error("launch at login failed: \(error.localizedDescription, privacy: .public)")
            presentLoginItemFailure(error)
        }
    }

    /// `.enabled` is the only status that means it will actually launch.
    /// `.requiresApproval` means macOS has it but the user has switched it off
    /// in System Settings, which should read as off here rather than on.
    private static var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func presentLoginItemFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t change Launch at Login"
        alert.informativeText = """
            \(error.localizedDescription)

            Cue can also be added by hand in System Settings → General → \
            Login Items & Extensions.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Menu bar glyph

    /// `playpause` — chosen in the menu bar itself, which is the only place
    /// worth judging it.
    ///
    /// `music.pages` won on a rendered contact sheet and then failed in situ:
    /// its internal detail survives black-on-white at 16 pt but disappears
    /// against a real translucent menu bar. `music.note.tv` was the other
    /// contender, but reads as AirPlay or screen sharing. A two-shape glyph
    /// with plenty of open space is what holds up at this size.
    ///
    /// Overridable without a rebuild:
    ///
    ///     defaults write nz.slstudio.Cue MenuBarSymbol waveform
    ///     defaults delete nz.slstudio.Cue MenuBarSymbol
    static let defaultSymbol = "playpause"

    private static func menuBarImage() -> NSImage? {
        let name = UserDefaults.standard.string(forKey: "MenuBarSymbol") ?? defaultSymbol
        return NSImage(systemSymbolName: name, accessibilityDescription: "Cue")
            ?? NSImage(systemSymbolName: defaultSymbol, accessibilityDescription: "Cue")
    }
}

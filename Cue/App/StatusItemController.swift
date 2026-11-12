//
//  StatusItemController.swift
//  Cue
//
//  Minimal still: without a Dock icon there has to be some way to reach the
//  panel and to quit. §4.9's full menu — Always on Top, Launch at Login,
//  Settings, global hotkey — is M5.
//

import AppKit

@MainActor
final class StatusItemController: NSObject {

    private let statusItem: NSStatusItem
    private let togglePanel: () -> Void
    private let quitApp: () -> Void

    init(togglePanel: @escaping () -> Void, quit: @escaping () -> Void) {
        self.togglePanel = togglePanel
        self.quitApp = quit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        if let button = statusItem.button {
            button.image = Self.menuBarImage()
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Show/Hide Panel", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Cue", action: #selector(terminate), keyEquivalent: "q")
        for item in menu.items where item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    /// The menu-bar glyph, overridable without a rebuild so candidates can be
    /// compared in place rather than imagined:
    ///
    ///     defaults write nz.slstudio.Cue MenuBarSymbol waveform
    ///     defaults delete nz.slstudio.Cue MenuBarSymbol     # back to the default
    ///
    /// Any SF Symbol name works; this macOS carries 8,647 of them. An unknown
    /// name falls back rather than leaving an empty menu bar.
    /// `music.pages` — Julian's pick, with an echo of old iTunes. `music.note.tv`
    /// was the other contender but reads as AirPlay or screen sharing, which
    /// would collide with §4.7's actual AirPlay picker in M4.
    static let defaultSymbol = "music.pages"

    private static func menuBarImage() -> NSImage? {
        let name = UserDefaults.standard.string(forKey: "MenuBarSymbol") ?? defaultSymbol
        return NSImage(systemSymbolName: name, accessibilityDescription: "Cue")
            ?? NSImage(systemSymbolName: defaultSymbol, accessibilityDescription: "Cue")
    }

    @objc private func showWindow() { togglePanel() }
    @objc private func terminate() { quitApp() }
}

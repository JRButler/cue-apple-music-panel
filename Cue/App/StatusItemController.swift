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
            button.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: "Cue")
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

    @objc private func showWindow() { togglePanel() }
    @objc private func terminate() { quitApp() }
}

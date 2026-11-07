//
//  StatusItemController.swift
//  Cue
//
//  Minimal for M0: without a Dock icon there has to be some way to reach the
//  app and to quit it. §4.9's full menu — Show/Hide Panel, Always on Top,
//  Launch at Login, Settings — is M5.
//

import AppKit

@MainActor
final class StatusItemController: NSObject {

    private let statusItem: NSStatusItem
    private let showDebugWindow: () -> Void
    private let quitApp: () -> Void

    init(showDebugWindow: @escaping () -> Void, quit: @escaping () -> Void) {
        self.showDebugWindow = showDebugWindow
        self.quitApp = quit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: "Cue")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Debug Window…", action: #selector(showWindow), keyEquivalent: "d")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Cue", action: #selector(terminate), keyEquivalent: "q")
        for item in menu.items where item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    @objc private func showWindow() { showDebugWindow() }
    @objc private func terminate() { quitApp() }
}

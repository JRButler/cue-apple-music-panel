//
//  main.swift
//  Cue
//
//  Explicit entry point, deliberately not `@main` on the delegate.
//
//  In an LSUIElement agent, annotating an NSApplicationDelegate with @main
//  leaves the delegate's lifecycle callbacks silently unfired — no crash, no
//  warning, just an app that launches and does nothing. Setting the delegate on
//  NSApplication.shared by hand and calling run() is the arrangement that works.
//
//  `delegate` is a top-level binding, so it is a global and outlives this file.
//

import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate

// §2: no Dock icon. The status item is the only chrome.
application.setActivationPolicy(.accessory)
application.run()

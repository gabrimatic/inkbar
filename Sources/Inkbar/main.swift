import AppKit

// One instance only: a second launch (a binary started by hand, another copy) hands over to
// the running Inkbar, which shows its window, and quits.
let ownPID = ProcessInfo.processInfo.processIdentifier
if let bundleID = Bundle.main.bundleIdentifier,
   let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
       .first(where: { $0.processIdentifier != ownPID && !$0.isTerminated }) {
    if let url = other.bundleURL { NSWorkspace.shared.open(url) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

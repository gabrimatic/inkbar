import Darwin
import AppKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let log = Logger(subsystem: "info.gabrimatic.inkbar", category: "app")
    private var statusItem: NSStatusItem?
    private var settings: AppSettings?
    private var monitor: SelectionMonitor?
    private var bar: BarController?
    /// The running app, for App Intents that act on it.
    static weak var shared: AppDelegate?

    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A plain `kill` (SIGTERM) skips `applicationWillTerminate`; this turns it into a normal quit.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        term.resume()
        terminationSignal = term

        // Launch leaves freed heap behind; hand it back once everything has settled.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            malloc_zone_pressure_relief(nil, 0)
        }
        Self.shared = self
        Typeface.register()
        MainMenu.install(target: self)
        let settings = AppSettings.shared
        self.settings = settings
        if !settings.loginConfigured {
            if let error = LoginItem.set(true) {
                log.error("login item registration failed: \(error, privacy: .public)")
            }
            settings.loginConfigured = true
        }

        let bar = BarController(settings: settings)
        let monitor = SelectionMonitor(settings: settings)
        monitor.isShowing = { [weak bar] in bar?.isVisible ?? false }
        monitor.onDismiss = { [weak bar] in bar?.hide() }
        bar.planActions = { [weak settings] context, topic, reading in
            guard let settings else { return [] }
            // The clipboard is read only when Paste Clean could show: an editable field and the action on.
            let canPaste = context.editable && settings.enabledActions.contains(.pasteClean)
            return ActionPlanner.actions(order: settings.order, enabled: settings.enabledActions,
                                         analysis: context.analysis, editable: context.editable,
                                         clipboardHasText: canPaste && Clipboard.hasPlainText(),
                                         targetLanguage: settings.effectiveTarget,
                                         intelligence: Intelligence.isAvailable
                                             && Intelligence.supports(language: context.analysis.language),
                                         topic: topic, reading: reading)
        }
        monitor.onSelection = { [weak bar] context in
            guard let bar else { return }
            bar.show(context, actions: bar.planActions(context, TopicReader.known(context.analysis), nil))
        }
        self.bar = bar
        self.monitor = monitor

        settings.onPausedChange = { [weak self] in self?.applyState() }
        settings.onMenuBarIconChange = { [weak self] in self?.applyStatusItem() }
        let permissions = Permissions.shared
        permissions.onChange = { [weak self] trusted in
            self?.log.info("accessibility trusted: \(trusted, privacy: .public)")
            self?.applyState()
        }
        applyStatusItem()
        applyState()

        if !settings.onboardingDone {
            WelcomeWindowController.shared.show()
        } else if !permissions.trusted {
            // Welcome was finished but the grant is gone (removed in System Settings): say so with one button.
            SettingsWindowController.shared.show(pane: .permissions)
        }
        log.info("launched, trusted: \(permissions.trusted, privacy: .public), login item: \(LoginItem.statusDescription, privacy: .public), menu bar icon: \(settings.showMenuBarIcon, privacy: .public)")
    }

    /// Shows the menu bar icon only when the setting is on. Everything it offers is also in Settings.
    private func applyStatusItem() {
        guard let settings else { return }
        if settings.showMenuBarIcon {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                let menu = NSMenu()
                menu.delegate = self
                item.menu = menu
                statusItem = item
            }
            updateIcon()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// Runs the monitor only when it can work and is wanted.
    private func applyState() {
        guard let settings, let monitor else { return }
        if Permissions.shared.trusted && !settings.isPaused {
            monitor.start()
        } else {
            monitor.stop()
            bar?.hide(animated: false)
        }
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem?.button, let settings else { return }
        button.image = BrandMark.menuBarImage(description: "Inkbar")
        let inactive = settings.isPaused || !Permissions.shared.trusted
        button.appearsDisabled = inactive
        if settings.focusPaused && !settings.paused {
            button.toolTip = "Inkbar (paused by Focus)"
        } else {
            button.toolTip = settings.paused ? "Inkbar (paused)" : (Permissions.shared.trusted ? "Inkbar" : "Inkbar needs Accessibility access")
        }
    }

    /// For the Show Inkbar intent. False when nothing readable is selected.
    func showForCurrentSelection() -> Bool {
        // The first need for Accessibility: ask with the system prompt instead of failing silently.
        if !Permissions.shared.trusted {
            Permissions.shared.requestAccessibility()
            return false
        }
        return monitor?.presentCurrentSelection() ?? false
    }

    // MARK: Reopen, quit

    /// Opening Inkbar again from Finder, Spotlight or Launchpad while it runs brings up its window,
    /// so everything stays reachable with the menu bar icon switched off.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    /// The welcome window until it is finished, Settings after that.
    func showMainWindow() {
        if AppSettings.shared.onboardingDone {
            SettingsWindowController.shared.show()
        } else {
            WelcomeWindowController.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Inkbar changes nothing outside itself; this only takes the bar and the watchers down cleanly.
        Handoff.clear()
        bar?.hide(animated: false)
        monitor?.stop()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(togglePause) { menuItem.state = settings?.paused == true ? .on : .off }
        return true
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let settings else { return }
        Permissions.shared.refresh()
        menu.removeAllItems()
        let trusted = Permissions.shared.trusted
        let status: String
        if !trusted {
            status = "Needs Accessibility"
        } else if settings.paused {
            status = "Paused"
        } else if settings.focusPaused {
            status = "Paused by Focus"
        } else {
            status = "On"
        }
        menu.addItem(.appName("Inkbar", state: status))
        if !trusted {
            let grant = NSMenuItem(title: "Allow Accessibility…", action: #selector(openAccessibility), keyEquivalent: "")
            grant.target = self
            grant.show(symbol: "exclamationmark.triangle")
            menu.addItem(grant)
        }
        menu.addItem(.separator())

        let pause = NSMenuItem(title: "Pause Inkbar", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = settings.paused ? .on : .off
        pause.show(symbol: "pause.circle")
        menu.addItem(pause)

        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        prefs.show(symbol: "gearshape")
        menu.addItem(prefs)

        let about = NSMenuItem(title: "About Inkbar", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        about.show(symbol: "info.circle")
        menu.addItem(about)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Inkbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.show(symbol: "power")
        menu.addItem(quit)
    }

    @objc func togglePause() {
        settings?.paused.toggle()
    }

    @objc func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc func showAbout() {
        AboutWindowController.shared.show()
    }

    /// Help is the About pane: what the bar does and which keys it answers to.
    @objc func showHelp() {
        SettingsWindowController.shared.show(pane: .about)
    }

    @objc private func openAccessibility() {
        Permissions.shared.openAccessibilitySettings()
    }
}

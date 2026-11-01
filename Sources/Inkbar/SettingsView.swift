import Darwin
import AppKit
import EventKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, actions, apps, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .actions: return "Actions"
        case .apps: return "Apps"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .actions: return "square.grid.2x2"
        case .apps: return "macwindow"
        case .permissions: return "hand.raised"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private(set) var window: NSWindow?
    private let selection = PaneSelection()

    /// A closed window is let go entirely, so its SwiftUI tree holds no memory while the app runs.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        closing.delegate = nil
        window = nil
        // After the close finishes, so AppKit is done with the views.
        Task { @MainActor in
            closing.contentViewController = nil
            // SwiftUI finishes tearing the tree down over the next moments.
            try? await Task.sleep(for: .seconds(3))
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    func show(pane: SettingsPane? = nil) {
        if let pane { selection.pane = pane }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(selection: selection))
            hosting.sizingOptions = []
            let w = NSWindow(contentViewController: hosting)
            // Like System Settings: the window is titled with the pane that is open.
            w.title = (selection.pane ?? .general).title
            selection.onChange = { [weak w] pane in w?.title = pane.title }
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.titlebarSeparatorStyle = .none
            let toolbar = NSToolbar(identifier: "InkbarSettings")
            toolbar.displayMode = .iconOnly
            w.toolbar = toolbar
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentMinSize = NSSize(width: 680, height: 500)
            w.setContentSize(NSSize(width: 720, height: 540))
            w.setFrameAutosaveName("InkbarSettings")
            if w.frame.origin == .zero { w.center() }
            window = w
        }
        window?.title = (selection.pane ?? .general).title
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor @Observable
final class PaneSelection {
    var pane: SettingsPane? = .general {
        didSet { if let pane { onChange?(pane) } }
    }
    @ObservationIgnored var onChange: ((SettingsPane) -> Void)?
}

/// The window: a flat sidebar of panes, a hairline, and the pane beside it under its title. The same
/// layout in every one of these apps, with the ground, text and accent from the palette.
struct SettingsView: View {
    @Bindable var selection: PaneSelection

    private var pane: SettingsPane { selection.pane ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: selection)
                .frame(width: 200)
            Rectangle().fill(Theme.divider).frame(width: 1)
            Group {
                switch pane {
                case .general: GeneralPane()
                case .actions: ActionsPane()
                case .apps: AppsPane()
                case .permissions: PermissionsPane()
                case .about: AboutPane()
                }
            }
            .font(Typeface.font(13))
            .scrollEdgeEffectStyle(.soft, for: .top)
            // The pane's title in the unified toolbar's row. Content scrolling under it fades out.
            .safeAreaBar(edge: .top, spacing: 0) {
                Text(pane.title)
                    .font(Typeface.font(22, .light))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 30)
                    .frame(height: 56)
                    .accessibilityAddTraits(.isHeader)
            }
            .frame(minWidth: 460, minHeight: 500)
        }
        .background(Theme.ground)
        .tint(Theme.accent)
        .ignoresSafeArea()
    }
}

private struct SettingsSidebar: View {
    @Bindable var selection: PaneSelection
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases) { pane in
                SidebarRow(pane: pane, selected: selection.pane == pane) { selection.pane = pane }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        // Below the traffic lights.
        .padding(.top, 52)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let all = SettingsPane.allCases
        guard let current = selection.pane, let index = all.firstIndex(of: current) else { return .ignored }
        selection.pane = all[min(max(index + step, 0), all.count - 1)]
        return .handled
    }
}

private struct SidebarRow: View {
    let pane: SettingsPane
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 20)
                Text(pane.title).font(Typeface.font(13, .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Theme.text : Theme.secondary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.34) : (hovering ? Theme.surface : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(pane.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Look

extension View {
    /// A pane's grouped form on the paper or ink ground, its groups a faint fill instead of the
    /// system's grey, in the palette and Plex.
    fileprivate func settingsForm() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Theme.ground)
            .listRowBackground(Theme.surface)
    }

    /// A section footer: small, quiet.
    fileprivate func footnote() -> some View {
        font(Typeface.font(11)).foregroundStyle(Theme.secondary)
    }

    /// A section header: a word above its group, regular weight.
    fileprivate func sectionHeader() -> some View {
        font(Typeface.font(12)).foregroundStyle(Theme.secondary)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable private var settings = AppSettings.shared
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var loginNote: String?
    @State private var languages: [(code: String, name: String)] = []

    var body: some View {
        Form {
            Section {
                Picker("Show the bar", selection: $settings.trigger) {
                    ForEach(TriggerMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Key to hold", selection: $settings.triggerKey) {
                    ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text(settings.trigger == .automatic
                     ? "The bar appears after you select text. In apps set to “Only with key held”, hold \(settings.triggerKey.title) as you finish the selection."
                     : "Hold \(settings.triggerKey.title) as you finish a selection to show the bar.")
                .footnote()
            }
            Section {
                Toggle("Read ahead with Apple Intelligence", isOn: $settings.readAhead)
            } footer: {
                Text("Reads each selection on this Mac and gets the next step ready: a calendar entry, a contact, reminders, three replies, what an error means, or the point of a long passage. Nothing leaves this Mac.")
                .footnote()
            }
            Section {
                Toggle("Number keys 1–9 run actions", isOn: $settings.numberKeys)
                Toggle("Haptic feedback on the trackpad", isOn: $settings.haptics)
                Toggle("Read selections in apps without text access", isOn: $settings.copyFallback)
            } footer: {
                Text("Some apps hide their text from Accessibility. Inkbar then copies the selection for a moment and puts your clipboard back exactly as it was. Never in password fields.")
                .footnote()
            }
            Section {
                Picker("Search with", selection: $settings.engine) {
                    ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                }
                Picker("Translate into", selection: $settings.translateTarget) {
                    Text("System language (\(Translator.languageName(Locale.preferredLanguages.first ?? "en")))").tag("")
                    if !languages.isEmpty { Divider() }
                    ForEach(languages, id: \.code) { Text($0.name).tag($0.code) }
                    if !settings.translateTarget.isEmpty, !languages.contains(where: { $0.code == settings.translateTarget }) {
                        Text(Translator.name(settings.translateTarget)).tag(settings.translateTarget)
                    }
                }
            } header: {
                Text("Search and Translate").sectionHeader()
            }
            Section {
                Toggle("Launch at login", isOn: .snapshot(loginEnabled, set: setLogin))
                if let loginNote {
                    LabeledContent {
                        if LoginItem.needsApproval { Button("Open Login Items") { LoginItem.openSettings() } }
                    } label: {
                        Text(loginNote).foregroundStyle(Theme.secondary)
                    }
                }
                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
                Toggle("Pause Inkbar", isOn: $settings.paused)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Without the menu bar icon, open Inkbar again from Finder or Spotlight to come back to these settings.")
                    if settings.focusPaused {
                        Text("A Focus filter is pausing Inkbar right now. Change it in System Settings > Focus.")
                    } else {
                        Text("To pause Inkbar during a Focus, add the Inkbar filter in System Settings > Focus. Inkbar also offers a control for Control Center and Shortcuts actions.")
                    }
                }
                .footnote()
            }
        }
        .settingsForm()
        .onAppear(perform: refresh)
        .task { languages = await Translator.supportedTargets() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        loginEnabled = LoginItem.isEnabled
        loginNote = LoginItem.needsApproval ? "Approve Inkbar in System Settings > General > Login Items." : nil
    }

    private func setLogin(_ on: Bool) {
        if let error = LoginItem.set(on) {
            loginNote = "Could not change the login item: \(error)"
        } else {
            loginNote = LoginItem.needsApproval ? "Approve Inkbar in System Settings > General > Login Items." : nil
        }
        loginEnabled = LoginItem.isEnabled
    }
}

// MARK: - Actions

private struct ActionsPane: View {
    @Bindable private var settings = AppSettings.shared
    /// The grouped forms of the other panes round their groups to this radius.
    private static let groupRadius: CGFloat = 12

    var body: some View {
        // The one list that must drag to reorder: a real List, not a grouped Form (which cannot move
        // rows). It is drawn as a form group, on the same fill and radius, so the panes read alike.
        VStack(alignment: .leading, spacing: 8) {
            List {
                ForEach(settings.order) { kind in
                    row(kind)
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
                .onMove { from, to in settings.order.move(fromOffsets: from, toOffset: to) }
                HStack {
                    Spacer()
                    Button("Restore Defaults") { settings.resetActions() }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(RoundedRectangle(cornerRadius: Self.groupRadius, style: .continuous).fill(Theme.surface))
            .clipShape(RoundedRectangle(cornerRadius: Self.groupRadius, style: .continuous))
            Text("Drag to reorder. Each action shows only when it fits the selection.")
                .font(Typeface.font(12))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 14)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
    }

    private func row(_ kind: ActionKind) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(Theme.tertiary)
                .accessibilityHidden(true)
            ActionGlyph(kind: kind, size: 14)
                .frame(width: 28)
                .foregroundStyle(Theme.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                Text(kind.detail).font(Typeface.font(11)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 12)
            Toggle(kind.title, isOn: settings.enabledBinding(for: kind))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            Button("Move Up") { move(kind, by: -1) }
            Button("Move Down") { move(kind, by: 1) }
        }
    }

    private func move(_ kind: ActionKind, by delta: Int) {
        guard let i = settings.order.firstIndex(of: kind) else { return }
        let j = i + delta
        guard settings.order.indices.contains(j) else { return }
        settings.order.swapAt(i, j)
    }
}

// MARK: - Apps

private struct AppsPane: View {
    @Bindable private var settings = AppSettings.shared

    /// Names for default rules whose app bundle states none.
    private static let knownNames: [String: String] = [
        "com.1password.1password": "1Password", "com.bitwarden.desktop": "Bitwarden",
        "com.googlecode.iterm2": "iTerm2", "com.mitchellh.ghostty": "Ghostty",
        "dev.warp.Warp": "Warp Preview", "dev.warp.Warp-Stable": "Warp", "com.apple.Terminal": "Terminal",
        "com.apple.keychainaccess": "Keychain Access", "com.apple.Passwords": "Passwords",
    ]

    /// Rules for apps that are installed. A rule for an app that is not here stays saved and applies
    /// the day the app is installed, but a list of apps nobody has is only clutter.
    private var rows: [(id: String, name: String, icon: NSImage?)] {
        settings.rules.keys.compactMap { id -> (id: String, name: String, icon: NSImage?)? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            let bundle = Bundle(url: url)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? Self.knownNames[id] ?? id
            return (id, name, NSWorkspace.shared.icon(forFile: url.path))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// How many saved rules belong to apps that are not installed, said once in the footer.
    private var hiddenNote: String {
        let hidden = settings.rules.count - rows.count
        return hidden > 0 ? " Rules for apps you have not installed are kept and apply once you do." : ""
    }

    var body: some View {
        Form {
            Section {
                if rows.isEmpty {
                    Text("No app rules. Inkbar works the same everywhere.")
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(rows, id: \.id) { row in
                    HStack(spacing: 10) {
                        if let icon = row.icon {
                            Image(nsImage: icon).resizable().frame(width: 22, height: 22).accessibilityHidden(true)
                        }
                        Text(row.name)
                        Spacer()
                        Picker(row.name, selection: settings.ruleBinding(for: row.id)) {
                            ForEach(AppRule.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            settings.rules[row.id] = nil
                        } label: {
                            Image(systemName: "minus.circle").foregroundStyle(Theme.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove rule")
                        .accessibilityLabel("Remove rule for \(row.name)")
                    }
                }
                HStack {
                    Spacer()
                    Button("Add App…", action: addApp)
                }
            } header: {
                Text("App rules").sectionHeader()
            } footer: {
                Text("“Never” turns Inkbar off in that app. “Only with key held” shows the bar only while you hold \(settings.triggerKey.title). Password fields are always skipped.\(hiddenNote)")
                    .footnote()
            }
        }
        .settingsForm()
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, settings.rules[id] == nil {
                settings.rules[id] = .never
            }
        }
    }
}

// MARK: - Permissions

private struct PermissionsPane: View {
    private var permissions = Permissions.shared


    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if permissions.trusted {
                        Label {
                            Text("Allowed")
                        } icon: {
                            Image(systemName: "checkmark").foregroundStyle(Theme.text)
                        }
                    } else {
                        if permissions.needsSettingsFallback {
                            Button("Open System Settings") { permissions.openAccessibilitySettings() }
                                .buttonStyle(.glassProminent)
                        } else {
                            Button("Allow…") { permissions.requestAccessibility() }
                                .buttonStyle(.glassProminent)
                        }
                    }
                } label: {
                    Text("Accessibility")
                    Text("Lets Inkbar see when you select text, where it is, and type a replacement when you ask.")
                }
            } footer: {
                if !permissions.trusted {
                    Text(permissions.needsSettingsFallback
                         ? "macOS asked and the answer was no. Turn on Inkbar in System Settings > Privacy & Security > Accessibility. The bar starts working right away, no restart needed."
                         : "Allow… shows the macOS prompt and adds Inkbar to the list. The bar starts working right away, no restart needed.")
                    .footnote()
                }
            }
            Section {
                LabeledContent {
                    if Intelligence.isAvailable {
                        Label {
                            Text("Ready")
                        } icon: {
                            Image(systemName: "checkmark").foregroundStyle(Theme.text)
                        }
                    } else if Intelligence.status == .notEnabled {
                        Button("Open Settings…") { BarController.openIntelligenceSettings() }
                    } else {
                        Text("Unavailable").foregroundStyle(Theme.secondary)
                    }
                } label: {
                    Text("Apple Intelligence")
                    Text(Intelligence.isAvailable
                         ? "Summarize, Explain, Rewrite, Proofread and Reply run on this Mac's own model."
                         : Intelligence.statusMessage)
                }
                LabeledContent {
                    switch EKEventStore.authorizationStatus(for: .reminder) {
                    case .fullAccess:
                        Label {
                            Text("Allowed")
                        } icon: {
                            Image(systemName: "checkmark").foregroundStyle(Theme.text)
                        }
                    case .notDetermined:
                        Text("Not asked yet").foregroundStyle(Theme.secondary)
                    default:
                        Button("Open System Settings") { Handoff.openRemindersSettings() }
                    }
                } label: {
                    Text("Reminders")
                    Text("macOS asks the first time you add tasks. Inkbar only adds to your default list and never reads it.")
                }
            }
            Section {
                Text("Inkbar never logs or stores what you select. Translation runs on this Mac. Inkbar writes its settings, and a file that lasts a minute when you add to Calendar or Contacts.")
                    .foregroundStyle(Theme.secondary)
            } header: {
                Text("Privacy").sectionHeader()
            }
            Section {
                LabeledContent {
                    Button("Show Again") {
                        AppSettings.shared.onboardingDone = false
                        permissions.resetRequested()
                        WelcomeWindowController.shared.show()
                    }
                } label: {
                    Text("Welcome window")
                    Text("Show the first-run window again.")
                }
            }
        }
        .settingsForm()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Inkbar").font(Typeface.font(22, .light))
                        Text("Version \(AppInfo.version)").foregroundStyle(Theme.secondary)
                        Text(AppInfo.tagline).foregroundStyle(Theme.secondary)
                        Text(AppInfo.copyright).font(Typeface.font(11)).foregroundStyle(Theme.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                Text("Select text in any app: drag, double-click, triple-click, Shift-click, or Shift with the arrow keys. The bar appears next to it and never takes focus from the app you are typing in.")
                    .foregroundStyle(Theme.secondary)
                Text("Open Inkbar again from Finder or Spotlight to come back to these settings. The menu bar icon is optional: switch it in General.")
                    .foregroundStyle(Theme.secondary)
            } header: {
                Text("Using Inkbar").sectionHeader()
            }
            Section {
                LabeledContent("Run an action", value: "1 – 9")
                LabeledContent("Close", value: "Esc")
                LabeledContent("Dismiss", value: "Type, scroll or click elsewhere")
            } header: {
                Text("Shortcuts while the bar is open").sectionHeader()
            }
        }
        .settingsForm()
    }
}

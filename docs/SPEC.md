# Inkbar specification

Single source of truth. README.md and docs/PLATFORM.md describe what ships; this file states what must be true. If they disagree, fix them to match this file.

## Product

A Liquid Glass action bar that appears when text is selected in any Mac app. Free, on-device, never takes focus from the app being typed in, never logs or stores selected text.

## Platform and quality bar

- macOS 26 or later on Apple silicon, designed for the macOS 26 and 27 Liquid Glass language. Swift 6, bundle id `info.gabrimatic.inkbar`, built ad hoc signed by default (`INKBAR_SIGN_IDENTITY` names a keychain signing identity, `-` forces ad hoc).
- IBM Plex Sans (bundled, SIL Open Font License, full text in Resources/Fonts/OFL.txt) on every surface the app draws itself, the system font on native controls, SF Symbols for in-app line icons. The palette is ink #1b262c, ice #bbe1fa and accent #3282b8 with alpha blends of them (docs/DESIGN.md). Concentric corner radii (card, bar and buttons share one radius scale). Springs and fades are SwiftUI animations at the display's refresh rate, no frame cap.
- Light and dark both correct. Glass never stacks on glass.
- Reduce Motion: no spring, short fade. Reduce Transparency: solid surfaces. Increase Contrast: visible border. VoiceOver: label and hint on every control, plus an announcement listing the actions and their numbers when the bar appears.
- Low Power Mode or thermal state serious/critical: short fade only.
- Idle CPU near 0% (under 0.1%), nothing polls; the installed app stays under 15 MB physical footprint. No crashes.
- Secure by default: input is untrusted, every failure path fails closed, every link is encoded and https (or mailto/tel/dict), no logging of selected text, no network use by Inkbar itself.
- Uses the Mac fully where a public API helps; decisions on what is not adopted live in docs/PLATFORM.md.

## Trigger

- Appears after a selection by mouse (drag, double-click, triple-click, Shift-click) or by Shift plus arrow keys. A keyboard selection shows once the keys rest for 0.35 s.
- A mouse selection gets its bar even when the app publishes it late: an empty read is repeated (up to five reads over about 1.1 s) and an Accessibility selection notification shows the bar at once. The selection is read from the app under the pointer where the drag began (the frontmost app when that cannot be told or is Inkbar itself), so a window the click did not bring forward still gets its bar. An app that comes forward just after the release (the click activated it) is read as the app of that selection. An app that times out on Accessibility is retried like one that has not published yet. Password fields and apps that hide their text are read once and never polled.
- Does not appear for Command-A or app-driven selections (Find).
- Trigger mode: automatic, or only while Option, Command or Control is held.
- Per-app rules: "Only with key held" (default for Terminal, Warp, iTerm2, Ghostty) and "Never" (default for Keychain Access, Passwords, 1Password, Bitwarden).
- Paused (menu, Settings, Control Center control, Shortcuts) or paused by a Focus filter: never shows. Focus pause never changes the user's own Pause switch.
- No bar without the Accessibility grant; the menu bar icon is dimmed and the menu links to the pane. Granting it starts Inkbar at once, with no relaunch: the grant is noticed from the system's notification and whenever another app comes forward.

## Secure fields: fail closed

- Never shows for password fields or while secure input is on.
- The clipboard fallback (apps that hide text from Accessibility) runs only after a mouse selection, only when secure input is off, the selection's app is the frontmost app (Command-C goes there) and both the focused element and the element under the drag are readable, neither is a password field, one is positively text, and no list row, table, toolbar or control sits between the element under the drag and the page or text view. Never from buttons, window chrome, file lists or Finder. Restores every clipboard item and type. Switchable off in Settings.
- If anything cannot be read, no bar.

## Placement

Just above the selection, below it when there is no room above. Never under the menu bar, the Dock or the camera notch (`safeAreaInsets`), never off a screen. On the screen that holds the selection. Joins all Spaces and full-screen apps. Dismissed on Space change, display change, sleep and session switch.

## Actions (shown only when they fit)

| Action | Shown when |
| --- | --- |
| Open Link | one web link; opened over https, tracking parameters removed |
| New Email | one email address; opens a draft, sends nothing |
| Call | a phone number (5 to 15 digits) |
| Show in Maps | a street address, or the on-device model reads the selection as a place (then it takes the end of the row) |
| Calculate | a sum such as `12 * (3 + 4.5) / 2`, `2^10`, `200 * 15%`, with functions such as `sqrt` and `round`, `pi` and `e`; lone numbers, dates and IDs are refused |
| Copy | always |
| Search | up to 2,000 characters, not a link or email address; Google, DuckDuckGo, Kagi or Perplexity |
| Translate | up to 5,000 characters whose language is clear and not the target language (a word or two the recognizer cannot place gets no Translate), not a link or email address; on-device Apple Translation; download prompt when a pair needs it; unsupported pairs say so |
| Apple Intelligence | text with letters, model available and language supported: Summarize (25 words or more), Explain, Rewrite (three or more words; three versions at once, number keys pick), Proofread (three or more words; marks the changed words, says so when nothing needs fixing), Reply (three or more words in text that cannot be edited; yes, no, a question); on-device, streamed; one fitting task runs at once, several open a list; a selection too long for a task says how much to select; the selection is treated as material, never as instructions; answers in the text's language when that is clear, else Explain and Reply use the Mac's language |
| Look Up | one to three words of letters, up to 40 characters, in Dictionary |
| Paste Clean | field editable and clipboard holds real text (not an empty or whitespace-only text type, not a file); pastes plain, tidy text with clean links |
| Clean Copy | cleaning would change the text; copies it cleaned |
| Change Case | text with cased letters: UPPERCASE, lowercase, Title Case (acronyms stay when the text also has lowercase) |
| Count | two or more words, or 20 characters: words, characters, lines |
| Letterboxd, IMDb | the on-device model reads the selection as a film or series, or it ends in a year in brackets |
| Shop, Amazon | the on-device model reads it as a product; Amazon opens the store of the Mac's region |
| Wikipedia | the on-device model reads it as a person or company |
| Goodreads | the on-device model reads it as a book |
| Apple Music | the on-device model reads it as music |
| Add to Calendar | read ahead finds an event and the system date detector finds its date; a card shows the draft, Add hands an .ics file to Calendar, which asks first |
| Add Contact | read ahead finds a contact and the detector finds an email or phone; a card shows the draft, Add hands a vCard to Contacts, which asks first |
| Add to Reminders | read ahead finds work to do; a card lists one task per action (at most eight), Add saves them to the default list through EventKit, with due dates from the date detector |
| Ready Replies | read ahead finds a message in text that cannot be edited; three replies are written before the card opens |

Default order: Open Link, New Email, Call, Show in Maps, Calculate, Copy, Search, Translate, Apple Intelligence, Look Up, Paste Clean, Clean Copy, Change Case, Count, then the actions read ahead adds, so a button that arrives late never moves one under the pointer.

Cleaning: removes `utm_*`, `fbclid`, `gclid`, `msclkid`, `si`, `igsh` and other tracking parameters; odd spaces become plain; zero-width characters dropped (keeping the joiners emoji and Persian need); runs of spaces collapse; line ends trimmed; at most one blank line; indentation kept.

## Read ahead

Runs after the bar shows and never holds it up, with Apple Intelligence available.

- First the on-device model reads what a short selection names (one line, up to six words and 60 characters), when a topic action is on. It only picks a topic from a fixed list: Inkbar owns every button and link.
- Then, when no topic was found and read ahead is on in Settings > General, one sort on the on-device model, held to what the text can really be, and one focused pass. The selection is up to 2,000 characters in a language the model supports; anything else stays silent. Everyday text gets nothing.
- Errors, long passages (20 words or more) and technical or foreign terms (four words or fewer) get a note beside the bar, on its own glass, so the row never moves; a click copies it.
- Topic actions keep their own switches in Settings > Actions.

## Cards

- Translate, Calculate, Count and Apple Intelligence results open a card with Copy. Translate, Calculate and Proofread add Replace when the field is editable. Rewrite, Reply and Change Case are lists of rows: a row replaces the selection when the field is editable and copies otherwise.
- Card titles name languages without their region ("German → English").
- Lists in cards (Apple Intelligence, Change Case) share one icon column, title column and number badges.
- When Apple Intelligence is off, its card says so with a button to the Apple Intelligence pane.
- A card that ends in a dead end (already in the target language, unsupported pair, download, failure, Apple Intelligence off) has a pill button forward.
- Action glyphs share one regular weight: outline SF Symbols only, and IMDb as its name in IBM Plex Sans regular, no box, as tall as the symbols' capitals.
- Cards open from the bar by moving and growing the panel on the content's own clock, also when the card needs the other side of the selection. A click on a card in the first double-click interval after it opened is ignored, so a double-click never runs a choice.
- The hover hint floats 8 pt clear of the bar's glass as drawn, glass rims included. It is flat: the ground and a hairline.
- A result taller than its card fades at the cut edge.
- Count copies exactly what it shows, with singular and plural labels.
- Replace and Paste Clean write through Accessibility; if the app refuses, paste and restore the clipboard exactly.

## Interaction

- `1` to `9` run actions in order (and choices inside a card, Change Case included, each marked with its number); `Esc` closes the bar and every card, also while a card is still streaming or the main thread was busy: the key tap is switched back on whenever the system turned it off, and a global key monitor closes the bar even then. Number keys switchable; with them on, a digit typed right after selecting runs the action, and a digit with no action behind it is swallowed, so it never replaces the selection.
- Dismisses on typing, scrolling (leftover momentum does not count), clicking elsewhere, switching apps.
- Hover shows the action name and number.
- A triple-click does not pop two bars: the double-click's bar stays while the third click lands, and the line's bar replaces it in place (same panel, new actions, animated move). A triple-click that reads nothing takes it down. The bar points at the selected text, not at the highlight of the line break a triple-click adds, and a line break at the ends of a selection never makes Clean Copy appear.
- The keyboard event tap and scroll watcher run only while the bar is visible. The tap runs on its own thread and decides swallow or pass from a snapshot of the bar (visible, card open, number keys, action count, card choice count) that the main thread keeps current, so a busy main thread never lets a digit that maps to an action through to the document; the action then runs on the main thread. A tap the system switches off is switched on again at once. If the tap is refused or cannot be kept on, typing still dismisses and number keys and their hints turn off.
- One entrance on appear (a short spring, or a short fade), no sweep or ambient motion. Force Touch haptics: alignment tap on appear, generic tap on action; switchable.

## Settings

- **General:** show the bar and key to hold, read ahead, number keys, haptics, clipboard fallback, search engine, translation target, launch at login, show menu bar icon, pause.
- **Actions:** one list: reorder by dragging, on/off, Restore Defaults.
- **Apps:** rules for installed apps, Add App… (starts as "Never"), remove a rule. Rules for apps that are not installed stay saved but are hidden.
- **Permissions:** Accessibility ("Allow…", "Allowed", fallback "Open System Settings"), Apple Intelligence readiness, Reminders, a privacy note, and a "Welcome window" row with the button "Show Again".
- **About:** version, copyright, a "Using Inkbar" section, the keys while the bar is open.

The window is titled with the open pane. Stored in UserDefaults only.

## System integration

- App Intents: Show Inkbar for Selection, Toggle Inkbar, Pause or Resume Inkbar, Clean Text, Calculate, Translate Text on Device, Write with Apple Intelligence; App Shortcuts with Siri phrases ("Show Inkbar", "Toggle Inkbar") and Spotlight entries.
- Focus filter (SetFocusFilterIntent) pauses Inkbar during a chosen Focus.
- Control Center and menu bar control, on macOS 27; its action runs only inside the app (`allowedExecutionTargets = .main`), no inter-process pause channel.
- Login item via SMAppService, registered on first launch. To turn it off: the switch in Settings > General, or System Settings > General > Login Items. The app binary takes no command-line flags.
- Logs under subsystem `info.gabrimatic.inkbar`, never containing selected text. Info level states why a selection did or did not show a bar.

## Known limits

Apps that neither expose text nor answer Command-C get no bar; translation covers the languages Apple Translation supports (the card says so for any other pair); plain http links open over https only.

## Menu bar

Inkbar is a menu bar app with no Dock icon, in any state. The menu's first line is the app name with its state (On, Paused, Paused by Focus, Needs Accessibility), with "Allow Accessibility…" under it, which opens the pane, while the grant is missing. Then Pause Inkbar, Settings… (Command-comma), About Inkbar and Quit Inkbar (Command-Q).

The icon is optional. Settings > General has "Show menu bar icon", on by default; turning it off removes the icon at once, with no relaunch. People also turn it off in System Settings > Menu Bar > Allow in the Menu Bar, or to keep room next to the notch. The app works fully without it: every function stays reachable through Settings.

## A complete macOS app

Inkbar must feel like a polished Mac app. Every item below is required:

1. **First-run welcome:** a welcome window on first launch, on the flat ground of the design language (glass only on what you click). It says in one line what the app does, then shows the one permission the first run needs (Accessibility), with:
   - an "Allow…" button that triggers the real macOS prompt (`AXIsProcessTrustedWithOptions` with prompt), so macOS itself adds the app to the list and asks. Nobody has to press "+" in System Settings.
   - a live state that turns to "Allowed" the moment access is granted, with no relaunch.
   - after the prompt was answered, "Open System Settings" in the button's place, to the exact pane.

   Then a "Launch at login" switch (the same label as in Settings, showing the real state) and a Done button. Done, Esc and the close button end it the same way, and it never returns on its own: only Show Again in Settings > Permissions or reset preferences bring it back. Never pre-set the welcome flag to skip it.
2. **Ask at first need too:** if a feature needs a permission that isn't granted, ask with the system prompt at that moment, then show a clear state with one way forward. Reminders asks the first time you press Add. Never fail silently.
3. **Info.plist completeness:** `NSRemindersFullAccessUsageDescription` in plain, friendly language, `CFBundleDisplayName`, a version and build, `NSHumanReadableCopyright` "© 2026 Soroush Yousefpour", `LSApplicationCategoryType`, `LSUIElement` and the app icon.
4. **Reopen behavior:** a second launch, or opening the app from Finder or Spotlight while it runs, shows the welcome window until it is finished and Settings after that. A launch that finds the welcome window finished and the grant gone opens Settings > Permissions.
5. **Standard menus while a window is in front:** the app menu with About Inkbar (a custom panel on the flat ground with only a close button, with icon, version, one-line description and copyright; About and Welcome open centered on the screen), Settings… Command-comma, Pause Inkbar and Quit Command-Q; an Edit menu so copy, paste and undo work in every text field; a Window menu; a Help menu whose "Inkbar Help" opens Settings > About, which has a "Using Inkbar" section. There is no bundled README and no Help window. Command-W closes windows, and Esc closes the Welcome and About windows, sheets and popovers. The About tagline sits on two lines: "Actions for any text you select," and "on this Mac.".
6. **Settings window:** one flat sidebar of panes with the pane beside it under its title, the same layout in all these apps, with remembered size and position, every pane a grouped form (the Actions pane is a list drawn as one so rows can drag), buttons in trailing rows, and a Permissions pane showing each permission's live state.
7. **Single instance:** a second launch hands over to the first one and quits. Clean quit: SIGTERM is a normal quit, and Inkbar changes nothing outside itself, so nothing needs reverting.
8. **Polish everywhere:** light and dark mode, Reduce Motion, Reduce Transparency and Increase Contrast respected, VoiceOver labels, keyboard navigation in every window, and no layout jumps. Copy is short, human and consistent.

## Build and release

- Build: `./build.sh` and `./build.sh --install`. Requirements: Xcode 27 or later (Swift 6).
- Release files: `Inkbar-<version>.zip`, `Inkbar-<version>.dmg` and `SHA256SUMS.txt`, built on a Mac with `scripts/package.sh`.
- `install.sh` options: `--no-open`, `INKBAR_VERSION`, `INKBAR_INSTALL_DIR`, `INKBAR_BASE_URL`. It falls back to `~/Applications` when `/Applications` is not writable.

## Design language

docs/DESIGN.md is binding for every surface, icon and word in this app.

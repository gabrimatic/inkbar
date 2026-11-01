# Platform audit

What macOS 26 and 27 and Mac hardware offer, and what Inkbar does with each. **Adopted** means it ships. **Not adopted** gives the reason, so the decision is on record.

## Adopted

| Capability | How Inkbar uses it |
| --- | --- |
| **Accessibility (AXUIElement, AXObserver)** | Reads the selection, its bounds (`AXBoundsForRange`, and text markers for web content), editability and password fields. Replaces text with `AXSelectedText`. Every call has a 0.25 s timeout. |
| **Foundation Models (Apple Intelligence)** | The Apple Intelligence action offers Summarize, Explain, Rewrite, Proofread and Reply, on the on-device model, and read ahead sorts each selection and runs one focused pass for what it found: a meeting, a contact, tasks, a message, a problem, a passage or a term. Answers stream into the glass card or the note beside the bar. Summarize, Rewrite and Proofread use the content-transformation guardrails, so ordinary text is not refused. The prompt treats the selection as data and names its language. Inkbar checks that the model is available and supports the language before showing the action. |
| **Translation** | Translates on device with `TranslationSession`, with the download prompt through `translationTask`. |
| **Natural Language** | Detects the language for Translate and Apple Intelligence. Persian and Urdu are told apart from Arabic by their letters. |
| **App Intents: Shortcuts, Spotlight, Siri** | Intents: Show Inkbar for Selection, Toggle Inkbar, Pause or Resume Inkbar, Clean Text, Calculate, Translate Text on Device, and Write with Apple Intelligence (with a Writing Action enum). App Shortcuts give them Siri phrases and Spotlight entries. The metadata is generated at build time from the compiler's constant values, as Xcode does. |
| **Focus filters (SetFocusFilterIntent)** | The Inkbar filter pauses Inkbar while a chosen Focus is on, and resumes it when the Focus ends. It never touches the user's own Pause switch. |
| **WidgetKit controls (ControlWidget)** | A Control Center and menu bar control pauses or resumes Inkbar, on macOS 27. Its action, `ToggleInkbarIntent`, is compiled into both the app and the sandboxed extension, with `allowedExecutionTargets = .main` (macOS 27), so it runs only inside the Inkbar app. There is no inter-process channel that another app could use to pause or resume Inkbar. |
| **SwiftUI Liquid Glass** | `glassEffect` inside `GlassEffectContainer` for the bar, cards and read-ahead note. Card buttons draw no glass of their own, so glass never stacks on glass, and the hover hint stays flat. |
| **ProMotion** | Springs and fades are SwiftUI animations. They run at the display's own refresh rate, with no frame cap. |
| **Force Touch haptics** | A light alignment tap when the bar appears and a generic tap when an action runs, through `NSHapticFeedbackManager`. Switchable in Settings. |
| **Trackpad gesture phases** | Scroll events that carry only momentum (a fling that started before the bar appeared) do not dismiss the bar. A new scroll or a mouse wheel does. |
| **Low Power Mode and thermal state** | Under Low Power Mode, or when the thermal state is serious or critical, there is no spring, only a short fade. |
| **Accessibility display options** | Reduce Motion: no spring. Reduce Transparency: solid surfaces. Increase Contrast: a visible border. VoiceOver: labels and hints on every control, and an announcement listing the actions and their numbers when the bar appears. |
| **Multiple displays, Spaces, full screen, notch** | The bar is placed on the screen that holds the selection, never under the menu bar, the Dock or the camera housing (`safeAreaInsets`). The panel joins every Space and full-screen apps. It is dismissed on a Space change, a display change, sleep and session switches. |
| **Keyboard event tap (CGEventTap)** | Runs only while the bar is visible, for 1 to 9 and Esc. If the system refuses the tap, typing still dismisses the bar and number keys turn off. |
| **Text Input Sources (Carbon)** | Finds the key that types C or V in the current layout, so synthetic Command-C and Command-V work on Dvorak and AZERTY. |
| **Data detectors** | Links, emails, phone numbers, addresses and dates. |
| **EventKit** | Add to Reminders saves tasks to the default list, with due dates. macOS asks the first time you press Add. |
| **Calendar and Contacts handoff** | Add to Calendar and Add Contact hand an .ics file or a vCard to the Apple app, which shows it before adding. No Calendar or Contacts permission is needed. |
| **ServiceManagement** | The login item, registered on first launch. |
| **os.Logger** | Logs never contain selected text. |

## Not adopted, and why

| Capability | Reason |
| --- | --- |
| **Vision (text recognition)** | Inkbar works on text that is already selected. Reading text from pixels would need the Screen Recording permission, a second and far broader grant. |
| **Writing Tools** | The system Writing Tools panel works on editable text views inside the app that shows it. There is no public API to run it on another app's selection. The Apple Intelligence card covers the same tasks on the selection. Inkbar's card text is read-only, so there is nothing for Writing Tools to edit there. |
| **Private Cloud Compute** | Inkbar runs on device only, by design. Nothing selected leaves the Mac. |
| **Spotlight indexing (Core Spotlight)** | Inkbar keeps no record of selections. Indexing would contradict that. |
| **Image Playground and Genmoji** | Inkbar has no image output. |
| **Speech synthesis** | Reading the selection aloud already exists system-wide (Speak Selection). A Speak action would duplicate it. |
| **Services menu provider** | Left out. The App Intents cover the same actions in Shortcuts. |
| **Handoff, iCloud and CloudKit** | Nothing to hand off or sync. Settings stay on this Mac. |
| **Notifications** | Every result appears in place, next to the selection. |
| **Touch ID (LocalAuthentication), Secure Enclave** | Inkbar stores nothing that needs protecting. |
| **Core ML and Create ML** | The on-device foundation model and Natural Language cover the language work. |
| **Camera, microphone, Bluetooth, Wi-Fi** | No use for a text tool. |

## Measured

- Idle CPU with the selection monitor running: about 0.006% over 20 s.
- Memory of the installed app: 11 to 14 MB physical footprint.
- On-device model: answers stream in 0.3 to 1.6 s on Apple silicon.

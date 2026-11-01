# Security Policy

## Privacy by Design

- **All processing is local.** Translation uses Apple Translation, and the Apple Intelligence action and read ahead use the on-device model, both on your Mac.
- **No network requests from Inkbar.** It has no web client and no update checker. Links you open go to your browser or to the Apple app for them.
- **No selected text is logged or stored.** Inkbar writes its settings to disk (macOS user defaults), and a calendar or contact file that it hands to Calendar or Contacts and deletes after a minute. Logs under the subsystem `info.gabrimatic.inkbar` never contain selected text.
- **No telemetry, no analytics, no accounts.**

## Permissions

| Permission | Why | Scope |
|------------|-----|-------|
| **Accessibility** | Read the selected text and its position, write text back for Replace and Paste Clean, listen for mouse clicks | The keyboard tap and scroll watcher exist only while the bar is on screen |
| **Reminders** | Save tasks when you press Add on a task card | Asked once, the first time you do it |

No other permission is requested: no Screen Recording, Input Monitoring, Full Disk Access, camera, microphone, contacts or location. Calendar and Contacts each show their own confirmation before anything is added.

## Stored Data

| Data | Location |
|------|----------|
| Settings | `~/Library/Preferences/info.gabrimatic.inkbar.plist` |
| A calendar or contact file on its way to Calendar or Contacts | The temporary folder, deleted after a minute |

`defaults delete info.gabrimatic.inkbar` resets everything.

## Secure by Default

- Password fields and secure input are always skipped.
- The clipboard fallback for apps that hide their text runs only after a mouse selection, only when secure input is off, and only when the focused element and the element under the drag are readable and not password fields. It restores every clipboard item and type. You can switch it off.
- Links are built with proper encoding and opened only over https, or as `mailto:`, `tel:` and `dict:` handed to the Apple app for them.
- The Apple Intelligence prompt treats the selection as material, never as instructions.
- The Control Center control runs its action only inside the Inkbar app (`allowedExecutionTargets = .main`); no other process can pause or resume Inkbar.

## Trust Boundaries

| Boundary | Trust Level | Notes |
|----------|-------------|-------|
| Selected text | Untrusted input | Parsed by detectors and cleaners; never executed, never logged |
| Inkbar app | Trusted | Built from this repository |
| Apple Translation, Apple Intelligence | System frameworks | On-device |
| Release downloads | Ad hoc signed | Not notarized; checksums are in `SHA256SUMS.txt` on each release page, and `install.sh` verifies them |

## Verifying a Download

```bash
shasum -a 256 -c SHA256SUMS.txt --ignore-missing
codesign --verify --strict --verbose=2 /Applications/Inkbar.app
```

`install.sh` runs the same checks before it installs anything.

## Supported Versions

Only the latest release receives fixes.

## Vulnerability Reporting

Report vulnerabilities responsibly:

1. **Do not open a public issue.**
2. Use [GitHub's private vulnerability reporting](https://github.com/gabrimatic/inkbar/security/advisories/new) to submit.
3. Include:
   - Steps to reproduce
   - Demonstrated impact
   - Affected version and macOS version
   - Suggested fix (if any)

Expect acknowledgment within 48 hours.

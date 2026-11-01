import AppKit
import EventKit

/// Hands drafts to the apps that own them. Calendar and Contacts each show what they are about to
/// add, so nothing lands there without the user seeing it.
@MainActor
enum Handoff {
    private static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Inkbar", isDirectory: true) }

    /// What is still waiting for its minute goes when Inkbar quits.
    static func clear() { try? FileManager.default.removeItem(at: folder) }

    private static func open(_ content: String, named name: String, in bundleID: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(name)
            try content.write(to: file, atomically: true, encoding: .utf8)
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            // The app has read it by then, and selected text does not stay on disk.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { try? FileManager.default.removeItem(at: file) }
            return true
        } catch {
            return false
        }
    }

    /// RFC 5545 and vCard share these escapes, so a selection can never add a line of its own.
    nonisolated static func escaped(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\\": out += #"\\"#
            case ";": out += #"\;"#
            case ",": out += #"\,"#
            case "\n", "\r", "\r\n": out += #"\n"#
            default: out.append(character)
            }
        }
        return out
    }

    nonisolated static func calendarText(_ event: EventDraft, now: Date = Date()) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = event.allDay ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss"
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Inkbar//EN", "BEGIN:VEVENT",
                     "UID:\(UUID().uuidString)", "DTSTAMP:\(stamp.string(from: now))"]
        if event.allDay {
            lines.append("DTSTART;VALUE=DATE:\(local.string(from: event.start))")
        } else {
            lines.append("DTSTART:\(local.string(from: event.start))")
            lines.append("DTEND:\(local.string(from: event.end))")
        }
        lines.append("SUMMARY:\(escaped(event.title))")
        if !event.place.isEmpty { lines.append("LOCATION:\(escaped(event.place))") }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    nonisolated static func contactText(_ contact: ContactDraft) -> String {
        var lines = ["BEGIN:VCARD", "VERSION:3.0", "FN:\(escaped(contact.name))"]
        let parts = contact.name.split(separator: " ").map(String.init)
        let family = parts.count > 1 ? parts.last ?? "" : ""
        let given = parts.count > 1 ? parts.dropLast().joined(separator: " ") : contact.name
        lines.append("N:\(escaped(family));\(escaped(given));;;")
        if !contact.company.isEmpty { lines.append("ORG:\(escaped(contact.company))") }
        if !contact.role.isEmpty { lines.append("TITLE:\(escaped(contact.role))") }
        lines += contact.emails.map { "EMAIL;TYPE=INTERNET:\(escaped($0))" }
        lines += contact.phones.map { "TEL;TYPE=VOICE:\(escaped($0))" }
        lines.append("END:VCARD")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func addEvent(_ event: EventDraft) -> Bool {
        open(calendarText(event), named: "Event.ics", in: "com.apple.iCal")
    }

    static func addContact(_ contact: ContactDraft) -> Bool {
        open(contactText(contact), named: "\(UUID().uuidString.prefix(8)).vcf", in: "com.apple.AddressBook")
    }

    /// True unless macOS holds a no: before the first ask, adding still works and macOS asks then.
    static var remindersAllowed: Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        return status != .denied && status != .restricted
    }

    static func openRemindersSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") { NSWorkspace.shared.open(url) }
    }

    /// Adds to the default Reminders list. A deadline in a task becomes its due date.
    static func addReminders(_ tasks: [String]) async -> Bool {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToReminders()) == true,
              let list = store.defaultCalendarForNewReminders() else { return false }
        for task in tasks {
            let reminder = EKReminder(eventStore: store)
            reminder.title = task
            reminder.calendar = list
            if let when = SelectionReader.eventDate(in: task) {
                let units: Set<Calendar.Component> = when.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
                reminder.dueDateComponents = Calendar.current.dateComponents(units, from: when.date)
            }
            guard (try? store.save(reminder, commit: false)) != nil else { return false }
        }
        return (try? store.commit()) != nil
    }
}

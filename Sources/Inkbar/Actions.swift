import Foundation

/// Every action the bar can show. The raw value is the stored id, so never rename one.
enum ActionKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case openURL, email, call, maps, calculate
    case copy, search, translate, define
    case pasteClean, cleanCopy
    case letterboxd, imdb
    case changeCase, count
    case intelligence
    case shop, amazon, wikipedia, goodreads, appleMusic
    case addEvent, addContact, addTasks, replies

    var id: String { rawValue }

    static let defaultOrder: [ActionKind] = [
        .openURL, .email, .call, .maps, .calculate,
        .copy, .search, .translate, .intelligence, .define,
        .pasteClean, .cleanCopy, .changeCase, .count,
        // Last, so the ones Apple Intelligence adds a moment later never move a button under the pointer.
        .letterboxd, .imdb, .shop, .amazon, .wikipedia, .goodreads, .appleMusic,
        .addEvent, .addContact, .addTasks, .replies,
    ]

    /// The actions Apple Intelligence can add once it knows what the selection names.
    static let topicActions: Set<ActionKind> = [.maps, .letterboxd, .imdb, .shop, .amazon, .wikipedia, .goodreads, .appleMusic]

    var title: String {
        switch self {
        case .openURL: return "Open Link"
        case .email: return "New Email"
        case .call: return "Call"
        case .maps: return "Show in Maps"
        case .calculate: return "Calculate"
        case .copy: return "Copy"
        case .search: return "Search"
        case .translate: return "Translate"
        case .define: return "Look Up"
        case .pasteClean: return "Paste Clean"
        case .cleanCopy: return "Clean Copy"
        case .letterboxd: return "Letterboxd"
        case .imdb: return "IMDb"
        case .changeCase: return "Change Case"
        case .intelligence: return "Apple Intelligence"
        case .count: return "Count"
        case .shop: return "Shop"
        case .amazon: return "Amazon"
        case .wikipedia: return "Wikipedia"
        case .goodreads: return "Goodreads"
        case .appleMusic: return "Apple Music"
        case .addEvent: return "Add to Calendar"
        case .addContact: return "Add Contact"
        case .addTasks: return "Add to Reminders"
        case .replies: return "Ready Replies"
        }
    }

    var symbol: String {
        switch self {
        case .openURL: return "link"
        case .email: return "envelope"
        case .call: return "phone"
        case .maps: return "map"
        case .calculate: return "equal.circle"
        case .copy: return "doc.on.doc"
        case .search: return "magnifyingglass"
        case .translate: return "character.bubble"
        case .define: return "character.book.closed"
        case .pasteClean: return "list.clipboard"
        case .cleanCopy: return "text.badge.checkmark"
        case .letterboxd: return "movieclapper"
        case .imdb: return "star.square"
        case .changeCase: return "textformat"
        case .intelligence: return "pencil.and.scribble"
        case .count: return "number"
        case .shop: return "cart"
        case .amazon: return "shippingbox"
        case .wikipedia: return "building.columns"
        case .goodreads: return "books.vertical"
        case .appleMusic: return "music.note"
        case .addEvent: return "calendar.badge.plus"
        case .addContact: return "person.crop.circle.badge.plus"
        case .addTasks: return "checklist"
        case .replies: return "arrowshape.turn.up.left.2"
        }
    }

    /// IMDb has no fitting SF Symbol: it is drawn as its short name in Plex, so it never reads as a generic glyph.
    var wordmark: String? { self == .imdb ? "IMDb" : nil }

    /// One line for Settings and VoiceOver.
    var detail: String {
        switch self {
        case .openURL: return "Opens a selected web link, without tracking parameters."
        case .email: return "Starts a new email to a selected address. Nothing is sent."
        case .call: return "Calls a selected phone number with FaceTime or iPhone."
        case .maps: return "Shows a selected address in Apple Maps."
        case .calculate: return "Works out a selected sum, like 12 * (3 + 4)."
        case .copy: return "Copies the selection."
        case .search: return "Searches the web with your chosen engine."
        case .translate: return "Translates on this Mac with Apple Translation."
        case .define: return "Looks up a word in Dictionary."
        case .pasteClean: return "Pastes the clipboard as plain, tidy text with clean links."
        case .cleanCopy: return "Copies the selection as plain, tidy text with clean links."
        case .letterboxd: return "Searches Letterboxd when the selection names a film."
        case .imdb: return "Searches IMDb when the selection names a film or series."
        case .changeCase: return "Changes the selection to UPPERCASE, lowercase or Title Case."
        case .intelligence: return "Summarize, explain, three rewrites, proofread or reply, on this Mac."
        case .count: return "Counts words, characters and lines."
        case .shop: return "Compares prices when the selection names a product."
        case .amazon: return "Searches Amazon when the selection names a product."
        case .wikipedia: return "Opens Wikipedia when the selection names a person or company."
        case .goodreads: return "Searches Goodreads when the selection names a book."
        case .appleMusic: return "Searches Apple Music when the selection names a band, album or song."
        case .addEvent: return "Turns a meeting in the selection into a calendar entry."
        case .addContact: return "Turns someone's details in the selection into a contact."
        case .addTasks: return "Turns the work in the selection into reminders."
        case .replies: return "Writes three replies to a selected message, ready to copy."
        }
    }

    /// Whether this action fits the selection. `editable` means the focused field accepts
    /// text; `clipboardHasText` means there is something for Paste Clean to paste;
    /// `intelligence` means the on-device model is ready for the selection's language.
    func isRelevant(_ a: TextAnalysis, editable: Bool, clipboardHasText: Bool, targetLanguage: String,
                    intelligence: Bool = false, topic: SelectionTopic? = nil, reading: SelectionReading? = nil) -> Bool {
        guard !a.isBlank else { return false }
        let small = a.trimmed.utf16.count <= TextAnalysis.detailLimit
        switch self {
        case .openURL: return a.url != nil
        case .email: return a.email != nil
        case .call: return a.phone != nil
        case .maps: return a.address != nil || topic == .place
        case .calculate: return a.mathResult != nil
        case .copy: return true
        case .search: return small && a.url == nil && a.email == nil
        case .translate:
            guard a.hasLetters, a.url == nil, a.email == nil, a.trimmed.utf16.count <= TextAnalysis.translateLimit else { return false }
            // Not sure which language this is (a word or two): offering Translate would guess.
            guard let lang = a.language else { return false }
            return !Self.sameLanguage(lang, targetLanguage)
        case .define: return a.isDefinable
        case .pasteClean: return editable && clipboardHasText
        case .cleanCopy: return a.cleanDiffers
        case .letterboxd, .imdb: return topic == .film || a.isDatedTitle
        case .shop, .amazon: return topic == .product
        case .wikipedia: return topic == .person || topic == .company
        case .goodreads: return topic == .book
        case .appleMusic: return topic == .music
        case .addEvent: if case .event = reading { return true } else { return false }
        case .addContact: if case .contact = reading { return true } else { return false }
        case .addTasks: if case .tasks = reading { return true } else { return false }
        case .replies: return reading == .message
        case .changeCase: return a.hasCasedLetters
        case .intelligence: return intelligence && !WritingTask.relevant(for: a, editable: editable).isEmpty
        case .count: return a.wordCount >= 2 || a.characterCount >= 20
        }
    }

    /// Compares base languages, so en-US and en-GB count as the same and zh-Hans and
    /// zh-Hant do not.
    static func sameLanguage(_ a: String, _ b: String) -> Bool {
        func key(_ code: String) -> String {
            let parts = code.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
            guard let base = parts.first else { return code.lowercased() }
            if base == "zh" {
                if parts.contains("hant") || parts.contains("tw") || parts.contains("hk") { return "zh-hant" }
                return "zh-hans"
            }
            return String(base)
        }
        return key(a) == key(b)
    }
}

/// Picks the visible actions for one selection, in the user's order.
enum ActionPlanner {
    static func actions(order: [ActionKind], enabled: Set<ActionKind>, analysis: TextAnalysis,
                        editable: Bool, clipboardHasText: Bool, targetLanguage: String,
                        intelligence: Bool = false, topic: SelectionTopic? = nil,
                        reading: SelectionReading? = nil) -> [ActionKind] {
        let actions = order.filter {
            enabled.contains($0) && $0.isRelevant(analysis, editable: editable, clipboardHasText: clipboardHasText,
                                                  targetLanguage: targetLanguage, intelligence: intelligence, topic: topic, reading: reading)
        }
        // Maps added for a place arrives late too, so it takes the end of the row like the others.
        guard topic == .place, analysis.address == nil else { return actions }
        return actions.filter { $0 != .maps } + (actions.contains(.maps) ? [.maps] : [])
    }

    /// Completes a stored order with every action it lacks and drops unknown ones.
    static func normalized(_ stored: [String]) -> [ActionKind] {
        var seen = Set<ActionKind>()
        var result: [ActionKind] = []
        for id in stored {
            if let kind = ActionKind(rawValue: id), seen.insert(kind).inserted { result.append(kind) }
        }
        for kind in ActionKind.defaultOrder where !seen.contains(kind) { result.append(kind) }
        return result
    }
}

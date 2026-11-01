import Foundation
import NaturalLanguage

/// What a selection is, worked out once per selection. Pure: no UI, no system state.
struct TextAnalysis: Sendable {
    /// Above this size only the cheap checks run, so a 10k-character selection stays instant.
    static let detailLimit = 2_000
    static let translateLimit = 5_000

    let text: String
    let trimmed: String
    let isBlank: Bool
    let characterCount: Int
    let wordCount: Int
    let lineCount: Int
    /// An http(s) link that is the whole selection, ready to open.
    let url: URL?
    let email: String?
    let phone: String?
    let address: String?
    let mathResult: Double?
    /// A title with its year, like `Heat (1995)`: a film even without Apple Intelligence.
    let isDatedTitle: Bool
    let isDefinable: Bool
    let hasCasedLetters: Bool
    let hasLetters: Bool
    /// BCP 47 code of the dominant language when the recognizer is confident.
    let language: String?
    /// True when Clean Copy would change the text.
    let cleanDiffers: Bool

    init(_ text: String) {
        self.text = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.trimmed = trimmed
        isBlank = trimmed.isEmpty
        characterCount = text.count
        wordCount = Self.countWords(text)
        lineCount = trimmed.isEmpty ? 0 : trimmed.split(separator: "\n", omittingEmptySubsequences: false).count
        hasLetters = trimmed.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        hasCasedLetters = trimmed.contains { $0.isCased }

        let small = !trimmed.isEmpty && trimmed.utf16.count <= Self.detailLimit
        let single = small && !trimmed.contains("\n")
        let whole = single ? Self.wholeMatch(trimmed) : nil
        url = single ? Self.url(from: trimmed, match: whole) : nil
        email = single ? Self.email(from: trimmed, match: whole) : nil
        phone = single && url == nil && email == nil ? Self.phone(from: trimmed, match: whole) : nil
        address = small && url == nil && email == nil && phone == nil ? Self.address(from: trimmed) : nil
        let isPlainData = url != nil || email != nil || phone != nil || Self.isDate(trimmed, match: whole)
        mathResult = single && !isPlainData ? MathEvaluator.evaluate(trimmed) : nil
        isDatedTitle = single && !isPlainData && mathResult == nil && Self.datedTitle(trimmed)
        isDefinable = single && !isPlainData && mathResult == nil && Self.definable(trimmed)
        language = hasLetters && trimmed.utf16.count <= Self.translateLimit ? Self.dominantLanguage(trimmed) : nil
        // A line picked by triple-click carries its line break; that is not something to clean.
        let core = text.trimmingCharacters(in: .newlines)
        cleanDiffers = small ? TextCleaner.clean(core) != core : TextCleaner.normalizeWhitespace(core) != core
    }

    // MARK: Detectors

    static func countWords(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    private static let detector = try? NSDataDetector(types:
        NSTextCheckingResult.CheckingType.link.rawValue |
        NSTextCheckingResult.CheckingType.phoneNumber.rawValue |
        NSTextCheckingResult.CheckingType.date.rawValue)

    private static let addressDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue)

    /// The single data-detector match that covers the whole text, if any.
    static func wholeMatch(_ text: String) -> NSTextCheckingResult? {
        guard let detector else { return nil }
        let full = NSRange(location: 0, length: (text as NSString).length)
        return detector.matches(in: text, range: full).first { $0.range == full }
    }

    static func url(from text: String, match: NSTextCheckingResult?) -> URL? {
        guard !text.contains(" "), let found = match?.url,
              let scheme = found.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = found.host, host.contains(".") else { return nil }
        // A bare domain like example.com comes back as http; prefer https.
        if scheme == "http", !text.lowercased().hasPrefix("http://") {
            var components = URLComponents(url: found, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            return components?.url
        }
        return found
    }

    static func email(from text: String, match: NSTextCheckingResult?) -> String? {
        if let url = match?.url, url.scheme?.lowercased() == "mailto" {
            let address = String(url.absoluteString.dropFirst("mailto:".count))
            return address.removingPercentEncoding ?? address
        }
        // Simple shape check for addresses the detector misses.
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasSuffix("."),
              !text.contains(" "), text.count <= 254,
              !parts[1].hasPrefix(".") else { return nil }
        return text
    }

    static func phone(from text: String, match: NSTextCheckingResult?) -> String? {
        guard let number = match?.phoneNumber else { return nil }
        let digits = number.filter(\.isNumber)
        guard digits.count >= 5, digits.count <= 15 else { return nil }
        return number
    }

    static func isDate(_ text: String, match: NSTextCheckingResult?) -> Bool {
        match?.resultType == .date
    }

    static func address(from text: String) -> String? {
        guard let addressDetector, text.count >= 8, countWords(text) >= 2 else { return nil }
        let ns = text as NSString
        guard let match = addressDetector.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        // The address must be most of the selection, not one line inside a long paragraph.
        guard Double(match.range.length) >= Double(ns.length) * 0.7 else { return nil }
        return ns.substring(with: match.range)
    }

    /// One to eight words ending in a year in brackets.
    static func datedTitle(_ text: String) -> Bool {
        guard text.count <= 60, let first = text.first, first.isLetter || first.isNumber else { return false }
        guard (2...9).contains(text.split(separator: " ").count) else { return false }
        return text.range(of: #"\((19|20)\d{2}\)$"#, options: .regularExpression) != nil
    }

    /// One to three words of letters, the kind of thing a dictionary can define.
    static func definable(_ text: String) -> Bool {
        guard text.count <= 40 else { return false }
        let words = text.split(separator: " ")
        guard (1...3).contains(words.count) else { return false }
        return text.allSatisfy { $0.isLetter || $0 == " " || $0 == "-" || $0 == "'" || $0 == "’" || $0 == "\u{200C}" }
    }

    /// The confidence the recognizer must reach before its answer is believed. It is least reliable
    /// on a word or two ("Godfather" reads as Dutch), so short text needs far more certainty.
    static func languageConfidenceBar(for text: String) -> Double {
        let words = countWords(text)
        if words <= 1 { return 0.75 }
        if words < 3 || text.count < 20 { return 0.6 }
        return 0.5
    }

    /// The language of the text, or nil when the recognizer is not sure enough to say.
    static func dominantLanguage(_ text: String) -> String? {
        let sample = String(text.prefix(1_000))
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let (lang, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              lang != .undetermined, confidence >= languageConfidenceBar(for: sample) else { return nil }
        return refineArabicScript(lang.rawValue, text)
    }

    /// The system recognizer reports Persian as Arabic. Letters that exist only in
    /// Persian or Urdu settle it.
    static func refineArabicScript(_ code: String, _ text: String) -> String {
        guard code == "ar" || code == "ur" || code == "fa" else { return code }
        var persianOrUrdu = false, urduOnly = false, arabicOnly = false
        for scalar in text.unicodeScalars.prefix(2_000) {
            switch scalar.value {
            case 0x067E, 0x0686, 0x0698, 0x06AF, 0x06A9, 0x06CC: persianOrUrdu = true
            case 0x0679, 0x0688, 0x0691, 0x06BA, 0x06BE, 0x06C1, 0x06D2: urduOnly = true
            case 0x0629, 0x064A, 0x0643, 0x0649: arabicOnly = true
            default: break
            }
        }
        if urduOnly { return "ur" }
        if persianOrUrdu && !arabicOnly { return "fa" }
        return code == "fa" ? "fa" : (arabicOnly || !persianOrUrdu ? "ar" : code)
    }

    // MARK: Transforms

    enum Case: String, CaseIterable, Sendable {
        case upper, lower, title

        var title: String {
            switch self {
            case .upper: return "UPPERCASE"
            case .lower: return "lowercase"
            case .title: return "Title Case"
            }
        }

        var symbol: String {
            switch self {
            case .upper: return "characters.uppercase"
            case .lower: return "characters.lowercase"
            case .title: return "textformat.characters"
            }
        }
    }

    static func transform(_ text: String, to c: Case, locale: Locale = .current) -> String {
        switch c {
        case .upper: return text.uppercased(with: locale)
        case .lower: return text.lowercased(with: locale)
        case .title: return titleCase(text, locale: locale)
        }
    }

    /// Capitalises the first letter of each word and lowers the rest, keeping
    /// all-caps words (acronyms such as NASA) as they are.
    static func titleCase(_ text: String, locale: Locale = .current) -> String {
        // Acronyms survive only when the text has lowercase elsewhere; an all-caps
        // selection is shouting, not a row of acronyms.
        let keepAcronyms = text.contains { $0.isLowercase }
        var result = ""
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            let letters = word.filter(\.isLetter)
            if keepAcronyms, letters.count > 1, letters.allSatisfy(\.isUppercase) {
                result += word
            } else {
                result += word.prefix(1).uppercased(with: locale) + word.dropFirst().lowercased(with: locale)
            }
            word = ""
        }
        for ch in text {
            if ch.isWhitespace || ch == "-" || ch == "/" {
                flush()
                result.append(ch)
            } else {
                word.append(ch)
            }
        }
        flush()
        return result
    }
}

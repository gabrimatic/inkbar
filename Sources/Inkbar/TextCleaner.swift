import Foundation

/// Cleans text for Clean Copy and Paste Clean: plain text, tidy whitespace and
/// links without tracking parameters.
enum TextCleaner {
    /// Query keys removed from every link. Matched case-insensitively.
    static let trackingKeys: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "twclid", "ttclid", "li_fat_id",
        "igsh", "igshid", "si", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "yclid", "ref_src", "ref_url",
        "s_cid", "spm", "vero_id", "oly_anon_id", "oly_enc_id", "rb_clickid", "wickedid", "_ga", "_gl",
    ]

    /// Query key prefixes removed from every link.
    static let trackingPrefixes = ["utm_", "pk_", "mtm_", "hsa_", "ga_"]

    static func isTrackingKey(_ key: String) -> Bool {
        let k = key.lowercased()
        return trackingKeys.contains(k) || trackingPrefixes.contains { k.hasPrefix($0) }
    }

    /// Removes tracking parameters from one http(s) link. Anything else comes back unchanged.
    static func cleanURL(_ string: String) -> String {
        guard var components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let items = components.percentEncodedQueryItems, !items.isEmpty else { return string }
        let kept = items.filter { !isTrackingKey($0.name) }
        guard kept.count != items.count else { return string }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        // Some sites put tracking in the fragment as a query, e.g. #utm_source=x.
        if let fragment = components.percentEncodedFragment,
           fragment.contains("="), !fragment.contains("/"),
           fragment.split(separator: "&").allSatisfy({ isTrackingKey(String($0.split(separator: "=").first ?? "")) }) {
            components.percentEncodedFragment = nil
        }
        return components.string ?? string
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Cleans every http(s) link found inside free text.
    static func cleanLinks(in text: String) -> String {
        guard let detector = linkDetector, text.contains("://") else { return text }
        let ns = text as NSString
        var result = text
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: ns.length))
        // Replace back to front so earlier ranges stay valid.
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let original = String(result[range])
            let cleaned = cleanURL(original)
            if cleaned != original { result.replaceSubrange(range, with: cleaned) }
        }
        return result
    }

    /// Tidies whitespace: unifies line endings, turns odd spaces into plain ones, drops
    /// zero-width characters, collapses runs of spaces, trims each line's end and the
    /// whole text, and keeps at most one blank line in a row.
    static func normalizeWhitespace(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        s = s.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n\n")
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x200B, 0x2060, 0xFEFF, 0x00AD: continue // zero-width space, word joiner, BOM, soft hyphen
            case 0x00A0, 0x2000...0x200A, 0x202F, 0x205F, 0x3000: out.append(" ")
            default: out.append(scalar)
            }
        }
        // Zero-width joiner and non-joiner stay: emoji sequences and Persian text need them.
        // Leading indentation stays as it is so code and lists keep their shape.
        let lines = String(out).split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            var collapsed = String(indent)
            var lastWasSpace = false
            for ch in line.dropFirst(indent.count) {
                if ch == " " || ch == "\t" {
                    if !lastWasSpace { collapsed.append(" ") }
                    lastWasSpace = true
                } else {
                    collapsed.append(ch)
                    lastWasSpace = false
                }
            }
            while collapsed.hasSuffix(" ") { collapsed.removeLast() }
            return collapsed
        }
        var result: [String] = []
        var blank = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blank += 1
                if blank == 1 { result.append("") }
            } else {
                blank = 0
                result.append(line)
            }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The full clean: whitespace and links.
    static func clean(_ text: String) -> String {
        cleanLinks(in: normalizeWhitespace(text))
    }
}

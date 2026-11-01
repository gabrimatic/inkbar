import AppKit

enum SearchEngine: String, CaseIterable, Identifiable, Sendable {
    case google, duckDuckGo, kagi, perplexity

    var id: String { rawValue }

    var name: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .kagi: return "Kagi"
        case .perplexity: return "Perplexity"
        }
    }

    var base: String {
        switch self {
        case .google: return "https://www.google.com/search"
        case .duckDuckGo: return "https://duckduckgo.com/"
        case .kagi: return "https://kagi.com/search"
        case .perplexity: return "https://www.perplexity.ai/search"
        }
    }
}

/// Builds every link Inkbar opens. Query values go through URLComponents, and path
/// segments through a strict allowed set, so no selection can change a link's host
/// or path.
enum Links {
    /// Characters left as-is in a single path segment. Everything else, including
    /// `/`, `?`, `#` and `%`, is percent-encoded.
    static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// Collapses whitespace and caps the length so a long selection makes a sane query.
    static func query(_ text: String, limit: Int = 500) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(limit))
    }

    static func search(_ text: String, engine: SearchEngine) -> URL? {
        var c = URLComponents(string: engine.base)
        c?.queryItems = [URLQueryItem(name: "q", value: query(text))]
        return c.flatMap(encodedPlus)
    }

    static func letterboxd(_ text: String) -> URL? {
        let q = query(text, limit: 120)
        guard !q.isEmpty, let segment = q.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) else { return nil }
        return URL(string: "https://letterboxd.com/search/\(segment)/")
    }

    static func imdb(_ text: String) -> URL? {
        var c = URLComponents(string: "https://www.imdb.com/find/")
        c?.queryItems = [URLQueryItem(name: "q", value: query(text, limit: 120))]
        return c.flatMap(encodedPlus)
    }

    static func shop(_ text: String) -> URL? {
        var c = URLComponents(string: "https://www.google.com/search")
        c?.queryItems = [URLQueryItem(name: "udm", value: "28"), URLQueryItem(name: "q", value: query(text, limit: 120))]
        return c.flatMap(encodedPlus)
    }

    /// The Amazon store of the Mac's region, or amazon.com where there is none.
    static func amazon(_ text: String, region: String? = Locale.current.region?.identifier) -> URL? {
        let hosts = ["DE": "de", "AT": "de", "CH": "de", "GB": "co.uk", "IE": "ie", "FR": "fr", "IT": "it", "ES": "es", "NL": "nl",
                     "SE": "se", "PL": "pl", "BE": "com.be", "CA": "ca", "AU": "com.au", "JP": "co.jp", "IN": "in", "TR": "com.tr", "AE": "ae"]
        var c = URLComponents(string: "https://www.amazon.\(hosts[region ?? ""] ?? "com")/s")
        c?.queryItems = [URLQueryItem(name: "k", value: query(text, limit: 120))]
        return c.flatMap(encodedPlus)
    }

    static func wikipedia(_ text: String) -> URL? {
        var c = URLComponents(string: "https://en.wikipedia.org/w/index.php")
        c?.queryItems = [URLQueryItem(name: "search", value: query(text, limit: 120))]
        return c.flatMap(encodedPlus)
    }

    static func goodreads(_ text: String) -> URL? {
        var c = URLComponents(string: "https://www.goodreads.com/search")
        c?.queryItems = [URLQueryItem(name: "q", value: query(text, limit: 120))]
        return c.flatMap(encodedPlus)
    }

    static func appleMusic(_ text: String) -> URL? {
        var c = URLComponents(string: "https://music.apple.com/search")
        c?.queryItems = [URLQueryItem(name: "term", value: query(text, limit: 120))]
        return c.flatMap(encodedPlus)
    }

    static func maps(_ address: String) -> URL? {
        var c = URLComponents(string: "https://maps.apple.com/")
        c?.queryItems = [URLQueryItem(name: "q", value: query(address, limit: 300))]
        return c.flatMap(encodedPlus)
    }

    static func mail(_ address: String) -> URL? {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !a.contains(where: { $0.isWhitespace || $0 == "?" || $0 == "&" || $0 == "#" || $0 == "/" }),
              a.filter({ $0 == "@" }).count == 1,
              let encoded = a.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed.union(CharacterSet(charactersIn: "@+")))
        else { return nil }
        return URL(string: "mailto:\(encoded)")
    }

    static func call(_ number: String) -> URL? {
        // Keep a leading plus and digits only, so nothing else reaches the dialer.
        var cleaned = number.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" : ""
        cleaned += number.filter { $0.isASCII && $0.isNumber }
        guard cleaned.filter(\.isNumber).count >= 3 else { return nil }
        return URL(string: "tel:\(cleaned)")
    }

    static func define(_ word: String) -> URL? {
        let q = query(word, limit: 60)
        guard !q.isEmpty, let encoded = q.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) else { return nil }
        return URL(string: "dict://\(encoded)")
    }

    /// URLComponents leaves `+` raw in query values, which servers read as a space.
    private static func encodedPlus(_ c: URLComponents) -> URL? {
        var c = c
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url
    }

    // MARK: Opening

    /// Schemes other than https that Inkbar may hand to the system, each to one Apple app.
    static let systemSchemes: Set<String> = ["mailto", "tel", "dict"]

    /// The allowlist every open goes through: https with a real host and no user info,
    /// or one of the system schemes. Plain http is upgraded only by the caller, never here.
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" {
            guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
            return true
        }
        return systemSchemes.contains(scheme)
    }

    /// Opens a link through NSWorkspace when it passes the allowlist. Returns false otherwise.
    @MainActor @discardableResult
    static func open(_ url: URL?) -> Bool {
        guard let url, isAllowed(url) else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Plain http links from a selection are opened over https; the allowlist never opens http.
    static func upgraded(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http", var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.scheme = "https"
        return c.url ?? url
    }
}

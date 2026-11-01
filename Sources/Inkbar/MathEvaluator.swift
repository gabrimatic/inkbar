import Foundation

/// Evaluates a plain arithmetic expression such as `12 * (3 + 4.5) / 2`, `2^10`,
/// `sqrt(16) + 15%` or `3 × 4 − 1`. Returns nil for anything that is not math,
/// including a lone number, so ordinary text never shows a result.
enum MathEvaluator {
    static let maxLength = 200

    static func evaluate(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
        var source = trimmed
        if source.hasSuffix("=") { source.removeLast() }
        guard let tokens = tokenize(source), isComputation(tokens) else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.parseExpression(), parser.atEnd, value.isFinite else { return nil }
        return value
    }

    /// The result as text: integers without a decimal point, others to at most 10 significant decimals.
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 10
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if abs(value) >= 1e15 || abs(value) < 1e-9 {
            formatter.numberStyle = .scientific
            formatter.maximumFractionDigits = 8
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    enum Token: Equatable {
        case number(Double)
        case op(Character)
        case open, close, comma
        case word(String)

    }

    /// True when the tokens do real work: a function call, or a binary operator or percent
    /// after an operand. A lone number, a lone constant or `-5` is not a computation.
    /// Dates and IDs such as `2026-10-29`, `10/29/2026` or `030-1234567` are refused too.
    static func isComputation(_ tokens: [Token]) -> Bool {
        var hasFunction = false
        var binaryOps: Set<Character> = []
        var previousIsOperand = false
        for t in tokens {
            switch t {
            case .number, .close:
                previousIsOperand = true
            case .word(let w):
                if Parser.functions[w] != nil { hasFunction = true; previousIsOperand = false } else { previousIsOperand = true }
            case .op(let c):
                if previousIsOperand { binaryOps.insert(c) }
                previousIsOperand = c == "%"
            case .open, .comma:
                previousIsOperand = false
            }
        }
        if hasFunction { return true }
        // A trailing percent alone (50%) is a value, not a sum.
        binaryOps.remove("%")
        guard !binaryOps.isEmpty else { return false }
        let onlyDashOrSlash = binaryOps.isSubset(of: ["-", "/"])
        let numbers = tokens.compactMap { t -> Double? in if case .number(let v) = t { return v } else { return nil } }
        let allIntegers = numbers.allSatisfy { $0 == $0.rounded() }
        let hasParens = tokens.contains(.open)
        if onlyDashOrSlash && allIntegers && !hasParens && numbers.count >= 3 { return false }
        return true
    }

    static func tokenize(_ s: String) -> [Token]? {
        var tokens: [Token] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isASCII, c.isNumber || c == "." {
                var j = i
                var seenDot = false
                var seenExp = false
                while j < chars.count {
                    let d = chars[j]
                    if d.isASCII && d.isNumber { j += 1; continue }
                    if d == "." && !seenDot && !seenExp { seenDot = true; j += 1; continue }
                    if (d == "e" || d == "E") && !seenExp && j + 1 < chars.count,
                       chars[j + 1].isNumber || ((chars[j + 1] == "-" || chars[j + 1] == "+") && j + 2 < chars.count && chars[j + 2].isNumber) {
                        seenExp = true; j += 2; continue
                    }
                    break
                }
                guard let value = Double(String(chars[i..<j])) else { return nil }
                tokens.append(.number(value))
                i = j
                continue
            }
            if c.isLetter && c.isASCII {
                var j = i
                while j < chars.count, chars[j].isASCII, chars[j].isLetter { j += 1 }
                let word = String(chars[i..<j]).lowercased()
                guard Parser.functions[word] != nil || Parser.constants[word] != nil else { return nil }
                tokens.append(.word(word))
                i = j
                continue
            }
            switch c {
            case "+", "-", "*", "/", "^", "%": tokens.append(.op(c))
            case "−", "–": tokens.append(.op("-"))
            case "×", "·": tokens.append(.op("*"))
            case "÷": tokens.append(.op("/"))
            case "(": tokens.append(.open)
            case ")": tokens.append(.close)
            case ",": tokens.append(.comma)
            default: return nil
            }
            i += 1
        }
        return tokens
    }

    struct Parser {
        static let functions: [String: @Sendable (Double) -> Double] = [
            "sqrt": { $0.squareRoot() }, "abs": { Swift.abs($0) },
            "sin": { Foundation.sin($0) }, "cos": { Foundation.cos($0) }, "tan": { Foundation.tan($0) },
            "ln": { Foundation.log($0) }, "log": { Foundation.log10($0) },
            "round": { $0.rounded() }, "floor": { Foundation.floor($0) }, "ceil": { Foundation.ceil($0) },
        ]
        static let constants: [String: Double] = ["pi": .pi, "e": M_E]

        let tokens: [Token]
        var index = 0
        var depth = 0

        init(tokens: [Token]) { self.tokens = tokens }

        var atEnd: Bool { index == tokens.count }

        private func peek() -> Token? { index < tokens.count ? tokens[index] : nil }

        // expression := term (('+' | '-') term)*
        mutating func parseExpression() -> Double? {
            depth += 1
            defer { depth -= 1 }
            guard depth < 64, var value = parseTerm() else { return nil }
            while let t = peek(), case .op(let c) = t, c == "+" || c == "-" {
                index += 1
                guard let rhs = parseTerm() else { return nil }
                value = c == "+" ? value + rhs : value - rhs
            }
            return value
        }

        // term := power (('*' | '/' | implicit) power)*
        mutating func parseTerm() -> Double? {
            guard var value = parseUnary() else { return nil }
            while let t = peek() {
                if case .op(let c) = t, c == "*" || c == "/" {
                    index += 1
                    guard let rhs = parseUnary() else { return nil }
                    if c == "/" {
                        guard rhs != 0 else { return nil }
                        value /= rhs
                    } else {
                        value *= rhs
                    }
                } else if t == .open {
                    // Implicit multiplication: 2(3 + 4).
                    guard let rhs = parseUnary() else { return nil }
                    value *= rhs
                } else {
                    break
                }
            }
            return value
        }

        // unary := ('-' | '+') unary | power
        mutating func parseUnary() -> Double? {
            if let t = peek(), case .op(let c) = t, c == "-" || c == "+" {
                index += 1
                guard let v = parseUnary() else { return nil }
                return c == "-" ? -v : v
            }
            return parsePower()
        }

        // power := postfix ('^' unary)?   (right associative)
        mutating func parsePower() -> Double? {
            guard let base = parsePostfix() else { return nil }
            if let t = peek(), t == .op("^") {
                index += 1
                guard let exponent = parseUnary() else { return nil }
                return Foundation.pow(base, exponent)
            }
            return base
        }

        // postfix := primary '%'*
        mutating func parsePostfix() -> Double? {
            guard var value = parsePrimary() else { return nil }
            while let t = peek(), t == .op("%") {
                index += 1
                value /= 100
            }
            return value
        }

        mutating func parsePrimary() -> Double? {
            guard let t = peek() else { return nil }
            index += 1
            switch t {
            case .number(let v):
                return v
            case .open:
                guard let v = parseExpression(), peek() == .close else { return nil }
                index += 1
                return v
            case .word(let w):
                if let constant = Self.constants[w] { return constant }
                guard let f = Self.functions[w], peek() == .open else { return nil }
                index += 1
                guard let arg = parseExpression(), peek() == .close else { return nil }
                index += 1
                return f(arg)
            default:
                return nil
            }
        }
    }
}

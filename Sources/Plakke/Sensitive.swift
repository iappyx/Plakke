import Foundation

/// Credential shapes that deserve the same treatment as a password-manager copy, even when no app
/// flagged them: memory only, blurred, 60-second countdown, never written to disk.
///
/// Every pattern here is high-precision on purpose. A rule that merely *might* match a secret would
/// quietly delete ordinary clips after a minute, which is far worse than not catching one — so
/// there is deliberately no generic "long hex string" rule (that is a git SHA more often than a key)
/// and no `password=` substring rule.
enum Sensitive {
    /// How much of a clip is scanned at all. A credential inside a larger file — a `.env`, an
    /// `~/.aws/credentials`, a CI secrets block — is still a credential, so the prefixed patterns run
    /// over this whole window rather than only over clips small enough to *be* a bare token.
    private static let maxScanBytes = 64 * 1024
    /// A bare payment card is its own clip; 64 bytes is generous for 19 digits plus separators.
    private static let maxCardBytes = 64

    private static let tokenPatterns = [
        // JSON Web Token: three base64url segments. Word-bounded, not anchored — the common case is
        // `Authorization: Bearer eyJ…` inside a curl command or a log line.
        #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{8,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,                           // AWS access key ID
        #"\bASIA[0-9A-Z]{16}\b"#,                           // AWS temporary access key ID
        #"\bsk-[A-Za-z0-9]{20,}\b"#,                        // OpenAI-style secret key
        #"\bsk-ant-[A-Za-z0-9_-]{20,}\b"#,                  // Anthropic API key
        #"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#,                 // GitHub token
        #"\bgithub_pat_[A-Za-z0-9_]{30,}\b"#,               // GitHub fine-grained PAT
        #"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#,               // Slack token
        #"\bAIza[0-9A-Za-z_-]{30,}\b"#,                     // Google API key (39 chars in practice)
        #"\bglpat-[A-Za-z0-9_-]{20,}\b"#,                   // GitLab PAT
        #"\bnpm_[A-Za-z0-9]{36}\b"#,                        // npm token
        #"\bSG\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\b"#, // SendGrid
        #"\b(?:r|s)k_(?:live|test)_[A-Za-z0-9]{20,}\b"#,    // Stripe
    ]

    private static let privateKeyPattern = #"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----"#

    static func looksSensitive(_ text: String) -> Bool {
        let scan = text.truncatedToUTF8(maxScanBytes)
        guard !scan.isEmpty else { return false }

        if scan.contains("-----BEGIN"),
           scan.range(of: privateKeyPattern, options: .regularExpression) != nil {
            return true
        }
        for pattern in tokenPatterns where scan.range(of: pattern, options: .regularExpression) != nil {
            return true
        }

        let t = scan.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.utf8.count <= maxCardBytes else { return false }
        return isPaymentCard(t)
    }

    /// Digits only (plus spaces and dashes), a real issuer prefix, the length that issuer uses, and
    /// Luhn-valid.
    ///
    /// Luhn alone was nowhere near enough: every IMEI is Luhn-valid by construction, and roughly one
    /// in ten arbitrary 16-digit order or account numbers passes it — all of which were being deleted
    /// after 60 seconds as if they were card numbers. Requiring an issuer prefix *and* that issuer's
    /// length removes almost all of those.
    private static func isPaymentCard(_ s: String) -> Bool {
        guard s.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) else { return false }
        let digits = s.filter(\.isNumber)
        guard (12...19).contains(digits.count), matchesIssuer(digits) else { return false }

        var sum = 0
        var double = false
        for ch in digits.reversed() {
            guard var d = ch.wholeNumberValue else { return false }
            if double {
                d *= 2
                if d > 9 { d -= 9 }
            }
            sum += d
            double.toggle()
        }
        return sum % 10 == 0
    }

    /// Issuer identification number ranges, with the lengths each issuer actually uses.
    private static func matchesIssuer(_ digits: String) -> Bool {
        let n = digits.count
        func prefix(_ length: Int) -> Int? { Int(digits.prefix(length)) }
        guard let p1 = prefix(1), let p2 = prefix(2), let p3 = prefix(3), let p4 = prefix(4) else {
            return false
        }
        switch true {
        case p1 == 4:                                   return [13, 16, 19].contains(n)   // Visa
        case (51...55).contains(p2):                    return n == 16                    // Mastercard
        case (2221...2720).contains(p4):                return n == 16                    // Mastercard 2-series
        case p2 == 34 || p2 == 37:                      return n == 15                    // Amex
        case p4 == 6011 || p2 == 65:                    return (16...19).contains(n)      // Discover
        case (644...649).contains(p3):                  return (16...19).contains(n)      // Discover
        case (3528...3589).contains(p4):                return (16...19).contains(n)      // JCB
        case (300...305).contains(p3) || p2 == 36:      return (14...19).contains(n)       // Diners
        case p2 == 38 || p2 == 39:                      return (14...19).contains(n)       // Diners
        case p2 == 62:                                  return (16...19).contains(n)      // UnionPay
        default:                                        return false
        }
    }
}

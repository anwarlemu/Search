import Foundation

// What you type has to be a place. There is no search here, so this either
// hands back a URL or hands back nothing — and nothing is worth saying out
// loud, because the alternative is a browser that silently does something else
// with your keystrokes.
enum Address {
    /// Schemes the window can show itself. Anything else typed with a scheme —
    /// mailto:, a custom app link — is somebody else's job and gets refused
    /// here rather than opening a blank tab.
    private static let ours: Set<String> = ["http", "https", "file", "about", "data"]

    static func url(from typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // A path to a file on this Mac, spaces and all — dragged in from
        // Finder or typed.
        if text.hasPrefix("/") || text.hasPrefix("~/") {
            let path = (text as NSString).expandingTildeInPath
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        guard !text.isEmpty, !text.contains(" ") else { return nil }

        // Written with a scheme, it is taken at its word.
        if let split = text.range(of: "://") {
            let scheme = text[..<split.lowerBound].lowercased()
            guard ours.contains(scheme) else { return nil }
            return URL(string: text)
        }
        if text.lowercased().hasPrefix("about:") || text.lowercased().hasPrefix("data:") {
            return URL(string: text)
        }

        // Everything else has to look like a host before it gets a scheme put
        // in front of it. "hello world" is not a website, and neither is "todo".
        let head = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !head.contains("@") else { return nil }   // an email address
        let host = head.split(separator: ":").first.map(String.init) ?? String(head)
        guard looksLikeHost(host) else { return nil }

        // A local server almost never has a certificate, so https there is a
        // connection failure rather than a page.
        let local = host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "127.0.0.1"
            || host == "0.0.0.0"
            || host.hasPrefix("192.168.")
            || host.hasPrefix("10.")
        return URL(string: (local ? "http://" : "https://") + text)
    }

    private static func looksLikeHost(_ host: String) -> Bool {
        if host == "localhost" { return true }

        // Four numbers is an address on the local network as often as not.
        let numbers = host.split(separator: ".", omittingEmptySubsequences: false)
        if numbers.count == 4, numbers.allSatisfy({ UInt8($0) != nil }) { return true }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        guard labels.allSatisfy({ label in
            !label.isEmpty
                && !label.hasPrefix("-")
                && !label.hasSuffix("-")
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }) else { return false }

        // The last label carries the weight: a dotted thing ending in letters is
        // a domain, a dotted thing ending in digits is a version number.
        let tld = labels[labels.count - 1]
        return tld.count >= 2 && tld.allSatisfy { $0.isLetter }
    }

    /// Editing must round-trip every part of an address, including its scheme.
    static func editable(_ url: URL) -> String { url.absoluteString }

    /// Only the scheme and host are case-insensitive. Paths, queries, ports
    /// and fragments distinguish pages and must survive history/imports.
    static func identity(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if ["http", "https"].contains(parts.scheme ?? ""), parts.path.isEmpty { parts.path = "/" }
        return parts.string ?? url.absoluteString
    }

    static func home(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.host != nil else { return nil }
        parts.path = "/"
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.url
    }

    /// A compact label, never a storage key or an editable address.
    static func pretty(_ url: URL) -> String {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = parts.host
        else { return url.absoluteString }
        parts.scheme = nil
        parts.user = nil
        parts.password = nil
        if host.hasPrefix("www.") { parts.host = String(host.dropFirst(4)) }
        if parts.path == "/", parts.query == nil, parts.fragment == nil { parts.path = "" }
        let label = parts.string ?? url.absoluteString
        return label.hasPrefix("//") ? String(label.dropFirst(2)) : label
    }
}

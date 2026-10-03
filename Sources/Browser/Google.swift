import Foundation

// What to do with words that aren't a place: ask Google.
//
// The field still tells an address from a phrase — typing a domain goes
// straight there, without a round trip through anyone's results page. Only
// what can't be a place gets searched.

enum Google {
    static let name = "Google"

    /// A place if it can be one, a search if it can't.
    static func destination(for typed: String) -> URL? {
        Address.url(from: typed) ?? url(for: typed)
    }

    static func url(for text: String) -> URL? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        // Everything a query string can't carry raw, including the plus sign,
        // which would otherwise come out the far end as a space.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let escaped = words.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "https://www.google.com/search?q=" + escaped)
    }

    /// The words a results page was asked for, when the address is one.
    static func query(of url: URL) -> String? {
        guard let host = url.host()?.lowercased(), host == "google.com" || host.hasSuffix(".google.com") || host.hasPrefix("google."),
              url.path() == "/search",
              let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value,
              !q.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return q
    }
}

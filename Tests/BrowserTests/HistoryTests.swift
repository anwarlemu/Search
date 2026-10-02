import XCTest
import Combine
@testable import Browser

final class HistoryTests: XCTestCase {
    func testEditableAddressesRoundTrip() throws {
        for value in ["http://localhost:3000/dashboard?project=one#section", "https://example.com/Case?q=a%2Bb&next=%2F#result", "http://example.com:8080/a", "https://www.example.com/a%20b"] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertEqual(Address.url(from: Address.editable(url))?.absoluteString, url.absoluteString)
        }
        XCTAssertEqual(Address.pretty(URL(string: "http://localhost:3000/a?q=1#b")!), "localhost:3000/a?q=1#b")
    }

    @MainActor
    func testHistoryKeepsDistinctDestinationsAndDeletesOnlyOne() async throws {
        let history = History(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let urls = ["https://example.com/Case?q=1", "https://example.com/Case?q=2", "https://example.com/case?q=1",
                    "http://example.com/Case?q=1", "https://example.com:8443/Case?q=1", "https://example.com/Case?q=1#x"]
        for text in urls { history.record(URL(string: text)!, title: "Page") }
        XCTAssertEqual(Set(history.everything().map { $0.url.absoluteString }), Set(urls))
        history.forget(Address.identity(URL(string: urls[0])!))
        XCTAssertEqual(history.everything().count, urls.count - 1)
        XCTAssertFalse(history.everything().contains { $0.url.absoluteString == urls[0] })
    }

    @MainActor
    func testLegacyHistoryMigratesByURLAndMergesDuplicates() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let entries: [[String: Any]] = [
            ["url": "https://example.com/a?q=one", "key": "example.com/a", "title": "One", "count": 2, "last": 10.0],
            ["url": "https://example.com/a?q=two", "key": "example.com/a", "title": "Two", "count": 3, "last": 20.0],
            ["url": "https://example.com/a?q=one", "key": "example.com/a", "title": "New title", "count": 1, "last": 30.0]
        ]
        try JSONSerialization.data(withJSONObject: entries).write(to: file)
        let history = History(file: file)
        XCTAssertEqual(history.everything().count, 2)
        XCTAssertEqual(history.everything().first?.count, 3)
        XCTAssertEqual(history.everything().first?.title, "New title")
    }

    @MainActor
    func testImportPublishesOnceAndCapsLiveHistory() async {
        let history = History(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), capacity: 20)
        var changes = 0
        let subscription = history.objectWillChange.sink { changes += 1 }
        history.batch {
            for n in 0..<500 {
                history.take(URL(string: "https://example.com/\(n)")!, title: "Page \(n)", count: n + 1, last: Date())
            }
        }
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(history.everything().count, 20)
        XCTAssertEqual(history.suggestions(for: "example", limit: 3).count, 3)
        XCTAssertTrue(history.everything(matching: "PAGE 499").contains { $0.title == "Page 499" })
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testCompletionDoesNotChangeSchemeOrPathCase() async {
        let history = History(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let http = Suggestion(key: "example.com/path", title: "", url: URL(string: "http://example.com/path")!, kind: .visited)
        XCTAssertNil(history.completion(for: "exam", among: [http]))
        XCTAssertEqual(history.completion(for: "http://exam", among: [http]), "ple.com/path")
        let path = Suggestion(key: "example.com/Case", title: "", url: URL(string: "https://example.com/Case")!, kind: .visited)
        XCTAssertNil(history.completion(for: "example.com/ca", among: [path]))
    }
}

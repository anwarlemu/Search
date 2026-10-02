import XCTest
import AppKit
import WebKit
import Network
@testable import Browser

/// Local HTTP transfers exercise WebKit's actual cancellation/resume data,
/// including a server which disconnects halfway through its first response.
private final class DownloadServer: @unchecked Sendable {
    static let size = 384 * 1024
    private let queue = DispatchQueue(label: "browser.tests.http")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var failedOnce = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)")!)
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.read(connection, bytes: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
            listener.cancel()
        }
    }

    private func read(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, let data, error == nil else { connection.cancel(); return }
            let all = bytes + data
            let request = String(decoding: all, as: UTF8.self)
            guard request.contains("\r\n\r\n") else {
                if complete { connection.cancel() } else { self.read(connection, bytes: all) }
                return
            }
            let flaky = request.hasPrefix("GET /flaky") && !self.failedOnce
            if flaky { self.failedOnce = true }
            let range = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range: bytes=") }
            let start = range.flatMap { Int($0.components(separatedBy: "=").last?.split(separator: "-").first ?? "0") } ?? 0
            let status = start > 0 ? "206 Partial Content" : "200 OK"
            var headers = "HTTP/1.1 \(status)\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=fixture.bin\r\nAccept-Ranges: bytes\r\nETag: \"fixture-1\"\r\nContent-Length: \(Self.size - start)\r\nConnection: close\r\n"
            if start > 0 { headers += "Content-Range: bytes \(start)-\(Self.size - 1)/\(Self.size)\r\n" }
            headers += "\r\n"
            connection.send(content: Data(headers.utf8), completion: .contentProcessed { error in
                guard error == nil else { connection.cancel(); return }
                self.send(connection, offset: start, end: flaky ? Self.size / 2 : Self.size)
            })
        }
    }

    private func send(_ connection: NWConnection, offset: Int, end: Int) {
        guard offset < end else { connection.cancel(); return }
        let count = min(8192, end - offset)
        connection.send(content: Data(repeating: 65, count: count), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + 0.03) { self.send(connection, offset: offset + count, end: end) }
        })
    }
}

final class DownloadTests: XCTestCase {
    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Download did not reach expected state")
    }

    @MainActor
    func testProgressCancellationAndRetry() async throws { try await transfer(flaky: false) }

    @MainActor
    func testFailureRemainsVisibleAndCanResume() async throws { try await transfer(flaky: true) }

    @MainActor
    private func transfer(flaky: Bool) async throws {
        _ = NSApplication.shared
        let server = try DownloadServer()
        let origin = try await server.start()
        defer { server.stop() }
        let browser = Browser(private: true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let previous = browser.prefs.downloads
        let asked = browser.prefs.asksWhereToSave
        browser.prefs.downloads = folder
        browser.prefs.asksWhereToSave = false
        defer {
            browser.endPrivate()
            browser.prefs.downloads = previous
            browser.prefs.asksWhereToSave = asked
            try? FileManager.default.removeItem(at: folder)
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        let download = await web.startDownload(using: URLRequest(url: origin.appendingPathComponent(flaky ? "flaky" : "download")))
        browser.keep(download)
        let item = try XCTUnwrap(browser.transfers.first)
        try await wait { item.received > 0 }
        XCTAssertNotNil(item.fraction)
        browser.clearDownloads()
        XCTAssertTrue(browser.transfers.contains { $0.id == item.id })
        XCTAssertTrue(item.active)
        if flaky {
            try await wait { item.state == .failed }
            XCTAssertNotNil(item.problem)
            XCTAssertTrue(browser.transfers.contains { $0.id == item.id })
        } else {
            browser.cancelDownload(item)
            try await wait { !item.cancelling }
            XCTAssertEqual(item.state, .cancelled)
        }
        XCTAssertTrue(browser.downloading.isEmpty)
        XCTAssertTrue(item.canRetry)
        browser.retryDownload(item)
        try await wait { item.state == .complete || item.state == .failed }
        XCTAssertEqual(item.state, .complete, item.problem ?? "No failure detail")
        let file = try XCTUnwrap(item.destination)
        XCTAssertEqual(try Data(contentsOf: file).count, DownloadServer.size)
        XCTAssertTrue(browser.downloading.isEmpty)
        browser.clearDownloads()
        XCTAssertTrue(browser.transfers.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}

import XCTest
import AppKit
import SwiftUI
import WebKit
@testable import Browser

final class InteractionTests: XCTestCase {
    @MainActor
    private func browser() -> Browser {
        _ = NSApplication.shared
        return Browser(private: true)
    }

    @MainActor
    private func loaded(_ web: WKWebView, marker: String) async throws {
        for _ in 0..<100 {
            if let value = try? await web.evaluateJavaScript("document.body && document.body.dataset.test"), value as? String == marker { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Web view did not load fixture \(marker)")
    }

    @MainActor
    func testReturningProfileCannotBeParkedByOldCallbacks() async throws {
        let browser = browser()
        defer { browser.endPrivate() }
        let tab = try XCTUnwrap(browser.active)
        tab.setAddressOptimistically(URL(string: "https://example.invalid/profile")!)
        let web = tab.web
        web.loadHTMLString("<body data-test='profile'>Keep this page</body>", baseURL: tab.address)
        try await loaded(web, marker: "profile")
        try await Task.sleep(for: .milliseconds(100))
        let other = browser.makeProfile(named: "Other")
        for _ in 0..<5 {
            browser.switchProfile(to: other)
            browser.switchProfile(to: 0)
        }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(browser.awake(because: tab, parking: true), "on screen")
        XCTAssertFalse(tab.asleep)
        XCTAssertTrue(tab.built === web)
    }

    @MainActor
    func testPanelDismissalFollowsVisualOrder() async {
        let browser = browser()
        defer { browser.endPrivate() }
        browser.recalling = true
        browser.hoarding = true
        browser.tuning = true
        XCTAssertEqual(browser.frontPanel, .settings)
        XCTAssertTrue(browser.dismissTopPanel())
        XCTAssertEqual(browser.frontPanel, .downloads)
        XCTAssertTrue(browser.dismissTopPanel())
        XCTAssertEqual(browser.frontPanel, .history)
        XCTAssertTrue(browser.dismissTopPanel())
        XCTAssertNil(browser.frontPanel)
        XCTAssertFalse(browser.dismissTopPanel())
    }

    @MainActor
    func testEditingUsesFullURL() async throws {
        let browser = browser()
        defer { browser.endPrivate() }
        let url = URL(string: "http://localhost:3000/Case?q=a%2Bb#result")!
        let tab = try XCTUnwrap(browser.active)
        tab.setAddressOptimistically(url)
        browser.edit()
        XCTAssertEqual(browser.completed, url.absoluteString)
        browser.beginTabEdit(tab)
        XCTAssertEqual(browser.tabDraft, url.absoluteString)
    }

    @MainActor
    func testRecoveryInvalidatesOldWorkAndDoesNotReplayPosts() async {
        let tab = Tab()
        tab.navigationRequest = URLRequest(url: URL(string: "https://example.com/submit")!)
        tab.navigationRequest?.httpMethod = "POST"
        XCTAssertFalse(tab.canRetryNavigation)
        tab.navigationRequest?.httpMethod = "GET"
        XCTAssertTrue(tab.canRetryNavigation)
        tab.slow = true
        tab.workerRecoveryAvailable = true
        let old = tab.navigationID
        tab.stop()
        XCTAssertNotEqual(tab.navigationID, old)
        XCTAssertFalse(tab.slow)
        XCTAssertFalse(tab.workerRecoveryAvailable)
    }

    @MainActor
    func testScrollingDoesNotRescanFormsOrSendUnchangedMessages() async throws {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.inactiveSchedulingPolicy = .none
        let capture = """
        window.__events = []; window.__scans = 0;
        window.__capture = function (value) { window.__events.push(value); };
        const original = document.querySelectorAll.bind(document);
        document.querySelectorAll = function (selector) {
          if (selector === 'input[type="password"]') window.__scans++;
          return original(selector);
        };
        """
        let script = capture + FormRelay.script.replacingOccurrences(of: "window.webkit.messageHandlers.officeForms.postMessage", with: "window.__capture")
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        defer { web.stopLoading() }
        web.loadHTMLString("<body data-test='forms'><div style='height:4000px'>Article</div></body>", baseURL: nil)
        try await loaded(web, marker: "forms")
        try await Task.sleep(for: .milliseconds(2500))
        _ = try await web.evaluateJavaScript("window.__scans = 0; window.__events = []; for (let i=0;i<60;i++) window.dispatchEvent(new Event('scroll'));")
        try await Task.sleep(for: .milliseconds(250))
        let scans = try await web.evaluateJavaScript("window.__scans") as? Int
        let messages = try await web.evaluateJavaScript("window.__events.length") as? Int
        XCTAssertEqual(scans, 0)
        XCTAssertEqual(messages, 0)

        _ = try await web.evaluateJavaScript("document.body.insertAdjacentHTML('afterbegin', '<form><input id=login><input type=password></form>');")
        try await Task.sleep(for: .milliseconds(200))
        _ = try await web.evaluateJavaScript("document.getElementById('login').focus();")
        try await Task.sleep(for: .milliseconds(100))
        let foundForm = try await web.evaluateJavaScript("window.__events.some(e => e.kind === 'form')") as? Bool
        XCTAssertEqual(foundForm, true)
        _ = try await web.evaluateJavaScript("window.__scans = 0; for (let i=0;i<60;i++) window.dispatchEvent(new Event('scroll'));")
        try await Task.sleep(for: .milliseconds(250))
        let focusedScans = try await web.evaluateJavaScript("window.__scans") as? Int
        XCTAssertEqual(focusedScans, 0)
    }

    @MainActor
    func testSmallWindowLayouts() async throws {
        let browser = browser()
        defer { browser.endPrivate() }
        let settings = NSHostingView(rootView: SettingsPanel(browser: browser, prefs: browser.prefs)
            .environment(\.panelSize, CGSize(width: 608, height: 388)))
        XCTAssertLessThanOrEqual(settings.fittingSize.width, 608)
        XCTAssertLessThanOrEqual(settings.fittingSize.height, 388)
        let root = NSHostingView(rootView: Omnibox(browser: browser, over: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 420), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = root
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        root.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        let field = try XCTUnwrap(fields(root).first)
        let rect = field.convert(field.bounds, to: root)
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertLessThanOrEqual(rect.maxX, root.bounds.width)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxY, root.bounds.height)
    }

    @MainActor
    func testHistoryPanelFitsMinimumWindow() async throws {
        let browser = browser()
        defer { browser.endPrivate() }
        let settings = SettingsPanel(browser: browser, prefs: browser.prefs)
            .environment(\.panelSize, CGSize(width: 608, height: 388))
        try await capture(settings, size: CGSize(width: 608, height: 388), name: "settings")
        browser.history.batch {
            for n in 0..<100 {
                browser.history.take(URL(string: "https://layout.invalid/\(n)")!, title: "Example page \(n)", count: 1, last: Date())
            }
        }
        defer { browser.history.forget() }
        let history = HistoryPanel(browser: browser)
            .environment(\.panelSize, CGSize(width: 608, height: 388))
        try await capture(history, size: CGSize(width: 608, height: 388), name: "history")
    }

    @MainActor
    private func capture<V: View>(_ view: V, size: CGSize, name: String) async throws {
        let root = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = root
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(250))
        root.layoutSubtreeIfNeeded()
        func scrolls(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
        }
        for scroll in scrolls(root) {
            let rect = scroll.convert(scroll.bounds, to: root)
            XCTAssertGreaterThanOrEqual(rect.minY, -1)
            XCTAssertLessThanOrEqual(rect.maxY, size.height + 1)
        }
        if let folder = ProcessInfo.processInfo.environment["BROWSER_TEST_ARTIFACTS"],
           let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }
}

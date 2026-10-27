import XCTest
import AppKit
import WebKit
@testable import Browser

final class WindowRecoveryTests: XCTestCase {
    @MainActor
    private func window(at origin: NSPoint = NSPoint(x: 120, y: 120)) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 800, height: 600)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor
    func testDockReopensBrowserEvenWhenAnAuxiliaryWindowIsVisible() async {
        _ = NSApplication.shared
        let browser = Browser(private: true)
        let main = window()
        let auxiliary = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 300, height: 200),
                                 styleMask: .borderless, backing: .buffered, defer: false)
        auxiliary.isReleasedWhenClosed = false
        let previous = Links.window
        browser.window = main
        Links.window = main
        defer {
            main.orderOut(nil)
            auxiliary.orderOut(nil)
            Links.window = previous
            browser.endPrivate()
        }
        auxiliary.orderBack(nil)
        main.orderOut(nil)
        let tab = browser.active
        let handled = Links().applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        XCTAssertFalse(handled, "The browser must handle recovery, regardless of auxiliary windows")
        XCTAssertTrue(main.isVisible)
        XCTAssertTrue(browser.active === tab, "Recovery must keep the existing page")
    }

    @MainActor
    func testDockReturnsOffscreenBrowserToAnAttachedDisplay() async {
        _ = NSApplication.shared
        let browser = Browser(private: true)
        let main = window(at: NSPoint(x: -20000, y: -20000))
        let previous = Links.window
        browser.window = main
        Links.window = main
        defer { main.orderOut(nil); Links.window = previous; browser.endPrivate() }
        main.orderBack(nil)
        main.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        let title = NSRect(x: main.frame.minX, y: main.frame.maxY - 32, width: main.frame.width, height: 32)
        XCTAssertFalse(NSScreen.screens.contains { $0.visibleFrame.intersection(title).width >= 80 })
        _ = Links().applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.intersects(main.frame) })
    }

    @MainActor
    func testDockKeepsLivePageAndJavaScriptState() async throws {
        let main = window()
        let browser = Browser(private: true)
        let previous = Links.window
        browser.window = main
        Links.window = main
        defer { main.orderOut(nil); Links.window = previous; browser.endPrivate() }
        let tab = try XCTUnwrap(browser.active)
        let web = tab.web
        main.contentView?.addSubview(web)
        web.loadHTMLString("<body><script>window.meetingState = {connected: true, token: 'same-page'};</script></body>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("window.meetingState && window.meetingState.connected")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        main.orderOut(nil)
        _ = Links().applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        XCTAssertTrue(main.isVisible)
        XCTAssertTrue(tab.built === web)
        let state = try await web.evaluateJavaScript("window.meetingState.token") as? String
        XCTAssertEqual(state, "same-page")
    }

    @MainActor
    func testClosedSceneUsesSceneOpenerInsteadOfItsOldWindow() async {
        let main = window()
        let browser = Browser(private: true)
        let previous = Links.window
        let previousOpen = Links.openMain
        browser.window = main
        browser.windowWatch = WindowWatch(main, browser: browser)
        Links.window = main
        var opens = 0
        Links.openMain = { opens += 1 }
        defer { main.orderOut(nil); Links.window = previous; Links.openMain = previousOpen }
        main.close()
        XCTAssertNil(browser.window)
        XCTAssertNil(Links.window)
        XCTAssertNil(browser.windowWatch)
        XCTAssertFalse(Links().applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertEqual(opens, 1)
        XCTAssertFalse(main.isVisible)
    }

    @MainActor
    func testAuxiliaryWindowCannotReplaceBrowserDuringDeferredSetup() async {
        let main = window()
        let auxiliary = NSPanel(contentRect: main.frame, styleMask: [.titled], backing: .buffered, defer: false)
        auxiliary.isReleasedWhenClosed = false
        var attached: [NSWindow] = []
        let probe = WindowSetup.Probe { attached.append($0) }
        main.contentView?.addSubview(probe)
        auxiliary.contentView?.addSubview(probe)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(attached.isEmpty, "Neither a stale attachment nor a panel is the browser window")
        main.contentView?.addSubview(probe)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(attached.count, 1)
        XCTAssertTrue(attached.first === main)
        main.orderOut(nil)
        auxiliary.orderOut(nil)
    }

    @MainActor
    func testDockIgnoresStalePanelReference() async {
        let main = window()
        let browser = Browser(private: true)
        let panel = NSPanel(contentRect: main.frame, styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let previous = Links.window
        browser.window = main
        Links.window = panel
        defer { main.orderOut(nil); panel.orderOut(nil); Links.window = previous; browser.endPrivate() }
        main.orderOut(nil)
        _ = Links().applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        XCTAssertTrue(main.isVisible)
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testReusedWindowReportsItsAttachmentAgainWhenItBecomesKey() async throws {
        let main = window()
        var attachments = 0
        let probe = WindowSetup.Probe { _ in attachments += 1 }
        main.contentView?.addSubview(probe)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(attachments, 1)
        // SwiftUI may reopen the same content in the same NSWindow, without
        // another viewDidMoveToWindow call. Replay that window's key event.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: main)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(attachments, 2)
        main.orderOut(nil)
    }

    @MainActor
    func testDockRestoresMinimizedBrowser() async throws {
        let main = window()
        let browser = Browser(private: true)
        browser.window = main
        let previous = Links.window
        Links.window = main
        defer { main.orderOut(nil); Links.window = previous; browser.endPrivate() }
        main.makeKeyAndOrderFront(nil)
        main.miniaturize(nil)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(main.isMiniaturized)
        _ = Links().applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(main.isMiniaturized)
        XCTAssertTrue(main.isVisible)
    }

    @MainActor
    func testReachableWindowsOnSecondaryDisplaysKeepTheirPosition() {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let secondary = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let frame = NSRect(x: -1800, y: 100, width: 1000, height: 800)
        XCTAssertEqual(WindowRecovery.reachableFrame(frame, screens: [primary, secondary], preferred: primary), frame)
        let restored = WindowRecovery.reachableFrame(frame, screens: [primary], preferred: primary)
        XCTAssertTrue(primary.contains(restored))
        let oversized = NSRect(x: 4000, y: 4000, width: 3000, height: 2000)
        XCTAssertTrue(primary.contains(WindowRecovery.reachableFrame(oversized, screens: [primary], preferred: primary)))
    }

    @MainActor
    func testQuitKeepsWindowsAvailableForFinalSessionFlush() {
        let main = window()
        let browser = Browser(private: true)
        browser.window = main
        browser.windowWatch = WindowWatch(main, browser: browser)
        let wasQuitting = Browser.quitting
        Browser.quitting = true
        defer { Browser.quitting = wasQuitting; browser.windowWatch = nil; browser.endPrivate() }
        main.close()
        XCTAssertTrue(browser.window === main)
        XCTAssertFalse(Links.reopen())
    }
}

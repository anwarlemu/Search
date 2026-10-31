import XCTest
import AppKit
import WebKit
@testable import Browser

final class PinnedTabTests: XCTestCase {
    @MainActor
    private func window(_ stage: StageView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = stage
        return window
    }

    @MainActor
    func testReturningToOpenPinKeepsWindowAndDocument() async throws {
        let stage = StageView()
        let main = window(stage)
        let pin = Tab(shy: true)
        pin.pin = "P"
        let web = pin.web
        var attachments = 0
        web.onWindow = { attachments += 1 }
        defer { web.onWindow = nil; web.stopLoading(); main.orderOut(nil) }
        stage.show(web, keeping: [web])
        web.loadHTMLString("<body><input id=draft><script>window.visitToken = 'original';</script></body>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("window.visitToken")) as? String == "original" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try await web.evaluateJavaScript("document.getElementById('draft').value = 'unsent draft'")
        let other = NSView()
        for _ in 0..<10 {
            stage.show(other, keeping: [web])
            XCTAssertTrue(web.window === main)
            XCTAssertTrue(web.isHidden)
            stage.show(web, keeping: [web])
            XCTAssertFalse(web.isHidden)
            XCTAssertNil(other.superview)
        }
        XCTAssertEqual(attachments, 1, "Returning to a pin must not reattach its WebKit view")
        let token = try await web.evaluateJavaScript("window.visitToken") as? String
        let draft = try await web.evaluateJavaScript("document.getElementById('draft').value") as? String
        XCTAssertEqual(token, "original")
        XCTAssertEqual(draft, "unsent draft")
        XCTAssertEqual(web.frame, stage.bounds)
    }

    @MainActor
    func testUnpinnedAndClosedPagesAreReleasedFromStage() {
        let stage = StageView()
        let main = window(stage)
        defer { main.orderOut(nil) }
        let pin = NSView()
        let other = NSView()
        stage.show(pin, keeping: [pin])
        stage.show(other, keeping: [pin])
        XCTAssertTrue(pin.isHidden)
        stage.show(other)
        XCTAssertNil(pin.superview)
        XCTAssertFalse(pin.isHidden, "A released view must be usable in another window")
        stage.show(nil)
        XCTAssertTrue(stage.subviews.isEmpty)
    }

    @MainActor
    func testStageDoesNotStealFloatingOrBuildUnopenedPins() {
        let stage = StageView()
        let main = window(stage)
        defer { main.orderOut(nil) }
        let floatingHost = NSView()
        let floating = NSView()
        floatingHost.addSubview(floating)
        stage.show(NSView(), keeping: [floating])
        stage.layout()
        XCTAssertTrue(floating.superview === floatingHost)
        let unopened = Tab(shy: true)
        unopened.pin = "P"
        unopened.restore(url: URL(string: "https://example.invalid")!, title: "Pin")
        let eligible = [unopened].filter { $0.stage.wanted }.compactMap { $0.built }
        stage.show(nil, keeping: eligible)
        XCTAssertNil(unopened.built)
        XCTAssertTrue(unopened.asleep)
    }
}

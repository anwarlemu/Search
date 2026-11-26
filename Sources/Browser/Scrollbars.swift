import AppKit
import ObjectiveC

/// Scroll bars that fade away when nothing is scrolling, even with System
/// Settings › Appearance › Show scroll bars set to Always, or Automatically
/// with a mouse plugged in (from upstream Search, #1490).
///
/// WebKit draws a page's scroll bars in the style AppKit prefers, and asks
/// again when AppKit says the style has changed: answered "overlay" for this
/// app alone, pages get the Mac's thin bars over the page instead of beside
/// it, that come up as it scrolls and fade once it stops. The app's own
/// lists too.
@MainActor
enum Scrollbars {
    private static var installed = false

    /// Once, at launch.
    static func fade() {
        guard !installed else { return }
        let pick = #selector(getter: NSScroller.preferredScrollerStyle)
        guard let method = class_getClassMethod(NSScroller.self, pick) else { return }
        installed = true
        let block: @convention(block) (AnyClass) -> Int = { _ in NSScroller.Style.overlay.rawValue }
        method_setImplementation(method, imp_implementationWithBlock(block))
        // WebKit hears this and tells every page's process.
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }
}

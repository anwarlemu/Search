import AppKit

// A guard around one assertion inside macOS, which took the whole browser
// down twice (23 and 24 Sep 2026).
//
// Safari's autofill machinery puts a remote view in a page — the list that
// can hang under a form field. When the page's view leaves its window (a tab
// you switched away from, a video lifted into the floating window) that
// remote view goes on listening for windows coming on screen, and the next
// one that does — the floating video, the Web Inspector — it answers with
// an assertion: "notified of <that window> but expected (null)". An
// assertion there is an uncaught exception, and an uncaught exception is
// the app gone.
//
// The notification is meant for the remote view's own window. Told about a
// window that isn't its own, or having none, it has nothing to do — so in
// exactly that case it now does nothing, and in every other case it runs as
// it always did. Installed once, when the first page is built.

enum ViewBridgeGuard {
    @MainActor private static var installed = false

    /// Every one of the remote view's window notifications that asserts
    /// when it is told about a window that isn't its own — found by calling
    /// each on a detached remote view (25 Sep 2026): will and did order on
    /// screen, will and did order off, and a change of occlusion. Moving is
    /// harmless but guarded the same way.
    private static let handlers = [
        "containingWindowWillOrderOnScreen:", "containingWindowDidOrderOnScreen:",
        "containingWindowWillOrderOffScreen:", "containingWindowDidOrderOffScreen:",
        "containingWindowDidChangeOcclusionState:", "containingWindowDidMove:",
    ]

    @MainActor static func install() {
        guard !installed else { return }
        installed = true
        if NSClassFromString("NSRemoteView") == nil {
            _ = dlopen("/System/Library/PrivateFrameworks/ViewBridge.framework/ViewBridge", RTLD_NOW)
        }
        guard let remote = NSClassFromString("NSRemoteView") else { return }
        for name in handlers {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(remote, selector) else { continue }
            typealias Original = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let guarded: @convention(block) (AnyObject, AnyObject?) -> Void = { view, note in
                let own = (view as? NSView)?.window
                let about = (note as? NSNotification)?.object as AnyObject?
                guard let own, about === own else { return }
                original(view, selector, note)
            }
            method_setImplementation(method, imp_implementationWithBlock(guarded))
        }
    }
}

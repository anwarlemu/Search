import AppKit
import BridgeGuard

// A guard around one assertion inside macOS, which took the whole browser
// down more than once (23–25 Sep 2026).
//
// Safari's autofill machinery puts a remote view in a page — the list that
// can hang under a form field. When the page's view leaves its window (a tab
// you switched away from, a video lifted into the floating window) that
// remote view goes on listening for windows coming on and off screen, and
// when the next one does — the floating video, the Web Inspector — it
// answers with an assertion. An assertion there is an uncaught exception,
// and an uncaught exception is the app gone.
//
// The guard itself is Objective-C (Sources/BridgeGuard), because catching
// that exception is something only Objective-C can do. Apple's code runs
// every time; only the assertion is caught. Installed once, with the first
// page.

enum ViewBridgeGuard {
    static func install() { BridgeGuardInstall() }
}

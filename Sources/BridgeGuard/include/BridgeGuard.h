#import <Foundation/Foundation.h>

/// Wraps the window notifications of ViewBridge's NSRemoteView so the one
/// assertion they raise — "notified of <a window> but expected <another>" —
/// is caught instead of ending the app. Apple's own code runs every time,
/// unchanged; only that exception is swallowed. Safe to call more than once.
void BridgeGuardInstall(void);

#import "BridgeGuard.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// Why this is Objective-C: the fault is an Objective-C exception raised
// inside ViewBridge, and only Objective-C can catch one. A first guard in
// Swift decided for itself which notifications to let through, judged by
// the view's window — and turned away the ones the system's right-click
// menus need, which are drawn by a remote view too, leaving every menu
// empty (26 Sep 2026). This one lets every notification through to Apple's
// code and catches only the assertion that code raises.

static void wrap(Class cls, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    typedef void (*Original)(id, SEL, id);
    Original original = (Original)method_getImplementation(method);
    IMP guarded = imp_implementationWithBlock(^(id view, id note) {
        @try {
            original(view, selector, note);
        } @catch (NSException *exception) {
            if (![exception.name isEqualToString:NSInternalInconsistencyException]) @throw;
            // A remote view told about a window that isn't the one it
            // expects: nothing for it to do, and nothing worth ending on.
        }
    });
    method_setImplementation(method, guarded);
}

void BridgeGuardInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!NSClassFromString(@"NSRemoteView")) {
            dlopen("/System/Library/PrivateFrameworks/ViewBridge.framework/ViewBridge", RTLD_NOW);
        }
        Class cls = NSClassFromString(@"NSRemoteView");
        if (!cls) return;
        for (NSString *name in @[
            @"containingWindowWillOrderOnScreen:", @"containingWindowDidOrderOnScreen:",
            @"containingWindowWillOrderOffScreen:", @"containingWindowDidOrderOffScreen:",
            @"containingWindowDidChangeOcclusionState:", @"containingWindowDidMove:",
        ]) {
            wrap(cls, name);
        }
    });
}

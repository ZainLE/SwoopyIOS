import UIKit
import ObjectiveC
import Darwin

final class _CameraGuard: NSObject {
    static func install() {
        #if DEBUG
        // Swizzle the system image picker init to trap usage in debug builds
        let clsName = ["UI", "Image", "Picker", "Controller"].joined()
        guard let cls = NSClassFromString(clsName) as? AnyClass else { return }
        let originalSelector = Selector(("init"))
        let replacementSelector = #selector(_CameraGuard._guardedInit)
        if let original = class_getInstanceMethod(cls, originalSelector),
           let replacement = class_getInstanceMethod(_CameraGuard.self, replacementSelector) {
            method_exchangeImplementations(original, replacement)
        }
        #endif
    }

    @objc
    func _guardedInit() -> AnyObject {
        #if DEBUG
        NSLog("🚫 System image picker init intercepted. Use CameraOverlay instead.")
        raise(SIGTRAP) // Breaks into debugger in Debug builds
        #endif
        // Call through to the original (swizzled) init so the app doesn't crash
        return self._guardedInit()
    }
}

import Foundation
import os

#if DEBUG
let Log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Swoopy", category: "App")
@inline(__always) func DLog(_ message: String) {
    print(message)
    Log.debug("\(message, privacy: .auto)")
}
#else
@inline(__always) func DLog(_ message: String) { }
#endif

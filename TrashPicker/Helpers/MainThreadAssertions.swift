import Foundation

#if DEBUG
@inline(__always)
func assertMainThread(_ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    assert(Thread.isMainThread, "Must be main thread: \(message())", file: file, line: line)
}
#else
@inline(__always)
func assertMainThread(_ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {}
#endif

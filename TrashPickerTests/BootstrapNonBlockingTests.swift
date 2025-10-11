import XCTest
@testable import TrashPicker

final class BootstrapNonBlockingTests: XCTestCase {
    // Ensures that app bootstrap does not block the main actor while cached-session restore runs
    func testInitDoesNotBlockMainActor() throws {
        let mainTick = expectation(description: "Main actor remains responsive")
        let stateReady = expectation(description: "didCheckSession eventually set")

        // Schedule a quick main-queue tick that must run very soon if main is not blocked
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { // 20ms
            mainTick.fulfill()
        }

        // Trigger service init on main thread
        _ = SupabaseService.shared

        // Observe didCheckSession flipping to true without requiring main-thread blocking
        let checkInterval = 0.05
        var checks = 0
        let timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { t in
            if SupabaseService.shared.didCheckSession {
                stateReady.fulfill()
                t.invalidate()
            }
            checks += 1
            if checks > 40 { // 2 seconds max
                t.invalidate()
            }
        }
        RunLoop.main.add(timer, forMode: .default)

        wait(for: [mainTick], timeout: 0.25) // main must not be blocked >250ms
        wait(for: [stateReady], timeout: 2.5)
    }
}

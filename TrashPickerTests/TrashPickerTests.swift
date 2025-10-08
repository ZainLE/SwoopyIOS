//
//  TrashPickerTests.swift
//  TrashPickerTests
//
//  Created by Zain Latif  on 3/9/25.
//

import Testing
#if canImport(TrashPicker)
@testable import Swoopy
#else
// The app module isn't visible to this test target yet.
// To fix permanently:
// 1) Select the test target in the project editor (TrashPickerTests).
// 2) In Build Phases, add the app target (TrashPicker) under Target Dependencies.
// 3) In Build Settings, ensure `Enable Testing Search Paths` is Yes and the app target builds for the same platform.
// 4) Make sure the test target's "Host Application" is set to the app, if needed for UI tests.
#endif

struct TrashPickerTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

}

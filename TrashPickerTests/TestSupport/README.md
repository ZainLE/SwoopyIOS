# Test Support

Test infrastructure for TrashPicker/Swoopy iOS app.

## Overview

This folder contains utilities for writing robust, maintainable tests:

- **MockURLProtocol** - Intercept and stub network requests
- **Fixtures** - Load JSON fixtures from files
- **TestHelpers** - Convenience assertions and utilities

---

## MockURLProtocol

Intercepts URLSession requests and returns stubbed responses.

### Basic Usage

```swift
// Setup mock response
MockURLProtocol.requestHandler = { request in
    let json = ["status": "healthy"]
    let data = try! JSONSerialization.data(withJSONObject: json)
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, ...)
    return (response, data)
}

// Create session with mock
let session = makeURLSession(using: MockURLProtocol.self)
let (data, response) = try await session.data(from: url)
```

### Convenience Handlers

**Match specific URL:**
```swift
MockURLProtocol.requestHandler = MockURLProtocol.handler(
    for: "https://api.swoopy.eu/custom-api/health",
    method: "GET",
    statusCode: 200,
    data: jsonData
)
```

**Match URL pattern:**
```swift
MockURLProtocol.requestHandler = MockURLProtocol.jsonHandler(
    matching: "/health",
    method: "GET",
    statusCode: 200,
    json: ["status": "healthy"]
)
```

**Route multiple endpoints:**
```swift
MockURLProtocol.requestHandler = MockURLProtocol.router([
    "/health": healthHandler,
    "/feed": feedHandler,
    "/profile": profileHandler
])
```

### Cleanup

Always reset in `tearDown`:
```swift
override func tearDown() {
    super.tearDown()
    MockURLProtocol.reset()
}
```

---

## Fixtures

Load JSON test data from `TrashPickerTests/Fixtures/*.json`.

### Load Raw Data

```swift
let data = try Fixtures.load("health")
```

### Load and Decode

```swift
struct HealthResponse: Codable {
    let status: String
}

let health = try Fixtures.loadJSON("health", as: HealthResponse.self)
```

### Load as Dictionary

```swift
let dict = try Fixtures.loadDictionary("health")
let status = dict["status"] as? String
```

### Create Inline Fixtures

```swift
let data = try Fixtures.makeJSON(["status": "healthy"])
```

### Fixture File Location

Place JSON files in: `TrashPickerTests/Fixtures/`

Example: `TrashPickerTests/Fixtures/health.json`

---

## TestHelpers

Convenience utilities for common test operations.

### URLSession Factory

```swift
let session = makeURLSession(using: MockURLProtocol.self)
```

### HTTP Assertions

**Check status:**
```swift
XCTAssertHTTP(response, status: 200)
```

**Check status and body:**
```swift
XCTAssertHTTP(response, data: data, status: 200, bodyContains: "healthy")
```

**Assert decoding:**
```swift
let health = XCTAssertDecodes(data, as: HealthResponse.self)
XCTAssertEqual(health?.status, "healthy")
```

### Mock Response Builders

```swift
let response = makeMockResponse(url: url, statusCode: 200)
let json = makeMockJSON(["status": "healthy"])
```

### Data Extensions

```swift
let data = Data.json(#"{"status":"healthy"}"#)
let string = String(data: data)
```

---

## Example Test

```swift
import XCTest
@testable import TrashPicker

final class MyAPITests: XCTestCase {
    
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.reset()
    }
    
    func testHealthCheck() async throws {
        // Setup: Stub the endpoint
        MockURLProtocol.requestHandler = MockURLProtocol.jsonHandler(
            matching: "/health",
            json: ["status": "healthy"]
        )
        
        // Execute: Make request
        let session = makeURLSession()
        let url = URL(string: "https://api.swoopy.eu/custom-api/health")!
        let (data, response) = try await session.data(from: url)
        
        // Verify: Check response
        XCTAssertHTTP(response, status: 200)
        
        struct HealthResponse: Codable {
            let status: String
        }
        
        let health = XCTAssertDecodes(data, as: HealthResponse.self)
        XCTAssertEqual(health?.status, "healthy")
    }
}
```

---

## Best Practices

1. **Always reset MockURLProtocol** in `tearDown()`
2. **Use fixtures for complex responses** - easier to maintain
3. **Use convenience handlers** for simple cases
4. **Use router for multiple endpoints** in the same test
5. **Assert both status and body** for complete verification
6. **Create reusable fixtures** for common responses

---

## Files

- `MockURLProtocol.swift` - Network request interceptor
- `Fixtures.swift` - JSON fixture loader
- `TestHelpers.swift` - Assertion and utility helpers
- `README.md` - This documentation

---

## Adding New Fixtures

1. Create JSON file: `TrashPickerTests/Fixtures/my-fixture.json`
2. Load in test: `let data = try Fixtures.load("my-fixture")`
3. Use with mock: `MockURLProtocol.requestHandler = { _ in (response, data) }`

---

## Troubleshooting

**"No request handler set"**
- Set `MockURLProtocol.requestHandler` before making requests

**"Fixture file not found"**
- Check file is in `TrashPickerTests/Fixtures/` folder
- Check file is added to test target (not app target)
- Check filename matches (case-sensitive)

**"Request doesn't match"**
- Check URL pattern in handler
- Check HTTP method matches
- Use router for multiple endpoints

---

## See Also

- `MockNetworkingTests.swift` - Example usage
- `ReservationDecodingTests.swift` - Model decoding tests

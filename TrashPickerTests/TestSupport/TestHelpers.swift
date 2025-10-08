//
//  TestHelpers.swift
//  TrashPickerTests
//
//  Convenience helpers for testing
//

import Foundation
import XCTest

// MARK: - URLSession Factory

/// Create a URLSession configured to use MockURLProtocol
/// - Parameter protocolClass: The mock protocol class to use (default: MockURLProtocol)
/// - Returns: URLSession configured for testing
func makeURLSession(using protocolClass: AnyClass = MockURLProtocol.self) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [protocolClass]
    return URLSession(configuration: config)
}

// MARK: - HTTP Assertions

/// Assert HTTP response properties
/// - Parameters:
///   - response: URLResponse to check
///   - expectedStatus: Expected HTTP status code
///   - file: Source file (auto-filled)
///   - line: Source line (auto-filled)
func XCTAssertHTTP(
    _ response: URLResponse?,
    status expectedStatus: Int,
    file: StaticString = #file,
    line: UInt = #line
) {
    guard let httpResponse = response as? HTTPURLResponse else {
        XCTFail("Response is not HTTPURLResponse", file: file, line: line)
        return
    }
    
    XCTAssertEqual(
        httpResponse.statusCode,
        expectedStatus,
        "Expected status \(expectedStatus), got \(httpResponse.statusCode)",
        file: file,
        line: line
    )
}

/// Assert HTTP response with body check
/// - Parameters:
///   - response: URLResponse to check
///   - data: Response data
///   - expectedStatus: Expected HTTP status code
///   - expectedBody: Expected body content (substring match)
///   - file: Source file (auto-filled)
///   - line: Source line (auto-filled)
func XCTAssertHTTP(
    _ response: URLResponse?,
    data: Data?,
    status expectedStatus: Int,
    bodyContains expectedBody: String? = nil,
    file: StaticString = #file,
    line: UInt = #line
) {
    // Check status
    XCTAssertHTTP(response, status: expectedStatus, file: file, line: line)
    
    // Check body if expected
    if let expectedBody = expectedBody {
        guard let data = data,
              let body = String(data: data, encoding: .utf8) else {
            XCTFail("No response body", file: file, line: line)
            return
        }
        
        XCTAssertTrue(
            body.contains(expectedBody),
            "Expected body to contain '\(expectedBody)', got: \(body)",
            file: file,
            line: line
        )
    }
}

/// Assert JSON response decodes successfully
/// - Parameters:
///   - data: Response data
///   - type: Type to decode to
///   - file: Source file (auto-filled)
///   - line: Source line (auto-filled)
/// - Returns: Decoded object
@discardableResult
func XCTAssertDecodes<T: Decodable>(
    _ data: Data?,
    as type: T.Type,
    file: StaticString = #file,
    line: UInt = #line
) -> T? {
    guard let data = data else {
        XCTFail("No data to decode", file: file, line: line)
        return nil
    }
    
    do {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    } catch {
        XCTFail("Failed to decode: \(error.localizedDescription)", file: file, line: line)
        return nil
    }
}

// MARK: - Async Testing Helpers

/// Wait for async condition with timeout
/// - Parameters:
///   - timeout: Maximum time to wait (default: 5 seconds)
///   - condition: Async condition to check
/// - Returns: True if condition met, false if timeout
@discardableResult
func waitFor(
    timeout: TimeInterval = 5.0,
    condition: @escaping () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
    }
    
    return false
}

// MARK: - Data Helpers

extension Data {
    /// Create Data from a JSON string literal
    static func json(_ string: String) -> Data {
        string.data(using: .utf8)!
    }
}

extension String {
    /// Create a String from Data (convenience)
    init?(data: Data) {
        self.init(data: data, encoding: .utf8)
    }
}

// MARK: - Mock Response Builders

/// Build a mock HTTP response
/// - Parameters:
///   - url: URL for the response
///   - statusCode: HTTP status code
///   - headers: HTTP headers
/// - Returns: HTTPURLResponse
func makeMockResponse(
    url: URL,
    statusCode: Int = 200,
    headers: [String: String]? = ["Content-Type": "application/json"]
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: headers
    )!
}

/// Build mock JSON response data
/// - Parameter json: Dictionary to encode
/// - Returns: JSON data
func makeMockJSON(_ json: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: json)
}

/// Build mock JSON array response data
/// - Parameter json: Array to encode
/// - Returns: JSON data
func makeMockJSON(_ json: [[String: Any]]) -> Data {
    try! JSONSerialization.data(withJSONObject: json)
}

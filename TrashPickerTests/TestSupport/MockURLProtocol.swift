//
//  MockURLProtocol.swift
//  TrashPickerTests
//
//  Mock URLProtocol for intercepting network requests in tests
//

import Foundation

/// Mock URLProtocol that intercepts requests and returns stubbed responses
/// Usage:
///   MockURLProtocol.requestHandler = { request in
///       return (HTTPURLResponse(...), Data(...))
///   }
///   let session = makeURLSession(using: MockURLProtocol.self)
class MockURLProtocol: URLProtocol {
    
    /// Handler type for intercepting requests
    /// Returns (response, data) tuple or throws an error
    typealias RequestHandler = (URLRequest) throws -> (HTTPURLResponse, Data)
    
    /// Static handler that will be called for each request
    /// Set this in your test to provide stubbed responses
    static var requestHandler: RequestHandler?
    
    /// Reset the handler (call in tearDown)
    static func reset() {
        requestHandler = nil
    }
    
    // MARK: - URLProtocol Override
    
    override class func canInit(with request: URLRequest) -> Bool {
        // Intercept all requests
        return true
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            // No handler set - fail with error
            let error = NSError(
                domain: "MockURLProtocol",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No request handler set"]
            )
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        
        do {
            // Call the handler to get response and data
            let (response, data) = try handler(request)
            
            // Send response to client
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            
        } catch {
            // Handler threw an error - pass it to client
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    
    override func stopLoading() {
        // Nothing to do
    }
}

// MARK: - Convenience Helpers

extension MockURLProtocol {
    
    /// Create a handler that matches specific URL and method
    /// - Parameters:
    ///   - url: URL string to match
    ///   - method: HTTP method to match (GET, POST, etc.)
    ///   - statusCode: HTTP status code to return
    ///   - data: Response data
    /// - Returns: RequestHandler that matches the criteria
    static func handler(
        for url: String,
        method: String = "GET",
        statusCode: Int = 200,
        data: Data = Data()
    ) -> RequestHandler {
        return { request in
            guard request.url?.absoluteString == url,
                  request.httpMethod == method else {
                throw NSError(
                    domain: "MockURLProtocol",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Request doesn't match: \(request.url?.absoluteString ?? "nil") \(request.httpMethod ?? "nil")"]
                )
            }
            
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            
            return (response, data)
        }
    }
    
    /// Create a handler that matches URL pattern and returns JSON
    /// - Parameters:
    ///   - urlPattern: URL pattern to match (can use contains)
    ///   - method: HTTP method to match
    ///   - statusCode: HTTP status code
    ///   - json: Dictionary to encode as JSON
    /// - Returns: RequestHandler
    static func jsonHandler(
        matching urlPattern: String,
        method: String = "GET",
        statusCode: Int = 200,
        json: [String: Any]
    ) -> RequestHandler {
        return { request in
            guard let urlString = request.url?.absoluteString,
                  urlString.contains(urlPattern),
                  request.httpMethod == method else {
                throw NSError(
                    domain: "MockURLProtocol",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Request doesn't match pattern: \(urlPattern)"]
                )
            }
            
            let data = try JSONSerialization.data(withJSONObject: json)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            
            return (response, data)
        }
    }
    
    /// Create a handler that routes based on URL patterns
    /// - Parameter routes: Dictionary of URL patterns to handlers
    /// - Returns: RequestHandler that routes to appropriate handler
    static func router(_ routes: [String: RequestHandler]) -> RequestHandler {
        return { request in
            guard let urlString = request.url?.absoluteString else {
                throw NSError(
                    domain: "MockURLProtocol",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No URL in request"]
                )
            }
            
            // Find matching route
            for (pattern, handler) in routes {
                if urlString.contains(pattern) {
                    return try handler(request)
                }
            }
            
            // No route matched
            throw NSError(
                domain: "MockURLProtocol",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No route matched: \(urlString)"]
            )
        }
    }
}

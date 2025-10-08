//
//  Fixtures.swift
//  TrashPickerTests
//
//  Load JSON fixtures from test bundle
//

import Foundation
import XCTest

/// Load JSON fixtures from SwoopyTests/Fixtures/*.json
enum Fixtures {
    
    /// Load a JSON fixture file by name
    /// - Parameter name: Filename without .json extension
    /// - Returns: Data from the fixture file
    /// - Throws: Error if file not found or can't be read
    static func load(_ name: String) throws -> Data {
        let bundle = Bundle(for: FixturesBundleMarker.self)
        
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw FixtureError.fileNotFound(name)
        }
        
        return try Data(contentsOf: url)
    }
    
    /// Load and decode a JSON fixture
    /// - Parameters:
    ///   - name: Filename without .json extension
    ///   - type: Type to decode to
    /// - Returns: Decoded object
    /// - Throws: Error if file not found or decoding fails
    static func loadJSON<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let data = try load(name)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
    
    /// Load a fixture as a dictionary
    /// - Parameter name: Filename without .json extension
    /// - Returns: Dictionary representation
    /// - Throws: Error if file not found or not valid JSON object
    static func loadDictionary(_ name: String) throws -> [String: Any] {
        let data = try load(name)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError.invalidFormat(name)
        }
        return dict
    }
    
    /// Load a fixture as an array
    /// - Parameter name: Filename without .json extension
    /// - Returns: Array representation
    /// - Throws: Error if file not found or not valid JSON array
    static func loadArray(_ name: String) throws -> [[String: Any]] {
        let data = try load(name)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw FixtureError.invalidFormat(name)
        }
        return array
    }
    
    /// Create a fixture inline from a dictionary
    /// - Parameter json: Dictionary to encode
    /// - Returns: JSON data
    /// - Throws: Error if encoding fails
    static func makeJSON(_ json: [String: Any]) throws -> Data {
        return try JSONSerialization.data(withJSONObject: json)
    }
    
    /// Create a fixture inline from an array
    /// - Parameter json: Array to encode
    /// - Returns: JSON data
    /// - Throws: Error if encoding fails
    static func makeJSON(_ json: [[String: Any]]) throws -> Data {
        return try JSONSerialization.data(withJSONObject: json)
    }
}

// MARK: - Errors

enum FixtureError: LocalizedError {
    case fileNotFound(String)
    case invalidFormat(String)
    
    var errorDescription: String? {
        switch self {
        case .fileNotFound(let name):
            return "Fixture file not found: \(name).json"
        case .invalidFormat(let name):
            return "Fixture has invalid format: \(name).json"
        }
    }
}

// MARK: - Bundle Marker

/// Private class to get the test bundle
private class FixturesBundleMarker {}

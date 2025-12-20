import Foundation

/// Phone normalization helper for E.164 format compliance
/// Defaults to Spanish country code (+34) when not provided
enum PhoneNormalizationError: Error {
    case invalid
    case tooShort
    case tooLong
    
    var userMessage: String {
        switch self {
        case .invalid:
            return "Please enter a valid phone number in international format, e.g. +34660580637"
        case .tooShort:
            return "Phone number is too short. Include country code (e.g., +34660580637)"
        case .tooLong:
            return "Phone number is too long. Max 15 digits after +"
        }
    }
}

struct PhoneNormalizer {
    /// Normalize phone input to E.164 format
    /// - Accepts: "660 580 637", "660580637", "+34 660 580 637", "+34660580637"
    /// - Returns: "+34660580637" (E.164 format)
    /// - Throws: PhoneNormalizationError if invalid
    static func normalizeToE164(rawInput: String, defaultCountryCode: String = "34") throws -> String {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        var digits = trimmed.filter(\.isNumber)
        
        // Handle international prefix like 00
        if trimmed.hasPrefix("00"), digits.count > 2 {
            digits = String(digits.dropFirst(2))
        } else if !trimmed.hasPrefix("+") && !digits.hasPrefix(defaultCountryCode) {
            digits = defaultCountryCode + digits
        }
        
        guard digits.count >= 7 else {
            throw PhoneNormalizationError.tooShort
        }
        guard digits.count <= 15 else {
            throw PhoneNormalizationError.tooLong
        }
        
        let e164 = "+" + digits
        
        // Validate against E.164 regex: +[1-9]d{1,14}
        let regex = try! NSRegularExpression(pattern: #"^\+[1-9]\d{1,14}$"#)
        let range = NSRange(location: 0, length: e164.utf16.count)
        
        guard regex.firstMatch(in: e164, options: [], range: range) != nil else {
            throw PhoneNormalizationError.invalid
        }
        
        return e164
    }
    
    /// Validate if a string is already in E.164 format
    static func isValidE164(_ phone: String) -> Bool {
        let regex = try! NSRegularExpression(pattern: #"^\+[1-9]\d{1,14}$"#)
        let range = NSRange(location: 0, length: phone.utf16.count)
        return regex.firstMatch(in: phone, options: [], range: range) != nil
    }
}

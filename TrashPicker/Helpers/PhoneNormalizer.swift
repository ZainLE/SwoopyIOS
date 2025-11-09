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
        // Extract only digits
        let digits = rawInput.filter(\.isNumber)
        
        // Minimum 9 digits for valid phone number
        guard digits.count >= 9 else {
            throw PhoneNormalizationError.tooShort
        }
        
        // Build with country code if not present
        let withCountry: String
        if digits.hasPrefix(defaultCountryCode) {
            // Already has country code
            withCountry = digits
        } else {
            // Prepend default country code
            withCountry = defaultCountryCode + digits
        }
        
        // Format as E.164: +{country code}{number}
        let e164 = "+" + withCountry
        
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

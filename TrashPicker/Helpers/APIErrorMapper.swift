import Foundation

/// Maps HTTP responses to user-friendly error messages, preventing raw HTML from appearing in UI
struct APIErrorMapper {
    /// Extracts a friendly error message from an HTTP response
    /// - Parameters:
    ///   - http: The HTTP response
    ///   - data: The response body data
    /// - Returns: A user-friendly error message
    static func friendlyMessage(http: HTTPURLResponse, data: Data) -> String {
        // Try to parse JSON error first
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("application/json") {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Try common error field names
                if let msg = obj["error"] as? String, !msg.isEmpty {
                    return msg
                }
                if let msg = obj["message"] as? String, !msg.isEmpty {
                    return msg
                }
                if let msg = obj["details"] as? String, !msg.isEmpty {
                    return msg
                }
            }
        }
        
        // Check if response is HTML (common for proxy/gateway errors)
        let body = String(data: data, encoding: .utf8) ?? ""
        let isHTML = body.lowercased().contains("<html") || body.lowercased().contains("<!doctype")
        
        if isHTML {
            // Map common HTML error responses to friendly messages
            switch http.statusCode {
            case 404:
                return "Server endpoint not found. Check app path configuration."
            case 502, 503:
                return "Server temporarily unavailable. Please retry."
            case 401:
                return "Authentication failed. Please sign in again."
            default:
                return "Unexpected server response."
            }
        }
        
        // For non-HTML errors, check if body has useful text
        if !body.isEmpty && body.count < 200 && !body.contains("{") && !body.contains("<") {
            return body
        }
        
        // Fallback to status code message
        switch http.statusCode {
        case 400:
            return "Invalid request data."
        case 401:
            return "Authentication required."
        case 403:
            return "Access denied."
        case 404:
            return "Endpoint not found."
        case 413:
            return "Image must be under 5 MB."
        case 429:
            return "Too many attempts. Please try again shortly."
        case 500...599:
            return "Server error. Please try again later."
        default:
            return "Request failed with status \(http.statusCode)."
        }
    }
}

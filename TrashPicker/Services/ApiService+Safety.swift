//
//  ApiService+Safety.swift
//  TrashPicker
//
//  Safety & moderation API stubs (frontend-only until backend ready)
//

import Foundation

extension ApiService {
    struct ReportResponse: Decodable {
        let ok: Bool
        let reportId: String?

        enum CodingKeys: String, CodingKey {
            case ok
            case reportId = "report_id"
        }
    }

    /// Current authenticated user ID for safety flows
    func currentUserIdForSafety() async -> String? {
        await MainActor.run { supabaseService.userId?.uuidString }
    }

    /// Report a post for violating community guidelines
    /// - Parameter postId: Identifier of the post being reported
    /// - Returns: ReportResponse containing backend report ID
    @MainActor
    func reportPost(postId: String, category: ReportPayload.Category, notes: String?) async throws -> ReportResponse {
        let url = try resolvedURL(for: "/report/post/\(postId)")
        var request = URLRequest(url: url)
        request.httpMethod = HTTPMethod.POST.rawValue

        let headers = try await getAuthHeaders()
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        var body: [String: Any] = ["category": category.rawValue]
        if let notes, !notes.isEmpty { body["notes"] = notes }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ApiServiceError.unknownError
        }

        switch http.statusCode {
        case 200...299:
            let decoder = JSONDecoder()
            return try decoder.decode(ReportResponse.self, from: data)
        case 401:
            throw ApiServiceError.unauthorized
        case 400:
            let message = extractErrorMessage(from: data) ?? "Couldn't submit report"
            throw ApiServiceError.serverError(message)
        default:
            let message = extractErrorMessage(from: data) ?? "Client error"
            throw ApiServiceError.serverError("HTTP \(http.statusCode): \(message)")
        }
    }
    
    /// Report a user for violating community guidelines
    /// - Parameter userId: Identifier of the user being reported
    /// - Returns: ReportResponse containing backend report ID
    @MainActor
    func reportUser(userId: String, category: ReportPayload.Category, notes: String?) async throws -> ReportResponse {
        let url = try resolvedURL(for: "/report/user/\(userId)")
        var request = URLRequest(url: url)
        request.httpMethod = HTTPMethod.POST.rawValue

        let headers = try await getAuthHeaders()
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        var body: [String: Any] = ["category": category.rawValue]
        if let notes, !notes.isEmpty { body["notes"] = notes }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ApiServiceError.unknownError
        }

        switch http.statusCode {
        case 200...299:
            let decoder = JSONDecoder()
            return try decoder.decode(ReportResponse.self, from: data)
        case 401:
            throw ApiServiceError.unauthorized
        case 400:
            let message = extractErrorMessage(from: data) ?? "Couldn't submit report"
            throw ApiServiceError.serverError(message)
        default:
            let message = extractErrorMessage(from: data) ?? "Client error"
            throw ApiServiceError.serverError("HTTP \(http.statusCode): \(message)")
        }
    }
    
    /// Block a user from interacting with you
    /// - Parameter userId: User identifier to block
    /// - Throws: ApiServiceError on network failure
    @MainActor
    func blockUser(userId: String) async throws {
        let url = try resolvedURL(for: "/block/\(userId)")
        var request = URLRequest(url: url)
        request.httpMethod = HTTPMethod.POST.rawValue
        let headers = try await getAuthHeaders()
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ApiServiceError.unknownError }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw ApiServiceError.unauthorized
        case 400:
            throw ApiServiceError.serverError("Couldn't block user")
        default:
            throw ApiServiceError.serverError("HTTP \(http.statusCode)")
        }
    }
    
    /// Unblock a previously blocked user
    /// - Parameter userId: The user ID to unblock
    /// - Throws: ApiServiceError on network failure
    @MainActor
    func unblockUser(userId: String) async throws {
        let url = try resolvedURL(for: "/block/\(userId)")
        var request = URLRequest(url: url)
        request.httpMethod = HTTPMethod.DELETE.rawValue
        let headers = try await getAuthHeaders()
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ApiServiceError.unknownError }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw ApiServiceError.unauthorized
        case 400:
            throw ApiServiceError.serverError("Couldn't unblock user")
        default:
            throw ApiServiceError.serverError("HTTP \(http.statusCode)")
        }
    }

    /// Fetch list of blocked user IDs (optional backend support)
    @MainActor
    func fetchMyBlocks() async throws -> [String] {
        let url = try resolvedURL(for: "/me/blocks")
        var request = URLRequest(url: url)
        request.httpMethod = HTTPMethod.GET.rawValue
        let headers = try await getAuthHeaders()
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ApiServiceError.unknownError }

        switch http.statusCode {
        case 200...299:
            // Server returns [{user_id, name, avatar_url}]
            struct BlockEntry: Decodable {
                let userId: String
                enum CodingKeys: String, CodingKey { case userId = "user_id" }
            }
            if let entries = try? JSONDecoder().decode([BlockEntry].self, from: data) {
                return entries.map(\.userId)
            }
            // Fallback: plain string array
            if let ids = try? JSONDecoder().decode([String].self, from: data) {
                return ids
            }
            return []
        case 401:
            throw ApiServiceError.unauthorized
        default:
            return []
        }
    }
}

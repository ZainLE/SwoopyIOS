import Foundation

struct ReportProblemContext {
    let userId: String
    let email: String
    let appVersion: String
    let deviceModel: String
    let osVersion: String
}

struct ReportProblemPayload: Codable {
    let userId: String
    let email: String
    let appVersion: String
    let deviceModel: String
    let osVersion: String
    let category: String
    let message: String
    let hasScreenshot: Bool
    let screenshotBase64: String?
    let createdAt: Date
}

enum ReportProblemError: Error, LocalizedError {
    case submitFailed

    var errorDescription: String? {
        switch self {
        case .submitFailed:
            return "Couldn't send your report. Please try again."
        }
    }
}

enum ReportProblemService {
    static func submit(payload: ReportProblemPayload) async throws {
        // Placeholder: simulate latency. Replace with Supabase call or email dispatch.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        // For now, treat all submissions as successful.
    }
}

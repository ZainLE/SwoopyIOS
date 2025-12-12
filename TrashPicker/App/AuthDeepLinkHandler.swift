import Foundation

enum AuthDeepLinkHandler {
    static func handle(_ url: URL) {
        guard
            url.scheme == "swoopy",
            url.host == "auth",
            url.path == "/callback"
        else { return }

        let fragment = url.fragment ?? ""
        let params = fragment
            .split(separator: "&")
            .reduce(into: [String: String]()) { dict, pair in
                let parts = pair.split(separator: "=")
                if parts.count == 2 {
                    dict[String(parts[0])] = String(parts[1])
                }
            }

        if params["type"] == "recovery" {
            DispatchQueue.main.async {
                AppState.shared.authFlow = .resetPassword
            }
        }
    }
}

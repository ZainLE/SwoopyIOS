import Foundation
import Combine

@MainActor
final class HiddenContentStore: ObservableObject {
    static let shared = HiddenContentStore()

    @Published var hideReportedContent: Bool {
        didSet { persistPreferences() }
    }

    @Published private(set) var hiddenPostIds: Set<String> = []

    private let hiddenKey = "hidden_post_ids"
    private let hidePreferenceKey = "hide_reported_content_enabled"

    private init() {
        let stored = UserDefaults.standard.array(forKey: hiddenKey) as? [String] ?? []
        hiddenPostIds = Set(stored)
        let pref = UserDefaults.standard.object(forKey: hidePreferenceKey) as? Bool
        hideReportedContent = pref ?? true
    }

    func add(postId: String) {
        guard !postId.isEmpty else { return }
        if hiddenPostIds.insert(postId).inserted {
            persistHidden()
        }
    }

    func remove(postId: String) {
        if hiddenPostIds.remove(postId) != nil {
            persistHidden()
        }
    }

    func clear() {
        hiddenPostIds.removeAll()
        persistHidden()
    }

    func shouldHide(post: Post, isBlocked: Bool) -> Bool {
        if isBlocked { return true }
        guard hideReportedContent else { return false }
        return hiddenPostIds.contains(post.id)
    }

    private func persistHidden() {
        UserDefaults.standard.set(Array(hiddenPostIds), forKey: hiddenKey)
    }

    private func persistPreferences() {
        UserDefaults.standard.set(hideReportedContent, forKey: hidePreferenceKey)
    }
}

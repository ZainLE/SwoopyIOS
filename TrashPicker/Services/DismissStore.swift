import Foundation

final class DismissStore {
    static let shared = DismissStore()
    private init() {}
    
    private func key(for userId: String) -> String { "dismissed.\(userId)" }
    
    func load(for userId: String) -> Set<String> {
        let k = key(for: userId)
        return Set(UserDefaults.standard.stringArray(forKey: k) ?? [])
    }
    
    func save(_ set: Set<String>, for userId: String) {
        UserDefaults.standard.set(Array(set), forKey: key(for: userId))
    }
}

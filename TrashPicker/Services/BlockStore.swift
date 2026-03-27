import Foundation
import Combine

@MainActor
final class BlockStore: ObservableObject {
    static let shared = BlockStore()

    @Published private(set) var blockedIds: Set<UUID> = []

    private let storageKey = "blocked_user_ids"
    private weak var api: ApiService?
    private var isFetching = false

    private init() {
        blockedIds = Self.loadPersisted()
    }

    func configure(api: ApiService) {
        self.api = api
        Task { await fetchRemoteIfPossible() }
    }

    func isBlocked(_ userId: String?) -> Bool {
        guard let userId, let uuid = UUID(uuidString: userId) else { return false }
        return blockedIds.contains(uuid)
    }

    func block(userId: String) async throws {
        guard let api else { return }
        addLocal(userId: userId)
        do {
            async let blockCall: Void = api.blockUser(userId: userId)
            async let reportCall = api.reportUser(userId: userId)
            _ = try await (blockCall, reportCall)
        } catch {
            #if DEBUG
            DLog("[BLOCK] block_fail user=\(userId) err=\(error.localizedDescription)")
            #endif
            throw error
        }
    }

    func unblock(userId: String) async {
        guard let api else { return }
        do {
            try await api.unblockUser(userId: userId)
            removeLocal(userId: userId)
        } catch {
            #if DEBUG
            DLog("[BLOCK] unblock_fail user=\(userId) err=\(error.localizedDescription)")
            #endif
        }
    }

    func addLocal(userId: String) {
        guard let uuid = UUID(uuidString: userId) else { return }
        if blockedIds.insert(uuid).inserted {
            persist()
        }
    }

    func removeLocal(userId: String) {
        guard let uuid = UUID(uuidString: userId) else { return }
        if blockedIds.remove(uuid) != nil {
            persist()
        }
    }

    private func fetchRemoteIfPossible() async {
        guard !isFetching, let api else { return }
        isFetching = true
        defer { isFetching = false }
        do {
            let ids = try await api.fetchMyBlocks()
            let uuids = ids.compactMap(UUID.init)
            if !uuids.isEmpty {
                blockedIds = Set(uuids)
                persist()
            }
        } catch {
            // Ignore remote failure; keep local cache
        }
    }

    private func persist() {
        let strings = blockedIds.map { $0.uuidString }
        UserDefaults.standard.set(strings, forKey: storageKey)
    }

    private static func loadPersisted() -> Set<UUID> {
        guard let stored = UserDefaults.standard.array(forKey: "blocked_user_ids") as? [String] else {
            return []
        }
        return Set(stored.compactMap(UUID.init))
    }
}

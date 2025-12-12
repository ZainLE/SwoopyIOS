import Foundation
import CoreLocation
import Combine

@MainActor
final class FeedViewModel: ObservableObject {
    // MARK: - Published State
    @Published var items: [Post] = []
    @Published var isLoading: Bool = false
    @Published var lastError: Error? = nil
    
    // MARK: - Private State
    private let api: ApiService
    private var currentTask: Task<Void, Never>?
    private var lastRefreshLocation: CLLocationCoordinate2D?
    private var lastRefreshRadius: Double = 10.0
    private let coalescer = FeedCoalescer()
    private let blockStore = BlockStore.shared
    private let hiddenStore = HiddenContentStore.shared
    private var cancellables: Set<AnyCancellable> = []
    private var baseItems: [Post] = []
    
    // MARK: - Notification Name
    static let feedDidChangeNotification = Notification.Name("FeedDidChange")
    
    init(api: ApiService) {
        self.api = api
        blockStore.configure(api: api)
        setupNotificationObserver()
        blockStore.$blockedIds
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyBlockFilter()
            }
            .store(in: &cancellables)
        hiddenStore.$hiddenPostIds
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyBlockFilter()
            }
            .store(in: &cancellables)
        hiddenStore.$hideReportedContent
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyBlockFilter()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public API
    
    /// Refresh feed with debouncing and concurrency control
    func refresh(currentLocation: CLLocationCoordinate2D, radiusKm: Double = 10.0) {
        // Cancel any in-flight request
        currentTask?.cancel()
        
        // Skip if location and radius haven't changed significantly
        if let lastLoc = lastRefreshLocation,
           abs(lastLoc.latitude - currentLocation.latitude) < 0.001,
           abs(lastLoc.longitude - currentLocation.longitude) < 0.001,
           abs(lastRefreshRadius - radiusKm) < 0.1 {
            return
        }
        
        currentTask = Task {
            await performRefresh(location: currentLocation, radiusKm: radiusKm)
        }
    }
    
    /// Force refresh regardless of location similarity (for post-upload triggers)
    func forceRefresh(currentLocation: CLLocationCoordinate2D, radiusKm: Double = 10.0) {
        currentTask?.cancel()
        currentTask = Task {
            await performRefresh(location: currentLocation, radiusKm: radiusKm)
        }
    }
    
    // MARK: - Private Methods
    
    private func performRefresh(location: CLLocationCoordinate2D, radiusKm: Double) async {
        isLoading = true
        lastError = nil
        
        do {
            let query = FeedQuery(
                lng: location.longitude,
                lat: location.latitude,
                radiusKm: radiusKm,
                category: nil,
                mode: nil,
                limit: 50,
                excludeSelf: true
            )
            
            let key = FeedQueryKey(
                coordinate: location,
                radiusKm: radiusKm,
                limit: query.limit,
                excludeSelf: query.excludeSelf,
                mode: query.mode,
                category: query.category
            )
            
            let fetchedItems = try await coalescer.runOnce(key: key) {
                try await self.api.getFeed(query: query)
            }
            
            // Only update if this task wasn't cancelled
            guard !Task.isCancelled else { return }
            
            baseItems = fetchedItems
            applyBlockFilter()
            lastRefreshLocation = location
            lastRefreshRadius = radiusKm
            
        } catch {
            guard !Task.isCancelled else { return }
            lastError = error
        }
        
        isLoading = false
    }
    
    private func setupNotificationObserver() {
        NotificationCenter.default.addObserver(
            forName: Self.feedDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self,
                  let lastLoc = self.lastRefreshLocation else { return }
            self.forceRefresh(currentLocation: lastLoc, radiusKm: self.lastRefreshRadius)
        }
    }
    
    deinit {
        currentTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        cancellables.forEach { $0.cancel() }
    }

    private func applyBlockFilter() {
        let filtered = baseItems.filter { post in
            let blockedOwner = blockStore.isBlocked(post.ownerId)
            let hidden = hiddenStore.shouldHide(post: post, isBlocked: blockedOwner)
            return !hidden
        }
        if filtered != items {
            items = filtered
        }
    }
}

// MARK: - Convenience Extensions

extension FeedViewModel {
    /// Trigger feed refresh from anywhere in the app
    static func requestFeedRefresh() {
        NotificationCenter.default.post(name: feedDidChangeNotification, object: nil)
    }
}

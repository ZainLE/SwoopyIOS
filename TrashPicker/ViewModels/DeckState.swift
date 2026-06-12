//
//  DeckState.swift
//  TrashPicker
//
//  Single source of truth for deck state management
//

import SwiftUI
import CloudKit

@MainActor
class DeckState: ObservableObject {
    @Published var items: [Any] = []
    @Published var activeIndex: Int = 0
    @Published var isAnimating: Bool = false
    @Published var isActing: Bool = false
    @Published var errorMessage: String?
    /// Direction the active card is exiting in, so the card view can run the
    /// fly-off animation even when the action came from a button tap.
    @Published var exitDirection: TransitionDirection?
    
    // Computed properties
    var hasCards: Bool { !items.isEmpty }
    var canAct: Bool { hasCards && !isAnimating && !isActing }
    var activeCard: Any? { 
        guard activeIndex < items.count else { return nil }
        return items[activeIndex] 
    }
    var nextCard: Any? {
        let nextIndex = activeIndex + 1
        guard nextIndex < items.count else { return nil }
        return items[nextIndex]
    }
    
    // MARK: - Public Actions
    
    func updateItems<T>(_ newItems: [T]) {
        items = newItems
        activeIndex = 0
        isAnimating = false
        isActing = false
    }

    /// Update items while preserving the current card position (for filter updates, not full reloads).
    func filterItems<T: Identifiable>(_ newItems: [T]) where T.ID: Equatable {
        let typedCurrent = items as? [T]
        let currentId: T.ID? = (typedCurrent != nil && activeIndex < (typedCurrent?.count ?? 0))
            ? typedCurrent?[activeIndex].id
            : nil
        items = newItems
        if let id = currentId, let newIndex = newItems.firstIndex(where: { $0.id == id }) {
            activeIndex = newIndex
        } else {
            activeIndex = min(activeIndex, max(0, newItems.count - 1))
        }
    }
    
    /// Matches the 0.3s fly-off animation in FeedCard's drag gesture; we advance
    /// just before the gesture's dragOffset reset fires so the old card view is
    /// gone before it could snap back to center.
    private let cardExitDuration: UInt64 = 280_000_000

    func triggerPass() async {
        await triggerAdvance(direction: .left)
    }

    func triggerReserve() async {
        await triggerAdvance(direction: .right)
    }

    private func triggerAdvance(direction: TransitionDirection) async {
        guard canAct, activeCard != nil else { return }

        isActing = true
        defer { isActing = false }

        // Keep the next card staged (visible) while the active card flies off.
        await startCardTransition(direction: direction)
        try? await Task.sleep(nanoseconds: cardExitDuration)

        // Remove card and advance
        advanceToNextCard()
    }

    // MARK: - Internal State Management

    @MainActor
    private func startCardTransition(direction: TransitionDirection) async {
        exitDirection = direction
        isAnimating = true

        // Animation will be handled by the view layer
        // This just manages the state flags
    }

    @MainActor
    func completeCardTransition() {
        isAnimating = false
        exitDirection = nil
    }
    
    @MainActor
    func advanceToNextCard() {
        guard activeIndex < items.count else { return }
        
        // Remove the current card
        items.remove(at: activeIndex)
        
        // Keep activeIndex the same (it now points to what was the next card)
        // Unless we're at the end, then we need to go back
        if activeIndex >= items.count && !items.isEmpty {
            activeIndex = items.count - 1
        }

        isAnimating = false
        exitDirection = nil
    }
    
    @MainActor
    private func handleError(_ message: String) {
        errorMessage = message
        isAnimating = false
        isActing = false
        
        // Clear error after 3 seconds
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            errorMessage = nil
        }
    }
    
    // MARK: - Supporting Types
    
    enum TransitionDirection {
        case left, right
    }
}

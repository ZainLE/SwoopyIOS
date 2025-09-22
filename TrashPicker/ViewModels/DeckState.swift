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
    @Published var items: [CKTrashItem] = []
    @Published var activeIndex: Int = 0
    @Published var isAnimating: Bool = false
    @Published var isActing: Bool = false
    @Published var errorMessage: String?
    
    // Computed properties
    var hasCards: Bool { !items.isEmpty }
    var canAct: Bool { hasCards && !isAnimating && !isActing }
    var activeCard: CKTrashItem? { 
        guard activeIndex < items.count else { return nil }
        return items[activeIndex] 
    }
    var nextCard: CKTrashItem? {
        let nextIndex = activeIndex + 1
        guard nextIndex < items.count else { return nil }
        return items[nextIndex]
    }
    
    // MARK: - Public Actions
    
    func updateItems(_ newItems: [CKTrashItem]) {
        items = newItems
        activeIndex = 0
        isAnimating = false
        isActing = false
    }
    
    func triggerPass() async {
        guard canAct, let card = activeCard else { return }
        
        isActing = true
        defer { isActing = false }
        
        do {
            // Start animation
            await startCardTransition(direction: .left)
            
            // Remove card and advance
            await advanceToNextCard()
            
        } catch {
            await handleError("Failed to pass item")
        }
    }
    
    func triggerReserve() async throws {
        guard canAct, let card = activeCard else { return }
        
        isActing = true
        
        do {
            // Start animation
            await startCardTransition(direction: .right)
            
            // The actual reservation will be handled by the parent view
            // This just manages the UI state transition
            
        } catch {
            await handleError("Failed to reserve item")
            isActing = false
            throw error
        }
    }
    
    // MARK: - Internal State Management
    
    @MainActor
    private func startCardTransition(direction: TransitionDirection) async {
        isAnimating = true
        
        // Animation will be handled by the view layer
        // This just manages the state flags
    }
    
    @MainActor
    func completeCardTransition() {
        isAnimating = false
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

import SwiftUI

/// Swipe-left-to-delete for card rows living in a ScrollView/LazyVStack, where
/// List's native swipeActions is unavailable. Dragging left reveals a Delete
/// button behind the card; a long full swipe deletes immediately.
struct SwipeToDeleteRow<Content: View>: View {
    let cornerRadius: CGFloat
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var offsetX: CGFloat = 0
    @State private var isOpen = false

    private let revealWidth: CGFloat = 92
    private let fullSwipeThreshold: CGFloat = 220

    var body: some View {
        ZStack(alignment: .trailing) {
            deleteBackdrop

            content()
                .offset(x: offsetX)
                .overlay {
                    // While the delete button is revealed, a tap anywhere on the
                    // card closes it instead of triggering the row's own tap.
                    if isOpen {
                        Color.clear
                            .contentShape(Rectangle())
                            .offset(x: offsetX)
                            .onTapGesture { close() }
                    }
                }
                .gesture(dragGesture)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: offsetX)
    }

    private var deleteBackdrop: some View {
        Button {
            Haptics.play(.swipePass)
            performDelete()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .semibold))
                Text("Delete")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(width: revealWidth)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.red)
            )
        }
        .buttonStyle(.plain)
        .opacity(offsetX < -1 ? 1 : 0)
        .accessibilityLabel("Delete notification")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onChanged { value in
                // Only claim horizontal-dominant drags; leave scrolling alone.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let base: CGFloat = isOpen ? -revealWidth : 0
                let proposed = base + value.translation.width
                // Follow leftward pulls; never push the card rightward.
                offsetX = min(0, proposed)
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    offsetX = isOpen ? -revealWidth : 0
                    return
                }
                if offsetX < -fullSwipeThreshold {
                    Haptics.play(.swipePass)
                    performDelete()
                } else if offsetX < -revealWidth * 0.55 {
                    isOpen = true
                    offsetX = -revealWidth
                } else {
                    close()
                }
            }
    }

    private func close() {
        isOpen = false
        offsetX = 0
    }

    private func performDelete() {
        isOpen = false
        offsetX = 0
        onDelete()
    }
}

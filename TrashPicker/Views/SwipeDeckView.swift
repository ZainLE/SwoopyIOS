//This was the previous working one with all the CTA before changes
import SwiftUI
import MapKit
import CloudKit

struct SwipeDeckView: View {
    @EnvironmentObject var ck: CKTrashService

    @State private var hidden: Set<CKRecord.ID> = []

    // reserve sheet (two-step)
    @State private var showReserveSheet = false
    @State private var sheetMode: ReserveSheet.Mode = .prompt
    @State private var sheetItem: TrashDTO?

    private var visible: [TrashDTO] {
        ck.feed.filter { !hidden.contains($0.id) && !ck.isMine($0) }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let maxWidth  = geo.size.width - 32
                let cardWidth = min(maxWidth, 420)
                let idealH    = cardWidth * 1.25   // 4:5 style
                let cardHeight = min(idealH, geo.size.height - 180)

                ZStack {
                    if visible.isEmpty {
                        EmptyFeedCTA(
                            refresh: { Task { await ck.fetchFeed() } },
                            makePost: {
                                // handled by NavigationLink provided below
                            }
                        )
                        .padding(.horizontal, 20)
                        // Floating camera shortcut (also visible on empty)
                        .overlay(alignment: .topTrailing) {
                            NavigationLink {
                                AddTrashView()
                                    .environmentObject(ck)
                                    .environmentObject(LocationManager())
                            } label: {
                                Image(systemName: "camera")
                                    .font(.title3)
                                    .padding(12)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .overlay(Circle().stroke(.white.opacity(0.25)))
                                    .shadow(radius: 5)
                            }
                            .padding(.trailing, 20)
                            .padding(.top, 8)
                        }
                    } else {
                        DeckStack(
                            items: Array(visible.prefix(3)),
                            width: cardWidth,
                            height: cardHeight,
                            onSwipe: { item, dir in
                                if dir == .right {
                                    // Step 1: show prompt (no map yet)
                                    sheetItem = item
                                    sheetMode = .prompt
                                    withAnimation(.easeOut(duration: 0.18)) { showReserveSheet = true }
                                } else {
                                    hidden.insert(item.id)
                                }
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        // Floating camera button
                        .overlay(alignment: .topTrailing) {
                            NavigationLink {
                                AddTrashView()
                                    .environmentObject(ck)
                                    .environmentObject(LocationManager())
                            } label: {
                                Image(systemName: "camera")
                                    .font(.title3)
                                    .padding(12)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .overlay(Circle().stroke(.white.opacity(0.25)))
                                    .shadow(radius: 5)
                            }
                            .padding(.trailing, 20)
                            .padding(.top, 8)
                        }
                    }

                    // Reservation sheet
                    if showReserveSheet, let item = sheetItem {
                        ReserveSheet(
                            mode: sheetMode,
                            item: item,
                            confirm: {
                                Task {
                                    try? await ck.reserve(item)
                                    await ck.fetchFeed()
                                    withAnimation(.easeOut(duration: 0.18)) { sheetMode = .info }
                                }
                            },
                            openMaps: {
                                let mi = MKMapItem(placemark: MKPlacemark(coordinate: item.coordinate))
                                mi.name = item.title
                                mi.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit])
                            },
                            close: {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    showReserveSheet = false
                                    sheetMode = .prompt
                                }
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
            }
            .navigationTitle("Feed")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await ck.fetchFeed()
                for i in ck.feed { await ck.releaseIfReservationExpired(i); await ck.expireIfPast24h(i) }
                await ck.fetchFeed()
            }
        }
    }
}

//
// MARK: - Empty State CTA
//

private struct EmptyFeedCTA: View {
    var refresh: () -> Void
    var makePost: () -> Void

    @State private var pulse = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.green.opacity(0.25), .blue.opacity(0.25)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 160, height: 160)
                    .scaleEffect(pulse ? 1.05 : 0.95)
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)

                Image(systemName: "leaf.circle.fill")
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(.green, .white)
                    .shadow(radius: 4)
            }
            .onAppear { pulse = true }

            Text("You’re all caught up")
                .font(.title3.weight(.semibold))

            Text("No nearby trash right now.\nGot something to give away?")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                NavigationLink {
                    // Provide Add flow here as well
                    AddTrashView()
                        .environmentObject(CKTrashService.shared)
                        .environmentObject(LocationManager())
                } label: {
                    Label("Make a post", systemImage: "camera.fill")
                }
                .buttonStyle(.borderedProminent)

                Button(action: refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

//
// MARK: - Stack of up to 3 cards
//

private struct DeckStack: View {
    let items: [TrashDTO]
    let width: CGFloat
    let height: CGFloat
    var onSwipe: (TrashDTO, SwipeCard.Direction) -> Void

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                SwipeCard(item: item, width: width, height: height) { dir in
                    onSwipe(item, dir)
                }
                .zIndex(Double(100 - idx))
                .scaleEffect(1 - CGFloat(idx) * 0.03)
                .offset(y: CGFloat(idx) * 14)
                .transition(.asymmetric(
                    insertion: .scale.combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: items.map(\.id))
    }
}

//
// MARK: - Single swipeable card
//

private struct SwipeCard: View {
    enum Direction { case left, right }

    let item: TrashDTO
    let width: CGFloat
    let height: CGFloat
    var onSwipe: (Direction) -> Void

    @State private var drag: CGSize = .zero
    @State private var dragging = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(.systemBackground))
                .frame(width: width, height: height)
                .shadow(color: .black.opacity(0.10), radius: 8, y: 5)

            if let url = item.photoURL {
                DownsampledImage(url: url, maxDimension: max(width, height))
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 22))
            } else {
                RoundedRectangle(cornerRadius: 22)
                    .fill(.secondary.opacity(0.15))
                    .frame(width: width, height: height)
            }

            // Title/time with subtle top gradient
            VStack {
                HStack {
                    Text(item.title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .shadow(radius: 2)
                    Spacer()
                    Text(item.createdAt, style: .time)
                        .font(.caption)
                        .opacity(0.95)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .foregroundStyle(.white)
                .background(
                    LinearGradient(colors: [Color.black.opacity(0.45), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 70)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .frame(maxHeight: .infinity, alignment: .top)
                )
                Spacer()
            }
            .frame(width: width, height: height)

            // Bottom chips + actions
            VStack(spacing: 10) {
                Spacer()
                HStack {
                    Label(item.city, systemImage: "mappin.and.ellipse")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                        .foregroundStyle(.white)

                    Spacer()

                    Text("Interested: \(item.interestedCount)")
                        .font(.caption2).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                        .foregroundStyle(.white)
                }
                HStack {
                    ActionCircle(system: "xmark") { swipe(.left) }
                    Spacer()
                    ActionCircle(system: "heart.fill") { swipe(.right) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .frame(width: width, height: height)
        }
        .offset(drag)
        .rotationEffect(.degrees(Double(drag.width / 18)))
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { v in dragging = true; drag = v.translation }
                .onEnded { v in
                    dragging = false
                    let t: CGFloat = 115
                    if v.translation.width > t { swipe(.right) }
                    else if v.translation.width < -t { swipe(.left) }
                    else { withAnimation(.easeOut(duration: 0.18)) { drag = .zero } }
                }
        )
        .animation(.easeOut(duration: 0.18), value: drag)
    }

    private func swipe(_ dir: Direction) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeOut(duration: 0.18)) {
            drag = CGSize(width: dir == .right ? 900 : -900, height: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { onSwipe(dir) }
    }
}

private struct ActionCircle: View {
    let system: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.title2.weight(.semibold))
                .frame(width: 56, height: 56)
                .background(Color.white.opacity(0.96))
                .foregroundStyle(.black)
                .clipShape(Circle())
                .shadow(radius: 4)
        }
    }
}

//
// MARK: - Reserve sheet (two-step)
//

private struct ReserveSheet: View {
    enum Mode { case prompt, info }
    let mode: Mode
    let item: TrashDTO
    var confirm: () -> Void
    var openMaps: () -> Void
    var close: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Capsule().fill(.secondary.opacity(0.35)).frame(width: 40, height: 4).padding(.top, 8)

            if mode == .prompt {
                Text("Reserve for the next 6 hours?").font(.headline)
                Text("Others won’t see this spot while it’s reserved.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("Not now", role: .cancel, action: close)
                    Spacer()
                    Button(action: confirm) {
                        Label("Reserve 6h", systemImage: "clock.badge.checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("Reserved until \(reservedUntilString(item))").font(.headline)
                HStack {
                    Label(item.city, systemImage: "mappin.circle")
                    Spacer()
                    Button(action: openMaps) { Label("Open in Maps", systemImage: "map") }
                        .buttonStyle(.bordered)
                }
                Button("Close", action: close).padding(.top, 6)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 16).padding(.bottom, 18)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func reservedUntilString(_ item: TrashDTO) -> String {
        if let u = item.reservedUntil, u > Date() { return u.formatted(date: .omitted, time: .shortened) }
        let u = Calendar.current.date(byAdding: .hour, value: 6, to: Date())!
        return u.formatted(date: .omitted, time: .shortened)
    }
}









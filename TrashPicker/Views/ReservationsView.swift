//
//  ReservationsView.swift
//  TrashPicker
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - Reservation Data Model

struct ReservationItem: Identifiable, Codable {
    let id: String
    let imageURL: String
    let condition: String
    let distanceKm: Double
    let swipedAt: Date
    let mode: String // "street" or "home"
    let exactLocation: CLLocationCoordinate2D? // Only for street mode
    let approxLocation: CLLocationCoordinate2D? // Only for home mode
    let reservationStatus: ReservationStatus
    let contactInfo: ContactInfo? // Only for home mode when confirmed
    
    enum ReservationStatus: String, Codable, CaseIterable {
        case active, canceled, picked, expired, pending // Added pending for home mode
    }
    
    struct ContactInfo: Codable {
        let phoneNumber: String? // Direct phone number for dialer
        let phone: String? // Legacy field
        let email: String?
        let chatLink: String?
    }
    
    // Computed properties
    var expiresAt: Date {
        Calendar.current.date(byAdding: .hour, value: 6, to: swipedAt) ?? swipedAt
    }
    
    var isExpired: Bool {
        Date() > expiresAt
    }
    
    var timeRemaining: TimeInterval {
        max(0, expiresAt.timeIntervalSinceNow)
    }
}

// MARK: - ReservationsView

struct ReservationsView: View {
    @EnvironmentObject var svc: SupabaseService
    @State private var reservations: [ReservationItem] = []
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    // App design tokens
    private let brandDark = Color(red: 0/255, green: 81/255, blue: 63/255)
    private let brandLime = Color(red: 180/255, green: 221/255, blue: 78/255)
    private let horizontalPadding: CGFloat = 16
    
    var body: some View {
        NavigationStack {
            Group {
                if activeReservations.isEmpty {
                    // Empty state
                    VStack {
                        Text("No active reservations yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Reservations list
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(activeReservations) { reservation in
                                ReservationCard(
                                    reservation: reservation,
                                    onPickUp: { confirmPickUp(reservation) },
                                    onCancel: { confirmCancel(reservation) },
                                    onDirections: { openDirections(reservation) },
                                    onContact: { showContact(reservation) }
                                )
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("Your reservations")
            .navigationBarTitleDisplayMode(.inline)
            .onReceive(timer) { _ in
                // Update timer and remove expired reservations
                removeExpiredReservations()
            }
            .task {
                await loadReservations()
            }
            .alert("Have you picked this up?", isPresented: $showPickUpConfirmation) {
                Button("Cancel", role: .cancel) {
                    selectedReservation = nil
                }
                Button("Picked up") {
                    handlePickUp()
                }
            }
            .alert("Cancel this reservation?", isPresented: $showCancelConfirmation) {
                Button("No", role: .cancel) {
                    selectedReservation = nil
                }
                Button("Yes, cancel", role: .destructive) {
                    handleCancel()
                }
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var activeReservations: [ReservationItem] {
        reservations.filter { reservation in
            // Include both street and home modes
            (reservation.mode == "street" || reservation.mode == "home") &&
            // Street: active and not expired, Home: pending or active
            (reservation.mode == "street" ? 
                (reservation.reservationStatus == .active && !reservation.isExpired) :
                (reservation.reservationStatus == .pending || reservation.reservationStatus == .active)
            ) &&
            // Exclude canceled, picked, expired
            ![.canceled, .picked, .expired].contains(reservation.reservationStatus)
        }
    }
    
    // MARK: - Actions
    
    private func loadReservations() async {
        // TODO: Load from backend
        // For now, using mock data that matches the spec
        await MainActor.run {
            reservations = createMockReservations()
        }
    }
    
    private func removeExpiredReservations() {
        let expiredIds = reservations.filter { $0.isExpired }.map { $0.id }
        if !expiredIds.isEmpty {
            reservations.removeAll { expiredIds.contains($0.id) }
            // TODO: Notify backend and return items to feed
        }
    }
    
    @State private var showPickUpConfirmation = false
    @State private var showCancelConfirmation = false
    @State private var selectedReservation: ReservationItem?
    
    private func confirmPickUp(_ reservation: ReservationItem) {
        selectedReservation = reservation
        showPickUpConfirmation = true
    }
    
    private func confirmCancel(_ reservation: ReservationItem) {
        selectedReservation = reservation
        showCancelConfirmation = true
    }
    
    private func handlePickUp() {
        guard let reservation = selectedReservation else { return }
        // TODO: PATCH/POST to backend: reservations/:id → status picked
        reservations.removeAll { $0.id == reservation.id }
        selectedReservation = nil
    }
    
    private func handleCancel() {
        guard let reservation = selectedReservation else { return }
        // TODO: PATCH/POST reservations/:id → status canceled; notify feed cache to reinsert item
        reservations.removeAll { $0.id == reservation.id }
        selectedReservation = nil
    }
    
    private func openDirections(_ reservation: ReservationItem) {
        let coordinate: CLLocationCoordinate2D
        if reservation.mode == "street", let exactLoc = reservation.exactLocation {
            coordinate = exactLoc
        } else if reservation.mode == "home", let approxLoc = reservation.approxLocation {
            coordinate = approxLoc
        } else {
            return // No valid coordinate
        }
        
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        mapItem.name = reservation.mode == "home" ? "Approximate Location" : "Pickup Location"
        mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
    
    private func showContact(_ reservation: ReservationItem) {
        // Open Phone dialer directly with the number
        guard let contactInfo = reservation.contactInfo,
              let phoneNumber = contactInfo.phoneNumber ?? contactInfo.phone else {
            return // No phone number available
        }
        
        // Clean phone number and open dialer
        let cleanNumber = phoneNumber.replacingOccurrences(of: " ", with: "")
        if let url = URL(string: "tel:\(cleanNumber)") {
            UIApplication.shared.open(url)
        }
    }
    
    // MARK: - Mock Data
    
    private func createMockReservations() -> [ReservationItem] {
        [
            // Street reservation
            ReservationItem(
                id: "1",
                imageURL: "https://picsum.photos/200/200?random=1",
                condition: "Usable",
                distanceKm: 0.8,
                swipedAt: Date().addingTimeInterval(-3600), // 1 hour ago
                mode: "street",
                exactLocation: CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686),
                approxLocation: nil,
                reservationStatus: .active,
                contactInfo: nil
            ),
            // Home reservation - pending
            ReservationItem(
                id: "2",
                imageURL: "https://picsum.photos/200/200?random=2",
                condition: "Good",
                distanceKm: 1.2,
                swipedAt: Date().addingTimeInterval(-7200), // 2 hours ago
                mode: "home",
                exactLocation: nil,
                approxLocation: CLLocationCoordinate2D(latitude: 41.3900, longitude: 2.1700),
                reservationStatus: .pending,
                contactInfo: nil
            ),
            // Home reservation - confirmed with contact
            ReservationItem(
                id: "3",
                imageURL: "https://picsum.photos/200/200?random=3",
                condition: "Like New",
                distanceKm: 2.1,
                swipedAt: Date().addingTimeInterval(-10800), // 3 hours ago
                mode: "home",
                exactLocation: nil,
                approxLocation: CLLocationCoordinate2D(latitude: 41.3850, longitude: 2.1650),
                reservationStatus: .active,
                contactInfo: ReservationItem.ContactInfo(
                    phoneNumber: "+34123456789",
                    phone: "+34 123 456 789",
                    email: "giver@example.com",
                    chatLink: nil
                )
            )
        ]
    }
}

// MARK: - ReservationCard

private struct ReservationCard: View {
    let reservation: ReservationItem
    let onPickUp: () -> Void
    let onCancel: () -> Void
    let onDirections: () -> Void
    let onContact: () -> Void
    
    @State private var timeRemaining: TimeInterval
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    // App design tokens
    private let brandDark = Color(red: 0/255, green: 81/255, blue: 63/255)
    private let brandLime = Color(red: 180/255, green: 221/255, blue: 78/255)
    private let cardHeight: CGFloat = 133
    private let imageSize: CGFloat = 85
    private let cornerRadius: CGFloat = 12 // Match app's card corner radius
    
    init(reservation: ReservationItem, onPickUp: @escaping () -> Void, onCancel: @escaping () -> Void, onDirections: @escaping () -> Void, onContact: @escaping () -> Void) {
        self.reservation = reservation
        self.onPickUp = onPickUp
        self.onCancel = onCancel
        self.onDirections = onDirections
        self.onContact = onContact
        self._timeRemaining = State(initialValue: reservation.timeRemaining)
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // First row: Image + Text content
            HStack(alignment: .top, spacing: 12) {
                // Left image tile
                AsyncImage(url: URL(string: reservation.imageURL)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                }
                .frame(width: imageSize, height: imageSize)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(brandDark.opacity(0.2), lineWidth: 1)
                )
                .accessibilityLabel("Item photo")
                
                // Right content column - aligned to image top
                VStack(alignment: .leading, spacing: 0) {
                    // Condition line - baseline aligns with image top
                    HStack(spacing: 6) {
                        Circle()
                            .fill(brandLime)
                            .frame(width: 6, height: 6)
                        
                        Text(reservation.condition)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(brandDark)
                        
                        Spacer()
                        
                        // Top-right muted label for home pending
                        if reservation.mode == "home" && reservation.reservationStatus == .pending {
                            Text("pending confirmation")
                                .font(.system(size: 8, weight: .regular))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2) // Fine-tune optical alignment with image top
                    
                    // Distance row - 6pt spacing below condition
                    Text(reservation.mode == "home" ? 
                        String(format: "≈ %.1f km away", reservation.distanceKm) :
                        String(format: "%.1f km away", reservation.distanceKm)
                    )
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(brandDark)
                    .padding(.top, 6)
                    
                    // Timer row (street only) - 6pt spacing below distance
                    if reservation.mode == "street" {
                        Text("Pickup in: \(formatTimeRemaining(timeRemaining))")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.red)
                            .padding(.top, 6)
                    }
                    
                    Spacer()
                }
            }
            
            // Second row: Buttons with different alignment per mode
            if reservation.mode == "street" {
                // Street mode: 3 buttons aligned exactly with image left edge
                HStack(spacing: 10) {
                    Button(action: onPickUp) {
                        Text("Pick up")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(height: 46)
                            .frame(minWidth: 80)
                            .padding(.horizontal, 16)
                    }
                    .background(brandDark)
                    .clipShape(Capsule())
                    .accessibilityLabel("Pick up")
                    
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(brandDark)
                            .frame(height: 46)
                            .frame(minWidth: 80)
                            .padding(.horizontal, 16)
                    }
                    .background(Color.clear)
                    .overlay(
                        Capsule()
                            .stroke(brandDark, lineWidth: 2)
                    )
                    .accessibilityLabel("Cancel")
                    
                    Button(action: onDirections) {
                        Text("Directions")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(brandDark)
                            .frame(height: 46)
                            .frame(minWidth: 80)
                            .padding(.horizontal, 16)
                    }
                    .background(brandLime)
                    .clipShape(Capsule())
                    .accessibilityLabel("Directions")
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
            } else if reservation.reservationStatus == .pending {
                // Home pending: 1 centered Cancel button
                HStack {
                    Spacer()
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(brandDark)
                            .frame(height: 46)
                            .frame(minWidth: 120)
                            .padding(.horizontal, 24)
                    }
                    .background(Color.clear)
                    .overlay(
                        Capsule()
                            .stroke(brandDark, lineWidth: 2)
                    )
                    .accessibilityLabel("Cancel")
                    Spacer()
                }
                
            } else if reservation.reservationStatus == .active {
                // Home confirmed: Contact + Cancel centered as a group
                HStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Button(action: onContact) {
                            Text("Contact")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(brandDark)
                                .frame(height: 46)
                                .frame(minWidth: 80)
                                .padding(.horizontal, 16)
                        }
                        .background(brandLime)
                        .clipShape(Capsule())
                        .accessibilityLabel("Contact")
                        
                        Button(action: onCancel) {
                            Text("Cancel")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(brandDark)
                                .frame(height: 46)
                                .frame(minWidth: 80)
                                .padding(.horizontal, 16)
                        }
                        .background(Color.clear)
                        .overlay(
                            Capsule()
                                .stroke(brandDark, lineWidth: 2)
                        )
                        .accessibilityLabel("Cancel")
                    }
                    Spacer()
                }
            }
        }
        .frame(height: cardHeight)
        .padding(16)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2) // Match app's card shadow
        .onReceive(timer) { _ in
            timeRemaining = reservation.timeRemaining
        }
    }
    
    private func formatTimeRemaining(_ timeInterval: TimeInterval) -> String {
        let hours = Int(timeInterval) / 3600
        let minutes = Int(timeInterval) % 3600 / 60
        return "\(hours)h \(minutes)m"
    }
}

// MARK: - CLLocationCoordinate2D Codable Extension

extension CLLocationCoordinate2D: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let latitude = try container.decode(Double.self, forKey: .latitude)
        let longitude = try container.decode(Double.self, forKey: .longitude)
        self.init(latitude: latitude, longitude: longitude)
    }
    
    private enum CodingKeys: String, CodingKey {
        case latitude, longitude
    }
}


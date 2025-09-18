//
//  ReservationsView.swift
//  TrashPicker
//

import SwiftUI
import MapKit

struct ReservationsView: View {
    @EnvironmentObject var svc: SupabaseService

    var body: some View {
        NavigationStack {
            Group {
                if svc.myReservations.isEmpty {
                    ContentUnavailableView(
                        "No reservations",
                        systemImage: "clock",
                        description: Text("Reserve an item from the Feed.")
                    )
                } else {
                    List(svc.myReservations) { item in
                        ReservationRow(item: item)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                    .listStyle(.plain)
                    .refreshable { await svc.fetchMyStuff() }
                }
            }
            .navigationTitle("Reservations")
            .task { await svc.fetchMyStuff() }
        }
    }

    private struct ReservationRow: View {
        @EnvironmentObject var svc: SupabaseService
        let item: TrashDTO
        @State private var showNoLocationAlert = false

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(item.title)
                        .font(.headline)
                    Spacer()
                    if let until = item.reservedUntil {
                        Text("⏱ \(until, style: .timer)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        Task { try? await svc.confirmPickup(item) }
                    } label: {
                        Label("Picked up", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        Task { await svc.cancelReservation(item) }
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        openMaps()
                    } label: {
                        Label("Map", systemImage: "map")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(item.mapCoordinate == nil)
                    .alert("No location available",
                           isPresented: $showNoLocationAlert) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(item.mode == "home"
                             ? "This item uses Home mode. The exact pin isn’t shown; contact is shared after approval."
                             : "Location is unavailable for this item.")
                    }
                }
            }
            .padding(.vertical, 6)
        }

        private func openMaps() {
            guard let coord = item.mapCoordinate else {
                showNoLocationAlert = true
                return
            }
            let mi = MKMapItem(placemark: MKPlacemark(coordinate: coord))
            mi.name = item.title
            mi.openInMaps()
        }
    }
}

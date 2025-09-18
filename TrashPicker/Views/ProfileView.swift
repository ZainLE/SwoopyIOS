//
//  ProfileView.swift
//  TrashPicker
//

import SwiftUI
import MapKit

struct ProfileView: View {
    @EnvironmentObject var svc: SupabaseService

    var body: some View {
        NavigationStack {
            List {
                // MARK: My uploads (24h)
                Section("My uploads (24h)") {
                    if svc.myUploads.isEmpty {
                        ContentUnavailableView(
                            "No uploads yet",
                            systemImage: "tray",
                            description: Text("Make a post from the Feed.")
                        )
                        .listRowInsets(.init())
                    } else {
                        ForEach(svc.myUploads) { item in
                            UploadRow(item: item)
                        }
                    }
                }

                // MARK: My reservations
                Section("My reservations") {
                    if svc.myReservations.isEmpty {
                        ContentUnavailableView(
                            "No reservations",
                            systemImage: "clock",
                            description: Text("Reserve an item from the Feed.")
                        )
                        .listRowInsets(.init())
                    } else {
                        ForEach(svc.myReservations) { item in
                            ReservationMini(item: item)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Profile")
            .task { await svc.fetchMyStuff() }
            .refreshable { await svc.fetchMyStuff() }
        }
    }

    // MARK: - Rows

    private struct UploadRow: View {
        let item: TrashDTO

        var body: some View {
            HStack(spacing: 12) {
                if let url = item.heroImageURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Color.gray.opacity(0.2)
                        case .empty:
                            ProgressView()
                        @unknown default:
                            Color.gray.opacity(0.2)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipped()
                    .cornerRadius(8)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.secondary.opacity(0.15))
                        .frame(width: 56, height: 56)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.headline)
                    Text(locationLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(item.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }

        private var locationLabel: String {
            if let c = item.city, !c.isEmpty { return c }
            return item.mode == "home" ? "Home area" : "Street"
        }
    }

    private struct ReservationMini: View {
        let item: TrashDTO
        var body: some View {
            HStack {
                Text(item.title)
                Spacer()
                if let until = item.reservedUntil {
                    Text(until, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

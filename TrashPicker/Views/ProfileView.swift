import SwiftUI
import MapKit

struct ProfileView: View {
    @EnvironmentObject var svc: SupabaseService

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(svc.myUploads) { item in
                        UploadRow(item: item)
                    }
                } header: {
                    Text("My uploads (24h)").font(AppFont.h2)
                }
                Section {
                    ForEach(svc.myReservations) { item in
                        ReservationRow(item: item)
                    }
                } header: {
                    Text("My reservations").font(AppFont.h2)
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign Out") { Task { await signOut() } }
                }
            }
            .task { await svc.fetchMyStuff() }
            .refreshable { await svc.fetchMyStuff() }
        }
    }

    @MainActor private func signOut() async {
        await svc.signOut()
    }
}

private struct UploadRow: View {
    let item: TrashDTO

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: item.firstPhotoURL)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppColor.stroke, lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(AppFont.h3)
                Text(item.cityText).font(AppFont.sub).foregroundColor(AppColor.muted)
            }
            Spacer()
            Text(item.createdAt, style: .time)
                .font(AppFont.sub).foregroundColor(AppColor.muted)
        }
    }
}

private struct ReservationRow: View {
    let item: TrashDTO

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: item.firstPhotoURL)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppColor.stroke, lineWidth: 1))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(AppFont.h3)
                if let until = item.reservedUntil {
                    Text("⏱ \(until, style: .timer)")
                        .font(AppFont.sub.monospacedDigit())
                        .foregroundColor(AppColor.muted)
                }
            }
            Spacer()
        }
    }
}

private struct Thumbnail: View {
    let url: URL?
    var body: some View {
        Group {
            if let url, url.isFileURL {
                DownsampledImage(url: url, maxDimension: 100).scaledToFill()
            } else if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    case .empty: Color.gray.opacity(0.15)
                    case .failure: Color.gray.opacity(0.15)
                    @unknown default: Color.gray.opacity(0.15)
                    }
                }
            } else {
                Color.gray.opacity(0.15)
            }
        }
    }
}


// MARK: Convenience helpers (align with TrashDTO)

extension CKTrashItem {
    var cityText: String { city }
    var mapCoordinate: CLLocationCoordinate2D? { coordinate }
}


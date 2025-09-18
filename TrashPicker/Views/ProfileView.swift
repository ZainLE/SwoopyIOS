import SwiftUI
import MapKit

struct ProfileView: View {
    @EnvironmentObject var ck: CKTrashService

    var body: some View {
        NavigationStack {
            List {
                Section("My uploads (24h)") {
                    ForEach(ck.myUploads) { item in
                        UploadRow(item: item)   // or generic row version you adopted
                    }
                }
                Section("My reservations") {
                    ForEach(ck.myReservations) { item in
                        ReservationRow(item: item)
                    }
                }
            }
            .navigationTitle("Profile")
            .task { await ck.fetchFeed() }
            .refreshable { await ck.fetchFeed() }
        }
    }
}

private struct UploadRow: View {
    let item: CKTrashItem
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let rem = max(0, Int(item.expiresAt.timeIntervalSince(ctx.date)))
                    Text("Expires in \(fmt(rem))")
                        .font(.title3.monospacedDigit())
                }
//                Text("Interested: \(item.interestedCount)")
                if let until = item.reservedUntil, until > Date() {
                    Text("Reserved until \(until, style: .time)")
                } else {
                    Text("Not reserved")
                }
                Button("Open in Maps") {
                    let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: item.coordinate))
                    mapItem.name = item.title
                    mapItem.openInMaps(
                        launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit]
                    )
                }
            }
            .font(.subheadline)
        } label: {
            HStack(spacing: 12) {
                if let url = item.photoURL, let img = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipped()
                        .cornerRadius(8)
                }
                VStack(alignment: .leading) {
                    Text(item.title).font(.headline)
                    Text(item.city).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private func fmt(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return String(format: "%02dh %02dm %02ds", h, m, s)
    }
}

private struct ReservationRow: View {
    let item: CKTrashItem

    var body: some View {
        HStack(spacing: 12) {
            if let url = item.photoURL, let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img)
                    .resizable().scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipped()
                    .cornerRadius(8)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.headline)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let rem = max(0, Int((item.reservedUntil ?? Date()).timeIntervalSince(ctx.date)))
                    Text("Time left: \(fmt(rem))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    let mi = MKMapItem(placemark: MKPlacemark(coordinate: item.coordinate))
                    mi.name = item.title
                    mi.openInMaps(
                        launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit]
                    )
                } label: {
                    Label("Open in Maps", systemImage: "map")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
    }

    private func fmt(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return String(format: "%02dh %02dm %02ds", h, m, sec)
    }
}


// MARK: Convenience helpers (align with TrashDTO)

extension CKTrashItem {
    var cityText: String { city }
    var mapCoordinate: CLLocationCoordinate2D? { coordinate }
}

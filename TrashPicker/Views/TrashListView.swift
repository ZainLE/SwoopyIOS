import SwiftUI

struct TrashListView: View {
    @EnvironmentObject var ck: CKTrashService
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(ck.feed.filter { query.isEmpty ? true : $0.title.lowercased().contains(query.lowercased()) }) { item in
                    HStack(spacing: 12) {
                        if let url = item.photoURL, let img = UIImage(contentsOfFile: url.path) {
                            Image(uiImage: img).resizable().scaledToFill().frame(width: 56, height: 56).clipped().cornerRadius(8)
                        } else {
                            RoundedRectangle(cornerRadius: 8).fill(.thinMaterial).frame(width: 56, height: 56)
                        }
                        VStack(alignment: .leading) {
                            Text(item.title).font(.headline)
                            Text(item.city).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.createdAt, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("List")
            .searchable(text: $query)
            .task { await ck.fetchFeed() }
        }
    }
}

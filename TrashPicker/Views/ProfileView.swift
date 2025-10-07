import SwiftUI
import MapKit

// MARK: - ProfileVM

@MainActor
final class ProfileVM: ObservableObject {
    @Published var userEmail: String = ""
    @Published var displayName: String = ""
    @Published var createdAt: Date?
    @Published var uploadsCount: Int?
    @Published var reservationsCount: Int?
    
    private let supabaseService: SupabaseService
    
    init(supabaseService: SupabaseService) {
        self.supabaseService = supabaseService
    }
    
    func load() async {
        // Get data from Supabase session first
        if let session = supabaseService.session {
            userEmail = session.user.email ?? "No email"
            displayName = session.user.userMetadata["full_name"]?.description
                ?? session.user.userMetadata["name"]?.description
                ?? "Your Name"
            createdAt = session.user.createdAt
        }
        
        // Get counts from service
        uploadsCount = supabaseService.myUploads.count
        reservationsCount = supabaseService.myReservations.count
    }
    
    var memberSinceText: String {
        guard let createdAt = createdAt else { return "Unknown" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: createdAt)
    }
    
    var accountAgeText: String {
        guard let createdAt = createdAt else { return "Unknown" }
        let components = Calendar.current.dateComponents([.day, .month, .year], from: createdAt, to: Date())
        
        if let years = components.year, years > 0 {
            return "\(years) year\(years == 1 ? "" : "s")"
        } else if let months = components.month, months > 0 {
            return "\(months) month\(months == 1 ? "" : "s")"
        } else if let days = components.day, days > 0 {
            return "\(days) day\(days == 1 ? "" : "s")"
        } else {
            return "Less than a day"
        }
    }
    
    var uploadSubtitle: String {
        guard let count = uploadsCount else { return "No uploads yet" }
        return count == 0 ? "No uploads yet" : "\(count) upload\(count == 1 ? "" : "s")"
    }
    
    var reservationSubtitle: String {
        guard let count = reservationsCount else { return "No reservations yet" }
        return count == 0 ? "No reservations yet" : "\(count) reservation\(count == 1 ? "" : "s")"
    }
}

struct ProfileView: View {
    @EnvironmentObject var svc: SupabaseService
    @StateObject private var viewModel: ProfileVM
    @State private var showingDeleteConfirmation = false
    @State private var showingFinalDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var showingSignOutError = false
    @State private var showingDeleteError = false
    @State private var errorMessage = ""
    @State private var showingAccountDetails = false
    @State private var notificationsCount = 0
    
    init() {
        // We'll need to inject the service in the view's initializer or use a different approach
        // For now, we'll create the viewModel in onAppear
        self._viewModel = StateObject(wrappedValue: ProfileVM(supabaseService: SupabaseService.shared))
    }

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Account Section
                Section {
                    Button(action: { showingAccountDetails = true }) {
                        HStack(spacing: 16) {
                            // Avatar
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 48))
                                .foregroundColor(AppColor.brandGreen)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                // Display name
                                Text(viewModel.displayName)
                                    .font(AppFont.h3)
                                    .foregroundColor(AppColor.text)
                                
                                // Email
                                Text(viewModel.userEmail)
                                    .font(AppFont.sub)
                                    .foregroundColor(AppColor.muted)
                                
                                // Member info
                                VStack(alignment: .leading, spacing: 2) {
                                    if viewModel.createdAt != nil {
                                        Text("Member since: \(viewModel.memberSinceText)")
                                            .font(AppFont.sub)
                                            .foregroundColor(AppColor.muted)
                                    }
                                    
                                    Text("Account age: \(viewModel.accountAgeText)")
                                        .font(AppFont.sub)
                                        .foregroundColor(AppColor.muted)
                                }
                            }
                            
                            Spacer()
                            
                            // Chevron for account details
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(AppColor.muted)
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Account")
                        .font(AppFont.h2)
                }
                
                // MARK: - Your Uploads Section
                Section {
                    NavigationLink(destination: UploadsHistoryView()) {
                        HStack(spacing: 12) {
                            Image(systemName: "tray.full")
                                .font(.system(size: 20))
                                .foregroundColor(AppColor.brandGreen)
                                .frame(width: 24)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Your uploads")
                                    .font(AppFont.body)
                                    .foregroundColor(AppColor.text)
                                
                                Text(viewModel.uploadSubtitle)
                                    .font(AppFont.sub)
                                    .foregroundColor(AppColor.muted)
                            }
                            
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                // MARK: - Reservation History Section
                Section {
                    NavigationLink(destination: ReservationHistoryView()) {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 20))
                                .foregroundColor(AppColor.brandGreen)
                                .frame(width: 24)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Reservation history")
                                    .font(AppFont.body)
                                    .foregroundColor(AppColor.text)
                                
                                Text(viewModel.reservationSubtitle)
                                    .font(AppFont.sub)
                                    .foregroundColor(AppColor.muted)
                            }
                            
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                // MARK: - Notifications Section
                Section {
                    NavigationLink(destination: NotificationsView()) {
                        HStack(spacing: 12) {
                            Image(systemName: "bell")
                                .font(.system(size: 20))
                                .foregroundColor(AppColor.brandGreen)
                                .frame(width: 24)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Notifications")
                                    .font(AppFont.body)
                                    .foregroundColor(AppColor.text)
                                
                                Text("Pickup requests")
                                    .font(AppFont.sub)
                                    .foregroundColor(AppColor.muted)
                            }
                            
                            Spacer()
                            
                            // Badge (always visible; starts at 0)
                            Text("\(notificationsCount)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(AppColor.brandGreen)
                                .clipShape(Capsule())
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                // MARK: - Danger Zone Section
                Section {
                    // Sign Out Button
                    Button(action: { Task { await signOut() } }) {
                        HStack {
                            Spacer()
                            Text("Sign Out")
                                .font(AppFont.label)
                                .foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .background(AppColor.brandGreen)
                        .clipShape(RoundedRectangle(cornerRadius: 99))
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    
                    // Delete Account Button
                    Button(action: { showingDeleteConfirmation = true }) {
                        HStack {
                            Spacer()
                            if isDeleting {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(.white)
                            } else {
                                Text("Delete Account")
                                    .font(AppFont.label)
                                    .foregroundColor(.white)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .background(Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 99))
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeleting)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .task {
                await svc.fetchMyStuff()
                await viewModel.load()
            }
            .refreshable {
                await svc.fetchMyStuff()
                await viewModel.load()
            }
            .confirmationDialog(
                "Delete Account",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Account", role: .destructive) {
                    showingFinalDeleteConfirmation = true
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Delete your account and all data?")
            }
            .confirmationDialog(
                "Final Confirmation",
                isPresented: $showingFinalDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Yes, delete", role: .destructive) {
                    Task { await deleteAccount() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This action cannot be undone. All your data will be permanently deleted.")
            }
            .alert("Sign Out Error", isPresented: $showingSignOutError) {
                Button("OK") { }
            } message: {
                Text("Couldn't sign out. Try again.")
            }
            .alert("Delete Account Error", isPresented: $showingDeleteError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
            .sheet(isPresented: $showingAccountDetails) {
                AccountDetailsView()
                    .environmentObject(svc)
            }
            .onAppear {
                // Refresh profile data when returning from account details
                Task {
                    await viewModel.load()
                }
                #if DEBUG
                print("[PROFILE] notificationsCount=\(notificationsCount)")
                #endif
            }
        }
    }
    
    
    // MARK: - Actions
    
    @MainActor private func signOut() async {
        do {
            try await svc.client.auth.signOut()
            // Clear any app state (draft stores, caches) and route to Auth flow
            await svc.signOut() // This handles the local cleanup
        } catch {
            errorMessage = "Couldn't sign out. Try again."
            showingSignOutError = true
        }
    }
    
    @MainActor private func deleteAccount() async {
        isDeleting = true
        do {
            try await svc.deleteAccount()
            // On success, the service handles sign out and cleanup
        } catch {
            errorMessage = error.localizedDescription
            showingDeleteError = true
        }
        isDeleting = false
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

private struct UploadPostRow: View {
    let post: Post  // Post.expiresAt is Date? in your model

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: post.primaryImageURL)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppColor.stroke, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(post.title)
                    .font(AppFont.h3)

                Text(post.condition.rawValue.capitalized)
                    .font(AppFont.sub)
                    .foregroundColor(AppColor.muted)

                // When / expiry label
                expiresView
            }

            Spacer()
        }
    }

    // Shows the expiration nicely if we have a Date
    @ViewBuilder
    private var expiresView: some View {
        if let date = post.expiresAt {
            // choose .time / .relative / .date to taste
            Text(date, style: .time)
                .font(AppFont.sub)
                .foregroundColor(AppColor.muted)
        } else {
            EmptyView()
        }
    }
}

private struct ProfileReservationRow: View {
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
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .empty:
                Color.gray.opacity(0.15)
            case .failure:
                Color.gray.opacity(0.15)
            @unknown default:
                Color.gray.opacity(0.15)
            }
        }
    }
}

// MARK: - History Views

private struct UploadsHistoryView: View {
    @EnvironmentObject var svc: SupabaseService
    @State private var api: ApiService?
    @State private var myPosts: [Post] = []
    @State private var isLoading = false
    
    var body: some View {
        List {
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(AppColor.brandGreen)
                    
                    Text("Loading your uploads...")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
            } else if myPosts.isEmpty {
                ContentUnavailableView(
                    "No Uploads Yet",
                    systemImage: "tray",
                    description: Text("Your uploaded items will appear here")
                )
            } else {
                ForEach(myPosts, id: \.id) { post in
                    UploadPostRow(post: post)
                }
            }
        }
        .navigationTitle("Your Uploads")
        .navigationBarTitleDisplayMode(.large)
        .task { 
            if api == nil { api = ApiService(supabaseService: svc) }
            await loadMyPosts()
        }
        .refreshable { 
            await loadMyPosts()
        }
    }
    
    @MainActor
    private func loadMyPosts() async {
        guard let api else { return }
        isLoading = true
        do {
            let posts = try await fetchWithRetry(svc: svc) {
                try await api.getMyPosts()
            }
            myPosts = posts
        } catch {
            myPosts = []
            // Note: ProfileView doesn't show error messages, but AuthError is handled gracefully
        }
        isLoading = false
    }
    
}

private struct ReservationHistoryView: View {
    @EnvironmentObject var svc: SupabaseService
    
    var body: some View {
        List {
            if svc.myReservations.isEmpty {
                ContentUnavailableView(
                    "No Reservations Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Items you've reserved will appear here")
                )
            } else {
                ForEach(svc.myReservations) { item in
                    ProfileReservationRow(item: item)
                }
            }
        }
        .navigationTitle("Reservation History")
        .navigationBarTitleDisplayMode(.large)
        .task { await svc.fetchMyStuff() }
        .refreshable { await svc.fetchMyStuff() }
    }
}

// MARK: Convenience helpers (align with TrashDTO)

extension CKTrashItem {
    var cityText: String { city }
    var mapCoordinate: CLLocationCoordinate2D? { coordinate }
}


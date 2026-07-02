import SwiftUI
import MapKit
import Combine
import UIKit
import PhotosUI

private let reportActionCornerRadius: CGFloat = 24

// MARK: - ProfileVM

@MainActor
final class ProfileVM: ObservableObject {
    @Published var userEmail: String = ""
    @Published var createdAt: Date?
    @Published var uploadsCount: Int?
    @Published var reservationsCount: Int?
    
    private let supabaseService: SupabaseService
    private var profileTask: Task<Void, Never>?
    private var isActive = false
    
    // Single-flight tracking: prevent duplicate fetches
    private var lastFetchTime: Date?
    private let fetchCooldown: TimeInterval = 3.0 // 3 seconds
    
    init(supabaseService: SupabaseService) {
        self.supabaseService = supabaseService
    }
    
    deinit {
        profileTask?.cancel()
    }
    
    func load() async {
        // Load immediately from cached session (no network, instant)
        await loadFromCache()
    }
    
    private func loadFromCache() async {
        // Get data from Supabase session (already in memory, instant)
        if let session = supabaseService.session {
            userEmail = session.user.email ?? "No email"
            createdAt = session.user.createdAt
        }
        
        // Get counts from service (already in memory, instant)
        uploadsCount = supabaseService.myUploads.count
        reservationsCount = supabaseService.myReservations.count
    }
    
    // MARK: - Lifecycle Management
    
    func startProfileRefresh(force: Bool = false) {
        // Single-flight: if already running, don't start another
        guard profileTask == nil else {
            #if DEBUG
            DLog("[PROFILE] startProfileRefresh skipped (already running)")
            #endif
            return
        }
        
        // Cooldown check: don't fetch if we fetched recently (unless forced)
        if !force, let lastFetch = lastFetchTime, Date().timeIntervalSince(lastFetch) < fetchCooldown {
            #if DEBUG
            let elapsed = Date().timeIntervalSince(lastFetch)
            DLog("[PROFILE] startProfileRefresh skipped (cooldown elapsed=\(String(format: "%.1f", elapsed))s)")
            #endif
            return
        }
        
        isActive = true
        profileTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchOnce()
        }
    }
    
    func stopProfileRefresh() {
        isActive = false
        profileTask?.cancel()
        profileTask = nil
    }
    
    private func fetchOnce() async {
        guard isActive, !Task.isCancelled else { return }
        
        #if DEBUG
        let fetchStart = Date()
        DLog("[PROFILE] fetchOnce starting")
        #endif
        
        // Run network call in background Task.detached
        let result = await Task.detached(priority: .userInitiated) { [supabaseService] in
            do {
                try Task.checkCancellation()
                await supabaseService.fetchMyStuff()
                return true
            } catch {
                // Silently ignore cancellations
                if error.isCancellationLike {
                    return false
                }
                // Log other errors with rate limiting
                NetLog.profileOnce("fetchOnce error=\(error.localizedDescription)")
                return false
            }
        }.value
        
        // Update UI on main actor
        if result {
            await loadFromCache()
            await MainActor.run {
                lastFetchTime = Date()
                profileTask = nil
            }
            
            #if DEBUG
            let elapsed = Date().timeIntervalSince(fetchStart)
            DLog("[PROFILE] fetchOnce complete elapsed=\(String(format: "%.0f", elapsed * 1000))ms")
            #endif
        } else {
            await MainActor.run {
                profileTask = nil
            }
        }
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
    @EnvironmentObject var api: ApiService
    @StateObject private var viewModel: ProfileVM
    @StateObject private var profileManager: ProfileManager
    @EnvironmentObject var notificationService: ReservationNotificationService
    @State private var showingSignOutError = false
    @State private var reportCategory: String?
    @State private var reportMessage: String = ""
    @State private var reportScreenshot: UIImage?
    @State private var isSendingReport = false
    @State private var reportShowCamera = false
    @State private var reportIsPhotoPickerPresented = false
    @State private var reportSelectedPhotoItem: PhotosPickerItem?
    @State private var isReportCategoryModalVisible = false
    @State private var isReportDetailModalVisible = false
    @State private var isReportSuccessModalVisible = false
    @State private var reportSuccessDismissTask: Task<Void, Never>?
    @State private var showNotificationsFromPush = false
    @State private var avatarRefreshNonce = 0
    @State private var givenCount: Int?
    @State private var gamificationProfile: Profile?
    
    init() {
        // Initialize both view models with shared services
        self._viewModel = StateObject(wrappedValue: ProfileVM(supabaseService: SupabaseService.shared))
        self._profileManager = StateObject(wrappedValue: ProfileManager(apiService: ApiService(supabaseService: SupabaseService.shared), initialProfile: SupabaseService.shared.serverProfile))
    }
    
    var body: some View {
        NavigationStack {
            List {
                profileHeaderSection
                achievementsSection
                uploadsSection
                notificationsSection
                safetySection
                primaryActionsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Profile")
                        .font(AppFont.h2)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .refreshable {
                viewModel.startProfileRefresh(force: true)
                try? await Task.sleep(nanoseconds: 100_000_000)
                await viewModel.load()
                await profileManager.loadProfile()
                await reloadNotificationBadges()
                await loadGivenCount()
            }
        }
        .navigationDestination(isPresented: $showNotificationsFromPush) {
            NotificationsView()
        }
        .fullScreenCover(isPresented: $reportShowCamera) {
            CameraScreen(
                onCaptured: { image in
                    applyReportImage(image)
                    reportShowCamera = false
                    restoreReportDetailModalIfNeeded()
                },
                onCancel: {
                    reportShowCamera = false
                    restoreReportDetailModalIfNeeded()
                }
            )
            .ignoresSafeArea()
        }
        .photosPicker(
            isPresented: $reportIsPhotoPickerPresented,
            selection: $reportSelectedPhotoItem,
            matching: .images,
            preferredItemEncoding: .automatic
        )
        .onChange(of: reportSelectedPhotoItem) { newItem in
            handleReportPhotoPickerChange(newItem)
        }
        .onChange(of: reportIsPhotoPickerPresented) { isPresented in
                if !isPresented {
                    restoreReportDetailModalIfNeeded()
                }
        }
        .alert("Sign Out Error", isPresented: $showingSignOutError) {
            Button("OK") { }
        } message: {
            Text("Couldn't sign out. Try again.")
        }
        .onReceive(svc.$myReservations) { reservations in
            viewModel.reservationsCount = reservations.count
        }
        .onReceive(svc.$myUploads) { uploads in
            viewModel.uploadsCount = uploads.count
        }
        .onReceive(NotificationCenter.default.publisher(for: .openNotifications)) { _ in
            showNotificationsFromPush = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .profileDidUpdate)) { _ in
            avatarRefreshNonce += 1
            Task { await profileManager.loadProfile() }
        }
        .onAppear {
            Task {
                await viewModel.load()
                await profileManager.loadProfile()
                await reloadNotificationBadges()
                await loadGivenCount()
            }
            viewModel.startProfileRefresh()
        }
        .onDisappear {
            viewModel.stopProfileRefresh()
            hideReportSuccessModal()
        }
        .onChange(of: svc.phase) { _, newPhase in
            if newPhase == .signedIn {
                Task { await reloadNotificationBadges() }
            } else if newPhase == .signedOut {
                notificationService.requestsCount = 0
                notificationService.unreadCount = 0
            }
        }
        .overlay {
            ZStack {
                if isReportCategoryModalVisible {
                    ReportCategoryModal(
                        categories: reportIssueCategories,
                        onSelect: { category in
                            reportCategory = category
                            reportMessage = ""
                            reportScreenshot = nil
                            reportSelectedPhotoItem = nil
                            isSendingReport = false
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                isReportCategoryModalVisible = false
                                isReportDetailModalVisible = true
                            }
                        },
                        onDismiss: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                isReportCategoryModalVisible = false
                            }
                            resetReportState()
                        }
                    )
                    .transition(.opacity.combined(with: .scale))
                    .zIndex(2)
                }

                if isReportDetailModalVisible {
                    ReportDetailModal(
                        category: reportCategory ?? "",
                        message: $reportMessage,
                        hasScreenshot: reportScreenshot != nil,
                        isSending: isSendingReport,
                        canSend: canSendReport,
                        onAddScreenshot: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                isReportDetailModalVisible = false
                            }
                            showScreenshotSourceSheet()
                        },
                        onSend: {
                            Task { await sendReport() }
                        },
                        onDismiss: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                isReportDetailModalVisible = false
                            }
                            resetReportState()
                        }
                    )
                    .transition(.opacity.combined(with: .scale))
                    .zIndex(2)
                }

                if isReportSuccessModalVisible {
                    ReportSuccessModal(onDismiss: { hideReportSuccessModal() })
                        .padding(.horizontal, 24)
                        .transition(.opacity.combined(with: .scale))
                        .zIndex(3)
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isReportCategoryModalVisible)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isReportDetailModalVisible)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isReportSuccessModalVisible)
    }
    
    @ViewBuilder
    private var profileHeaderSection: some View {
        Section {
            ZStack {
                HStack(spacing: 16) {
                    // Avatar with fallback to system icon
                    Group {
                        if let avatarURL = resolvedAvatarURL {
                            ResilientAsyncImage(url: avatarURL) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                default:
                                    Image(systemName: "person.circle.fill")
                                        .font(.system(size: 48))
                                        .foregroundColor(AppColor.brandGreen)
                                }
                            }
                            .frame(width: 48, height: 48)
                            .clipShape(Circle())
                        } else {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 48))
                                .foregroundColor(AppColor.brandGreen)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profileManager.displayName)
                            .font(AppFont.h3)
                            .foregroundColor(AppColor.text)
                        
                        Text(viewModel.userEmail)
                            .font(AppFont.sub)
                            .foregroundColor(AppColor.muted)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            if viewModel.createdAt != nil {
                                Text("Member since: \(viewModel.memberSinceText)")
                                    .font(AppFont.sub)
                                    .foregroundColor(AppColor.muted)
                            }
                            
                            Text("Account age: \(viewModel.accountAgeText)")
                                .font(AppFont.sub)
                                .foregroundColor(AppColor.muted)

                            if let givenCount, givenCount >= 1 {
                                Text("You've helped divert \(givenCount) item\(givenCount == 1 ? "" : "s")")
                                    .font(AppFont.sub.weight(.semibold))
                                    .foregroundColor(AppColor.brandGreen)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    Text("Edit")
                        .font(AppFont.sub)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(AppColor.brandGreen)
                        .clipShape(Capsule())
                }
                .padding(.vertical, 8)
                
                NavigationLink(destination: AccountDetailsView()) {
                    EmptyView()
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(0.01)
            }
        } header: {
            Text("User Information")
                .font(AppFont.body.weight(.semibold))
        }
    }

    private var earnedBadges: [String] {
        guard let profile = gamificationProfile else { return [] }
        var badges: [String] = []
        if profile.badgeFirstPickup == true { badges.append("First pickup") }
        if profile.badgeTenItems == true { badges.append("10 items diverted") }
        if profile.badgeThreeWeekStreak == true { badges.append("3-week streak") }
        if profile.badgeTop3 == true { badges.append("Top 3 finish") }
        return badges
    }

    @ViewBuilder
    private var achievementsSection: some View {
        let tier = gamificationProfile?.tier.flatMap { LeaderboardTier(rawValue: $0.lowercased()) }
        let badges = earnedBadges

        if tier != nil || badges.isEmpty == false {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let tier {
                            TierBadge(tier: tier)
                        }

                        ForEach(badges, id: \.self) { badge in
                            Text(badge)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(AppColor.brandGreen)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(AppColor.brandGreen.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Achievements")
                    .font(AppFont.body.weight(.semibold))
            }
        }
    }

    private var resolvedAvatarURL: URL? {
        let raw = (profileManager.avatarUrl ?? svc.serverProfile?.avatarUrl)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        guard var components = URLComponents(string: raw) else { return URL(string: raw) }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "tpv" }
        queryItems.append(URLQueryItem(name: "tpv", value: "\(avatarRefreshNonce)"))
        components.queryItems = queryItems
        return components.url ?? URL(string: raw)
    }
    
    @ViewBuilder
    private var uploadsSection: some View {
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
    }

    @ViewBuilder
    private var safetySection: some View {
        Section {
            NavigationLink(destination: SafetySettingsView()) {
                HStack(spacing: 12) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 20))
                        .foregroundColor(AppColor.brandGreen)
                        .frame(width: 24)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Safety & Moderation")
                            .font(AppFont.body)
                            .foregroundColor(AppColor.text)
                        
                        Text("Report, filter, or block users")
                            .font(AppFont.sub)
                            .foregroundColor(AppColor.muted)
                    }
                    
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var notificationsSection: some View {
        let totalBadge = max(0, notificationService.requestsCount + notificationService.unreadCount)
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
                        
                        Text("Requests & updates")
                            .font(AppFont.sub)
                            .foregroundColor(AppColor.muted)
                    }
                    
                    Spacer()
                    
                    if totalBadge > 0 {
                        Text("\(totalBadge)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AppColor.brandGreen)
                            .clipShape(Capsule())
                    }
                }
                .padding(.vertical, 4)
            }

            NavigationLink(destination: NearbyAlertsSettingsView()) {
                HStack(spacing: 12) {
                    Image(systemName: "location.circle")
                        .font(.system(size: 20))
                        .foregroundColor(AppColor.brandGreen)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nearby Alerts")
                            .font(AppFont.body)
                            .foregroundColor(AppColor.text)

                        Text("Get notified about new items near you")
                            .font(AppFont.sub)
                            .foregroundColor(AppColor.muted)
                    }

                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
    }
    

    @ViewBuilder
    private var primaryActionsSection: some View {
        Section {
            Button {
                playHaptic(.light)
                resetReportState()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    isReportCategoryModalVisible = true
                }
            } label: {
                HStack {
                    Spacer()
                    Text("Report a Problem")
                        .font(AppFont.label)
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding(.vertical, 14)
                .background(AppTheme.ColorToken.danger)
                .clipShape(RoundedRectangle(cornerRadius: reportActionCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            
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
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @MainActor
    private func loadGivenCount() async {
        guard svc.hasAuthToken else { return }
        do {
            let profile = try await api.getProfile()
            givenCount = profile.givenCount
            gamificationProfile = profile
        } catch {
#if DEBUG
            DLog("[PROFILE] given count refresh failed: \(error.localizedDescription)")
#endif
        }
    }

    @MainActor
    private func reloadNotificationBadges() async {
        guard svc.hasAuthToken else {
            notificationService.requestsCount = 0
            notificationService.unreadCount = 0
            return
        }
        
        let service = NotificationService(api: api)
        do {
            let notifications = try await service.fetchAll()
            let actionable = notifications.filter { $0.category == .actionable }
            let unread = notifications.filter { !$0.isRead }
            notificationService.requestsCount = actionable.count
            notificationService.unreadCount = unread.count
        } catch {
#if DEBUG
            DLog("[PROFILE] notifications refresh failed: \(error.localizedDescription)")
#endif
        }
    }

    private var reportProblemContext: ReportProblemContext {
        let session = svc.session
        let user = session?.user
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let versionString = build.isEmpty ? version : "\(version) (\(build))"
        let device = UIDevice.current
        return ReportProblemContext(
            userId: user?.id.uuidString ?? "unknown",
            email: user?.email ?? "unknown",
            appVersion: versionString,
            deviceModel: device.model,
            osVersion: "iOS \(device.systemVersion)"
        )
    }
    
    private var canSendReport: Bool {
        !reportMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reportScreenshot != nil
    }
    
    private func playHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
#if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
#endif
    }
    
    private let reportIssueCategories = [
        "App isn’t working",
        "Posting issue",
        "Location / map",
        "Other"
    ]
    
    private func showScreenshotSourceSheet() {
        let alert = UIAlertController(title: "Screenshot", message: nil, preferredStyle: .actionSheet)
        
        let cameraAction = UIAlertAction(title: reportScreenshot == nil ? "Take Photo" : "Retake Photo", style: .default) { _ in
            openReportCamera()
        }
        applyBrandColor(to: cameraAction)
        alert.addAction(cameraAction)
        
        let libraryAction = UIAlertAction(title: "Choose from Library", style: .default) { _ in
            openReportLibrary()
        }
        applyBrandColor(to: libraryAction)
        alert.addAction(libraryAction)
        
        if reportScreenshot != nil {
            alert.addAction(UIAlertAction(title: "Remove Screenshot", style: .destructive) { _ in
                reportScreenshot = nil
                restoreReportDetailModalIfNeeded()
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            restoreReportDetailModalIfNeeded()
        })
        
        presentAlertController(alert)
    }
    
    private func openReportLibrary() {
        reportSelectedPhotoItem = nil
        reportIsPhotoPickerPresented = true
    }
    
    private func openReportCamera() {
        Task { @MainActor in
            let granted = await CameraSessionManager.shared.ensurePermission()
            if granted {
                CameraSessionManager.shared.configureIfNeeded()
                reportShowCamera = true
            }
        }
    }
    
    private func handleReportPhotoPickerChange(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                await MainActor.run {
                    applyReportImage(image)
                    reportIsPhotoPickerPresented = false
                    reportSelectedPhotoItem = nil
                }
            } else {
                await MainActor.run {
                    reportIsPhotoPickerPresented = false
                    reportSelectedPhotoItem = nil
                }
            }
        }
    }
    
    @MainActor
    private func applyReportImage(_ image: UIImage) {
        reportScreenshot = image
    }
    
    @MainActor
    private func resetReportState(preservingSuccess: Bool = false) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            isReportCategoryModalVisible = false
            isReportDetailModalVisible = false
        }
        reportCategory = nil
        reportMessage = ""
        reportScreenshot = nil
        reportSelectedPhotoItem = nil
        reportIsPhotoPickerPresented = false
        isSendingReport = false
        if !preservingSuccess {
            hideReportSuccessModal()
        }
    }

    @MainActor
    private func showReportSuccessModal() {
        reportSuccessDismissTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isReportSuccessModalVisible = true
        }
        reportSuccessDismissTask = Task {
            do {
                try await Task.sleep(nanoseconds: 2_200_000_000)
            } catch {
                return
            }
            await MainActor.run {
                self.reportSuccessDismissTask = nil
                guard self.isReportSuccessModalVisible else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    self.isReportSuccessModalVisible = false
                }
            }
        }
    }

    @MainActor
    private func hideReportSuccessModal() {
        reportSuccessDismissTask?.cancel()
        reportSuccessDismissTask = nil
        guard isReportSuccessModalVisible else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            isReportSuccessModalVisible = false
        }
    }
    
    private func presentAlertController(_ alert: UIAlertController) {
        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
                  let window = scene.windows.first(where: { $0.isKeyWindow }),
                  let root = window.rootViewController else { return }
            var top = root
            while let presented = top.presentedViewController {
                top = presented
            }
            top.present(alert, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.styleAlertActions(in: alert)
            }
        }
    }
    
    private func applyBrandColor(to action: UIAlertAction) {
        guard action.style == .default else { return }
        action.setValue(UIColor.white, forKey: "titleTextColor")
    }

    private func restoreReportDetailModalIfNeeded() {
        guard reportCategory != nil else { return }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                self.isReportDetailModalVisible = true
            }
        }
    }
    
    private func styleAlertActions(in alert: UIAlertController) {
        guard alert.preferredStyle == .actionSheet else { return }
        styleActions(alert.actions, in: alert, cornerRadius: reportActionCornerRadius)
    }
    
    private func styleActions(_ actions: [UIAlertAction], in alert: UIAlertController, cornerRadius: CGFloat) {
        let brandColor = UIColor(AppColor.brandGreen)
        
        for action in actions {
            guard let title = action.title,
                  let label = findLabel(in: alert.view, matching: title),
                  let container = findActionContainer(for: label) else { continue }
            
            let isDefault = action.style == .default
            let backgroundColor: UIColor = {
                switch action.style {
                case .default:
                    return brandColor
                case .destructive:
                    return UIColor(AppTheme.ColorToken.danger)
                case .cancel:
                    return container.backgroundColor ?? UIColor.systemBackground
                @unknown default:
                    return container.backgroundColor ?? UIColor.systemBackground
                }
            }()
            
            container.backgroundColor = backgroundColor
            container.layer.cornerRadius = cornerRadius
            if #available(iOS 13.0, *) {
                container.layer.cornerCurve = .continuous
            }
            container.layer.masksToBounds = true
            container.alpha = action.isEnabled ? 1.0 : 0.55
            
            switch action.style {
            case .default:
                label.textColor = .white
            case .destructive:
                label.textColor = .white
            case .cancel:
                label.textColor = label.textColor
            @unknown default:
                break
            }
            
            if isDefault {
                action.setValue(UIColor.white, forKey: "titleTextColor")
            }
        }
    }
    private func findLabel(in view: UIView, matching text: String) -> UILabel? {
        if let label = view as? UILabel, label.text == text {
            return label
        }
        for subview in view.subviews {
            if let label = findLabel(in: subview, matching: text) {
                return label
            }
        }
        return nil
    }

    private func findActionContainer(for label: UILabel) -> UIView? {
        var current: UIView? = label
        while let view = current?.superview {
            current = view
            let className = NSStringFromClass(type(of: view))
            if className.contains("UIInterfaceAction") && !className.contains("Label") {
                return view
            }
        }
        return label.superview
    }

    @MainActor
    private func sendReport() async {
        guard let category = reportCategory, canSendReport, !isSendingReport else { return }
        isSendingReport = true
        let context = reportProblemContext
        let trimmedMessage = reportMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let screenshotBase64 = reportScreenshot?.jpegData(compressionQuality: 0.7)?.base64EncodedString()
        let payload = ReportProblemPayload(
            userId: context.userId,
            email: context.email,
            appVersion: context.appVersion,
            deviceModel: context.deviceModel,
            osVersion: context.osVersion,
            category: category,
            message: trimmedMessage,
            hasScreenshot: screenshotBase64 != nil,
            screenshotBase64: screenshotBase64,
            createdAt: Date()
        )

        do {
            try await ReportProblemService.submit(payload: payload)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            resetReportState(preservingSuccess: true)
            showReportSuccessModal()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            ToastCenter.shared.show("Couldn't send report. Try again later.", isError: true)
            isSendingReport = false
            restoreReportDetailModalIfNeeded()
        }
    }
    
    
    // MARK: - Actions
    
    @MainActor private func signOut() async {
        do {
            try await svc.client.auth.signOut()
            // Clear any app state (draft stores, caches) and route to Auth flow
            await svc.signOut() // This handles the local cleanup
        } catch {
            showingSignOutError = true
        }
    }
}

private struct ReportCategoryModal: View {
        let categories: [String]
        let onSelect: (String) -> Void
        let onDismiss: () -> Void

        var body: some View {
        ZStack {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Community Safety")
                                .font(AppFont.h3)
                                .foregroundColor(AppColor.text)
                            Text("Tell us what went wrong so we can fix it.")
                                .font(AppFont.sub)
                                .foregroundColor(AppColor.muted)
                        }
                        Spacer()
                        Button(action: onDismiss) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundColor(AppColor.muted)
                                .background(Color.white.opacity(0.001))
                                .accessibilityLabel("Close")
                        }
                    }

                    VStack(spacing: 12) {
                        ForEach(categories, id: \.self) { category in
                            Button {
                                onSelect(category)
                            } label: {
                                Text(category)
                                    .font(AppFont.body)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(AppColor.brandGreen)
                                    .clipShape(RoundedRectangle(cornerRadius: reportActionCornerRadius, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 340)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: Color.black.opacity(0.25), radius: 24, x: 0, y: 12)
            }
        }
}


private struct ReportDetailModal: View {
    let category: String
    @Binding var message: String
    let hasScreenshot: Bool
    let isSending: Bool
    let canSend: Bool
    let onAddScreenshot: () -> Void
    let onSend: () -> Void
    let onDismiss: () -> Void

    @FocusState private var messageFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Please tell us what happened")
                            .font(AppFont.h3)
                            .foregroundColor(AppColor.text)
                        Text("Example: App froze when I tried to post a photo.")
                            .font(AppFont.sub)
                            .foregroundColor(AppColor.muted)
                    }
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundColor(AppColor.muted)
                            .background(Color.white.opacity(0.001))
                            .accessibilityLabel("Close")
                    }
                }

                if !category.isEmpty {
                    Text(category)
                        .font(AppFont.sub)
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(AppColor.brandGreen)
                        .clipShape(Capsule())
                }

                VStack(alignment: .leading, spacing: 12) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $message)
                            .focused($messageFocused)
                            .frame(minHeight: 120, maxHeight: 160)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(AppColor.brandGreen, lineWidth: 1)
                            )

                        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("type here…")
                                .font(AppFont.sub)
                                .foregroundColor(AppColor.muted)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }

                    Text(hasScreenshot ? "1 image uploaded" : "No image uploaded")
                        .font(AppFont.caption)
                        .foregroundColor(hasScreenshot ? AppColor.brandGreen : AppColor.muted)
                }

                VStack(spacing: 12) {
                    Button(action: onAddScreenshot) {
                        HStack(spacing: 8) {
                            Image(systemName: "photo.badge.plus.fill")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Add Screenshot")
                                .font(AppFont.body)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AppColor.cta)
                        .clipShape(RoundedRectangle(cornerRadius: reportActionCornerRadius, style: .continuous))
                        .shadow(color: Color.black.opacity(0.12), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)

                    Button(action: onSend) {
                        HStack {
                            Spacer()
                            if isSending {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Send Report")
                                    .font(AppFont.body)
                            }
                            Spacer()
                        }
                        .foregroundColor(.white)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(AppColor.brandGreen)
                        .clipShape(RoundedRectangle(cornerRadius: reportActionCornerRadius, style: .continuous))
                        .shadow(color: Color.black.opacity(0.12), radius: 8, y: 4)
                        .opacity((canSend && !isSending) ? 1.0 : 0.5)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend || isSending)
                }
            }
            .padding(24)
            .frame(maxWidth: 360)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: Color.black.opacity(0.25), radius: 24, x: 0, y: 12)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    messageFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .font(AppFont.sub)
            }
        }
    }
}

private struct ReportSuccessModal: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Thanks for letting us know! 💚")
                .font(AppFont.h3)
                .foregroundColor(AppColor.text)
            Text("We've received your report and will check it soon.")
                .font(AppFont.sub)
                .foregroundColor(AppColor.muted)
        }
        .padding(24)
        .frame(maxWidth: 320)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Color.black.opacity(0.25), radius: 24, x: 0, y: 12)
        .onTapGesture {
            onDismiss()
        }
        .accessibilityAddTraits(.isButton)
        .transition(.opacity.combined(with: .scale))
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
    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .short
        df.timeZone = .current
        df.locale = .current
        return df
    }()
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
    private static var didLogSample = false

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
                Text(uploadTitle(for: post))
                    .font(AppFont.h3)

                Text(post.condition.displayName)
                    .font(AppFont.sub)
                    .foregroundColor(AppColor.muted)

                // When / expiry label
                expiresView
            }

            Spacer(minLength: 8)

            statusBadge
        }
    }

    private enum PostLifecycle {
        case active, pickedUp, expired

        var label: String {
            switch self {
            case .active: return "Active"
            case .pickedUp: return "Picked up"
            case .expired: return "Expired"
            }
        }

        var color: Color {
            switch self {
            case .active: return AppColor.brandGreen
            case .pickedUp: return Color(hex: "6AA54A")
            case .expired: return AppColor.muted
            }
        }
    }

    private var lifecycle: PostLifecycle {
        let normalized = post.status?.lowercased() ?? ""
        if ["picked_up", "picked", "completed"].contains(normalized) {
            return .pickedUp
        }
        if normalized == "expired" {
            return .expired
        }
        if let expiresAt = post.expiresAt, expiresAt < Date() {
            return .expired
        }
        return .active
    }

    private var statusBadge: some View {
        Text(lifecycle.label)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(lifecycle.color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(lifecycle.color.opacity(0.12))
            .clipShape(Capsule())
    }

    private func uploadTitle(for post: Post) -> String {
        switch post.mode {
        case .street:
            return "Street post"
        case .home:
            return "Home post"
        default:
            return "Post"
        }
    }

    // Shows the expiration nicely if we have a Date
    @ViewBuilder
    private var expiresView: some View {
        // Prefer createdAt for upload timestamp; fall back to expiresAt if missing
        if let date = post.createdAt ?? post.expiresAt {
            Text(formattedUploadDate(date))
                .font(AppFont.sub)
                .foregroundColor(AppColor.muted)
        } else {
            EmptyView()
        }
    }

    private func formattedUploadDate(_ date: Date) -> String {
        let formatted = UploadPostRow.timeFormatter.string(from: date)
        if UploadPostRow.didLogSample == false {
            UploadPostRow.didLogSample = true
            let raw = UploadPostRow.isoFormatter.string(from: date)
            DLog("[UPLOADS] sample timestamp raw=\(raw) local=\(formatted)")
        }
        return formatted
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
    @State private var loadTask: Task<Void, Never>?
    
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
        .onAppear {
            if api == nil { api = ApiService(supabaseService: svc) }
            loadTask = Task { await loadMyPosts() }
        }
        .onDisappear {
            loadTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .profileDidUpdate)) { _ in
            loadTask?.cancel()
            loadTask = Task { await loadMyPosts() }
        }
        .refreshable { 
            await loadMyPosts()
        }
    }
    
    @MainActor
    private func loadMyPosts() async {
        guard let api else { return }
        isLoading = true
        defer { isLoading = false }
        
        do {
            try Task.checkCancellation()
            var posts = try await fetchWithRetry(svc: svc) {
                try await api.getMyPosts()
            }
            posts = await hydrateLocationsIfNeeded(for: posts, api: api)
            myPosts = posts
        } catch {
            // Silently ignore cancellations
            if error.isCancellationLike {
                return
            }
            myPosts = []
            NetLog.profileOnce("loadMyPosts error=\(error.localizedDescription)")
        }
    }
    
}

extension UploadsHistoryView {
    private func hydrateLocationsIfNeeded(for posts: [Post], api: ApiService) async -> [Post] {
        var updated = posts
        for index in posts.indices where posts[index].mode == .street && posts[index].exactCoordinate == nil {
            do {
                let hydrated = try await fetchWithRetry(svc: svc) {
                    try await api.getPost(posts[index].id)
                }
                LocationCache.shared.store(post: hydrated)
                updated[index] = hydrated
            } catch {
                #if DEBUG
                DLog("[PROFILE] hydrate post \(posts[index].id) error=\(error.localizedDescription)")
                #endif
            }
        }
        return updated
    }
}
//
//private struct ReservationHistoryView: View {
//    @EnvironmentObject var svc: SupabaseService
//    @State private var loadTask: Task<Void, Never>?
//    
//    var body: some View {
//        List {
//            if svc.myReservations.isEmpty {
//                ContentUnavailableView(
//                    "No Reservations Yet",
//                    systemImage: "clock.arrow.circlepath",
//                    description: Text("Items you've reserved will appear here")
//                )
//            } else {
//                ForEach(svc.myReservations) { item in
//                    ProfileReservationRow(item: item)
//                }
//            }
//        }
//        .navigationTitle("Reservation History")
//        .navigationBarTitleDisplayMode(.large)
//        .onAppear {
//            loadTask = Task { await svc.fetchMyStuff() }
//        }
//        .onDisappear {
//            loadTask?.cancel()
//        }
//        .refreshable { await svc.fetchMyStuff() }
//    }
//}

// MARK: Convenience helpers (align with TrashDTO)

extension CKTrashItem {
    var cityText: String { city }
    var mapCoordinate: CLLocationCoordinate2D? { coordinate }
}

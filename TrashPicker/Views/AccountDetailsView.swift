//
//  AccountDetailsView.swift
//  TrashPicker
//
//  Account details editing view for user profile
//

import SwiftUI
import PhotosUI
import UIKit
import LocalAuthentication

private let deleteButtonCornerRadius: CGFloat = 99

struct AccountDetailsView: View {
    @EnvironmentObject var svc: SupabaseService
    @Environment(\.dismiss) private var dismiss
    
    @State private var fullName: String = ""
    @State private var email: String = ""
    @State private var phone: String = ""

    @State private var isLoading = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var successToast = false
    @State private var showDeleteConfirmation = false
    @State private var isDeletingAccount = false
    @State private var didLogDeleteCancel = false
    @State private var canAuthenticateWithDevice = false
    @State private var biometricType: LABiometryType = .none
    @State private var deleteSheetHeight: CGFloat = 0
    
    // Track initial values to detect changes
    @State private var initialFullName = ""
    @State private var initialPhone = ""
    
    // Track if user has uploads from home (requires phone)
    @State private var hasHomeUploads = false
    
    // Photo picker
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var profileImage: Image?

    @State private var oldPassword: String = ""
    @State private var newPassword: String = ""
    @State private var confirmPassword: String = ""
    @State private var passwordError: String?
    @State private var passwordSuccess: String?
    @State private var isUpdatingPassword = false
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    headerSection
                    personalInformationSection
                    accountInformationSection
                    changePasswordSection
                    deleteAccountButton
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("User Information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Task { await saveProfile() }
                    }
                    .font(AppFont.body.weight(.semibold))
                    .foregroundColor(hasChanges ? AppColor.brandGreen : AppColor.muted)
                    .disabled(isLoading || !isFormValid || !hasChanges || isDeletingAccount)
                }
            }
            .overlay {
                if isLoading || isDeletingAccount {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    
                    ProgressView(isDeletingAccount ? "Deleting account…" : "Saving…")
                        .padding()
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 8)
                }
            }
            .overlay(alignment: .bottom) {
                if successToast {
                    Text("Profile updated!")
                        .font(AppFont.body.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(AppColor.brandGreen)
                        .clipShape(Capsule())
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlayPreferenceValue(DeleteButtonAnchorKey.self) { anchor in
                GeometryReader { proxy in
                    if let anchor, showDeleteConfirmation, !isRegularWidth {
                        let rect = proxy[anchor]
                        let measuredHeight = deleteSheetHeight > 0 ? deleteSheetHeight : 220
                        ZStack {
                            Color.black.opacity(0.001)
                                .ignoresSafeArea()
                                .onTapGesture { cancelDeleteFlow() }
                            DeleteAccountSheet(
                                message: "This permanently deletes your profile, posts, and reservations.",
                                confirmTitle: biometricButtonTitle,
                                cancelTitle: "Cancel",
                                confirmIconName: biometricIconName,
                                cornerRadius: deleteButtonCornerRadius,
                                isDeleting: isDeletingAccount,
                                canConfirm: canAuthenticateWithDevice && !isDeletingAccount,
                                onConfirm: confirmDeleteWithBiometrics,
                                onCancel: cancelDeleteFlow
                            )
                            .frame(maxWidth: min(proxy.size.width - 32, 360))
                            .background(
                                GeometryReader { sheetProxy in
                                    Color.clear
                                        .onAppear {
                                            let height = sheetProxy.size.height
                                            if abs(deleteSheetHeight - height) > 0.5 {
                                                deleteSheetHeight = height
                                            }
                                        }
                                        .onChange(of: sheetProxy.size.height) { newHeight in
                                            if abs(deleteSheetHeight - newHeight) > 0.5 {
                                                deleteSheetHeight = newHeight
                                            }
                                        }
                                }
                            )
                            .position(
                                x: rect.midX,
                                y: min(
                                    rect.maxY + measuredHeight / 2 + 12,
                                    proxy.size.height - measuredHeight / 2 - proxy.safeAreaInsets.bottom - 16
                                )
                            )
                            .transition(.opacity.combined(with: .scale))
                        }
                    }
                }
            }
        }
        .task {
            await loadCurrentProfile()
            updateBiometricAvailability()
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
        .onChange(of: selectedPhoto) { _, newPhoto in
            guard let newPhoto else { return }
            Task(priority: TaskPriority.userInitiated) {
                await loadSelectedPhoto(newPhoto)
            }
        }
        .onChange(of: oldPassword) { _ in
            passwordError = nil
        }
        .onChange(of: newPassword) { _ in
            passwordError = nil
        }
        .onChange(of: confirmPassword) { _ in
            passwordError = nil
        }
    }

    // MARK: - Sections
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            profilePictureSection

            if let since = memberSinceText {
                Text("Member since \(since)")
                    .font(AppFont.sub)
                    .foregroundColor(AppColor.muted)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var profilePictureSection: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let profileImage {
                    profileImage
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 120, height: 120)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(AppColor.brandGreen, lineWidth: 4))
                } else {
                    Circle()
                        .stroke(AppColor.brandGreen, lineWidth: 4)
                        .frame(width: 120, height: 120)
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 54))
                                .foregroundColor(AppColor.brandGreen)
                        )
                }
            }

            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(AppColor.brandGreen)
                    .background(Color(.systemBackground))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: 6)
        }
        .frame(maxWidth: .infinity)
    }
    
    private var personalInformationSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            labeledField("Name") {
                TextField("Your name", text: $fullName)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                    .textContentType(.name)
                    .font(AppFont.body)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 14).stroke(AppColor.brandGreen, lineWidth: 1))
            }
            
            labeledField("Phone number") {
                TextField("Enter phone number", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .font(AppFont.body)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 14).stroke(AppColor.brandGreen, lineWidth: 1))
            }
            
            Text(hasHomeUploads ? "Phone number required for home listings." : "Optional")
                .font(AppFont.caption)
                .foregroundColor(AppColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var accountInformationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeledField("Email") {
                Text(email.isEmpty ? "No email" : email)
                    .font(AppFont.body)
                    .foregroundColor(AppColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 14).stroke(AppColor.brandGreen, lineWidth: 1))
            }
            
            Text("Email cannot be changed. Contact support if you need to update it.")
                .font(AppFont.caption)
                .foregroundColor(AppColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var changePasswordSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Change Password")
                    .font(AppFont.body.weight(.semibold))
                    .foregroundColor(AppColor.text)
                Spacer()
                Button("Forgot password?") {
                    Task { await sendPasswordReset() }
                }
                .font(AppFont.sub)
                .foregroundColor(AppTheme.ColorToken.accent)
                .disabled(isUpdatingPassword || isLoading)
            }
            
            labeledField("Old password") {
                SecureField("Enter current password", text: $oldPassword)
                    .font(AppFont.body)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 14).stroke(AppColor.brandGreen, lineWidth: 1))
            }
            
            labeledField("New password") {
                SecureField("Enter new password", text: $newPassword)
                    .font(AppFont.body)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 14).stroke(AppColor.brandGreen, lineWidth: 1))
            }
            
            labeledField("Repeat new password") {
                SecureField("Confirm new password", text: $confirmPassword)
                    .font(AppFont.body)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 14).stroke(AppColor.brandGreen, lineWidth: 1))
            }
            
            if let passwordError {
                Text(passwordError)
                    .font(AppFont.sub)
                    .foregroundColor(AppTheme.ColorToken.danger)
            }
            
            if let passwordSuccess {
                Text(passwordSuccess)
                    .font(AppFont.sub)
                    .foregroundColor(AppColor.brandGreen)
            }
            
            Button {
                Task { await updatePassword() }
            } label: {
                HStack {
                    Spacer()
                    if isUpdatingPassword {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Update Password")
                            .font(AppFont.label)
                            .foregroundColor(.white)
                    }
                    Spacer()
                }
                .padding(.vertical, 14)
                .background(AppColor.brandGreen)
                .clipShape(RoundedRectangle(cornerRadius: 99))
            }
            .buttonStyle(.plain)
            .disabled(isUpdatingPassword || isLoading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var deleteAccountButton: some View {
        let isRegular = isRegularWidth
        return Button(action: handleDeleteTapped) {
            HStack {
                Spacer()
                if isDeletingAccount {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Delete Account")
                        .font(AppFont.label)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
                Spacer()
            }
            .padding(.vertical, 14)
            .background(AppTheme.ColorToken.danger)
            .clipShape(RoundedRectangle(cornerRadius: deleteButtonCornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(isLoading || isDeletingAccount)
        .opacity(isLoading ? 0.7 : 1.0)
        .accessibilityLabel("Delete account")
        .background(
            GeometryReader { _ in
                Color.clear
                    .anchorPreference(key: DeleteButtonAnchorKey.self, value: .bounds) { anchor in anchor }
            }
        )
        .popover(
            isPresented: Binding(
                get: { showDeleteConfirmation && isRegular },
                set: { newValue in
                    if !newValue {
                        cancelDeleteFlow()
                    }
                }
            ),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            DeleteAccountSheet(
                message: "This permanently deletes your profile, posts, and reservations.",
                confirmTitle: biometricButtonTitle,
                cancelTitle: "Cancel",
                confirmIconName: biometricIconName,
                cornerRadius: deleteButtonCornerRadius,
                isDeleting: isDeletingAccount,
                canConfirm: canAuthenticateWithDevice && !isDeletingAccount,
                onConfirm: confirmDeleteWithBiometrics,
                onCancel: cancelDeleteFlow
            )
            .frame(maxWidth: 360)
        }
    }
    
    @ViewBuilder
    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(AppFont.body.weight(.semibold))
                .foregroundColor(AppColor.text)
            content()
        }
    }
    
    
    // MARK: - Computed Properties
    
    private var memberSinceText: String? {
        guard let date = svc.memberSince else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }
    
    private var biometricButtonTitle: String {
        switch biometricType {
        case .faceID:
            return "Confirm with Face ID"
        case .touchID:
            return "Confirm with Touch ID"
        default:
            return "Confirm with Passcode"
        }
    }

    private var biometricIconName: String {
        switch biometricType {
        case .faceID:
            return "faceid"
        case .touchID:
            return "touchid"
        default:
            return "key.fill"
        }
    }
    
    private var isRegularWidth: Bool {
        horizontalSizeClass == .regular
    }
    
    private var isFormValid: Bool {
        // First name is required
        !fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        // Phone is required if user has home uploads
        (!hasHomeUploads || !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    
    private var hasChanges: Bool {
        fullName.trimmingCharacters(in: .whitespacesAndNewlines) != initialFullName.trimmingCharacters(in: .whitespacesAndNewlines) ||
        phone.trimmingCharacters(in: .whitespacesAndNewlines) != initialPhone.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Methods

    private func sendPasswordReset() async {
        guard !email.isEmpty else {
            passwordError = "No email associated with this account."
            return
        }
        passwordError = nil
        passwordSuccess = nil
        do {
            try await svc.sendPasswordResetEmail()
            passwordSuccess = "Check your email for a reset link."
        } catch {
            if let simple = error as? SimpleError {
                passwordError = simple.message
            } else {
                passwordError = "Couldn't send reset email. Try again later."
            }
        }
    }

    private func updatePassword() async {
        let trimmedOld = oldPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNew = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedConfirm = confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        passwordError = nil
        passwordSuccess = nil
        guard !trimmedOld.isEmpty else {
            passwordError = "Enter your current password."
            return
        }
        guard trimmedNew.count >= 6 else {
            passwordError = "New password must be at least 6 characters."
            return
        }
        guard trimmedNew == trimmedConfirm else {
            passwordError = "New passwords do not match."
            return
        }
        guard trimmedNew != trimmedOld else {
            passwordError = "Choose a different password than your current one."
            return
        }
        isUpdatingPassword = true
        defer { isUpdatingPassword = false }
        do {
            try await svc.updatePassword(currentPassword: trimmedOld, newPassword: trimmedNew)
            passwordSuccess = "Password updated successfully."
            oldPassword = ""
            newPassword = ""
            confirmPassword = ""
        } catch {
            if let simple = error as? SimpleError {
                passwordError = simple.message
            } else {
                passwordError = "Couldn't update password. Try again."
            }
        }
    }

    private func handleDeleteTapped() {
        guard !isDeletingAccount, !isLoading else { return }
        playHaptic(.light)
        logDeleteTapped()
        didLogDeleteCancel = false
        deleteSheetHeight = 0
        showDeleteConfirmation = true
    }
    
    private func confirmDeleteWithBiometrics() {
        guard canAuthenticateWithDevice, !isDeletingAccount else { return }
        Task {
            do {
                try await BiometricAuth.authenticate(reason: "Confirm deleting your TrashPicker account.")
                await MainActor.run {
                    playHaptic(.heavy)
                }
                await performDelete()
            } catch {
                handleAuthenticationError(error)
            }
        }
    }
    
    private func cancelDeleteFlow() {
        guard showDeleteConfirmation, !isDeletingAccount else { return }
        showDeleteConfirmation = false
        deleteSheetHeight = 0
        logDeleteCanceled()
    }
    
    @MainActor
    private func performDelete() async {
        guard !isDeletingAccount else { return }
        isDeletingAccount = true
        logDeleteConfirmed()
        
        let fallbackMessage = "Couldn't delete your account right now. Please try again."
        
        defer {
            isDeletingAccount = false
        }
        
        do {
            _ = try await svc.deleteAccount()
            showDeleteConfirmation = false
            deleteSheetHeight = 0
            await svc.finalizeAccountDeletion()
        } catch {
            if error.isCancellationLike {
                errorMessage = fallbackMessage
            } else if let simple = error as? SimpleError {
                errorMessage = simple.localizedDescription ?? fallbackMessage
            } else {
                let nsError = error as NSError
                let derived = nsError.localizedDescription
                errorMessage = derived.isEmpty || derived == "(null)" ? fallbackMessage : derived
            }
            
            showingError = true
        }
    }
    
    private func handleAuthenticationError(_ error: Error) {
        if let laError = error as? LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback:
                return
            case .biometryLockout, .biometryNotEnrolled, .biometryNotAvailable:
                canAuthenticateWithDevice = false
                biometricType = .none
                fallthrough
            default:
                errorMessage = laError.localizedDescription.isEmpty ? "Face ID could not verify you. Try again." : laError.localizedDescription
                showingError = true
            }
        } else {
            errorMessage = "Face ID could not verify you. Try again."
            showingError = true
        }
    }
    
    private func updateBiometricAvailability() {
        let context = LAContext()
        var error: NSError?
        let available = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        canAuthenticateWithDevice = available
        biometricType = BiometricAuth.availableBiometryType()
    }
    
    private func logDeleteTapped() {
        DLog("[METRIC] settings_delete_tapped")
    }
    
    private func logDeleteCanceled() {
        guard !didLogDeleteCancel else { return }
        didLogDeleteCancel = true
        DLog("[METRIC] settings_delete_canceled")
    }
    
    private func logDeleteConfirmed() {
        DLog("[METRIC] settings_delete_confirmed")
    }
    
    private func playHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
    
    @MainActor
    private func loadCurrentProfile() async {
        guard let session = svc.session else { return }
        
        // Load current user data
        email = session.user.email ?? ""
        
        // Parse full name into first and last name
        // Compose full name from available metadata
        let metaFull = session.user.userMetadata["full_name"]?.description ?? ""
        let metaName = session.user.userMetadata["name"]?.description ?? ""
        let first = session.user.userMetadata["first_name"]?.description ?? ""
        let last = session.user.userMetadata["last_name"]?.description ?? ""
        let derivedFullName: String
        if !metaFull.isEmpty {
            derivedFullName = metaFull
        } else if !metaName.isEmpty {
            derivedFullName = metaName
        } else if !first.isEmpty || !last.isEmpty {
            derivedFullName = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        } else {
            derivedFullName = ""
        }
        fullName = derivedFullName
        
        // Load phone
        phone = session.user.userMetadata["phone"]?.description ?? ""
        
        // Store initial values
        initialFullName = fullName
        initialPhone = phone
        
        // Check if user has home uploads (would require phone)
        // For now, we'll assume false since we don't have the data structure
        hasHomeUploads = false
    }
    
    @MainActor
    private func saveProfile() async {
        isLoading = true
        
        do {
            let trimmedFullName = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            var parsedFirstName = ""
            var parsedLastName: String? = nil
            if !trimmedFullName.isEmpty {
                let parts = trimmedFullName.split(separator: " ")
                if let firstPart = parts.first {
                    parsedFirstName = String(firstPart)
                }
                let remainder = parts.dropFirst().joined(separator: " ")
                parsedLastName = remainder.isEmpty ? nil : remainder
            }
            let trimmedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
            
            try await svc.updateProfile(
                firstName: parsedFirstName,
                lastName: parsedLastName,
                phone: trimmedPhone
            )
            
            // Update initial values after successful save
            initialFullName = fullName
            initialPhone = phone
            
            // Show success toast
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                successToast = true
            }
            
            // Hide toast after 2 seconds and dismiss
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    successToast = false
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                dismiss()
            }
            
        } catch {
            errorMessage = "Couldn't save your changes. Please try again."
            
            #if DEBUG
            DLog("[PROFILE] Save error: \(error.localizedDescription)")
            #endif
            
            // Show more specific error if available
            if let simpleError = error as? SimpleError {
                errorMessage = simpleError.message
            } else if error.localizedDescription.contains("401") || error.localizedDescription.contains("unauthorized") {
                errorMessage = "Please sign in again to continue."
            }
            
            showingError = true
        }
        
        isLoading = false
    }
    
    @MainActor
    private func loadSelectedPhoto(_ photo: PhotosPickerItem) async {
        do {
            if let data = try await photo.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                profileImage = Image(uiImage: uiImage)
            }
        } catch {
            errorMessage = "Couldn't load that photo. Please try another."
            showingError = true
        }
    }
}

private struct DeleteButtonAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

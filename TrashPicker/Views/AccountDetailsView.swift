//
//  AccountDetailsView.swift
//  TrashPicker
//
//  Account details editing view for user profile
//

import SwiftUI
import PhotosUI
import UIKit

struct AccountDetailsView: View {
    @EnvironmentObject var svc: SupabaseService
    @Environment(\.dismiss) private var dismiss
    
    @State private var firstName: String = ""
    @State private var lastName: String = ""
    @State private var email: String = ""
    @State private var phone: String = ""
    
    @State private var isLoading = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showingSuccess = false
    
    // Track if user has uploads from home (requires phone)
    @State private var hasHomeUploads = false
    
    // Photo picker
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var profileImage: Image?
    
    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Profile Picture Section
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            // Profile image or placeholder
                            Group {
                                if let profileImage = profileImage {
                                    profileImage
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 80, height: 80)
                                        .clipShape(Circle())
                                } else {
                                    Image(systemName: "person.circle.fill")
                                        .font(.system(size: 80))
                                        .foregroundColor(AppColor.brandGreen)
                                }
                            }
                            
                            PhotosPicker("Change Photo", selection: $selectedPhoto, matching: .images)
                                .font(AppFont.sub)
                                .foregroundColor(AppColor.brandGreen)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Profile Picture")
                        .font(AppFont.h2)
                }
                
                // MARK: - Personal Information Section
                Section {
                    // First Name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("First Name")
                            .font(AppFont.body)
                            .foregroundColor(AppColor.text)
                        
                        TextField("Enter first name", text: $firstName)
                            .font(AppFont.body)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    
                    // Last Name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last Name")
                            .font(AppFont.body)
                            .foregroundColor(AppColor.text)
                        
                        TextField("Enter last name", text: $lastName)
                            .font(AppFont.body)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    
                    // Phone Number
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Phone")
                            .font(AppFont.body)
                            .foregroundColor(AppColor.text)
                        
                        TextField("Enter phone number", text: $phone)
                            .font(AppFont.body)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .keyboardType(.phonePad)
                        
                        if hasHomeUploads {
                            Text("Required for home listings")
                                .font(AppFont.caption)
                                .foregroundColor(AppColor.muted)
                        } else {
                            Text("Optional")
                                .font(AppFont.caption)
                                .foregroundColor(AppColor.muted)
                        }
                    }
                    
                } header: {
                    Text("Personal Information")
                        .font(AppFont.h2)
                }
                
                // MARK: - Account Information Section
                Section {
                    // Email (read-only)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Email")
                            .font(AppFont.body)
                            .foregroundColor(AppColor.text)
                        
                        Text(email)
                            .font(AppFont.body)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemGray5))
                            .foregroundColor(AppColor.muted)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    
                } header: {
                    Text("Account Information")
                        .font(AppFont.h2)
                } footer: {
                    Text("Email cannot be changed. Contact support if you need to update your email address.")
                        .font(AppFont.caption)
                        .foregroundColor(AppColor.muted)
                }
            }
            .navigationTitle("Account Details")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .font(AppFont.body)
                    .foregroundColor(AppColor.brandGreen)
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Task { await saveProfile() }
                    }
                    .font(AppFont.body.weight(.semibold))
                    .foregroundColor(AppColor.brandGreen)
                    .disabled(isLoading || !isFormValid)
                }
            }
            .overlay {
                if isLoading {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    
                    ProgressView("Saving...")
                        .padding()
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 8)
                }
            }
        }
        .task {
            await loadCurrentProfile()
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
        .alert("Success", isPresented: $showingSuccess) {
            Button("OK") {
                dismiss()
            }
        } message: {
            Text("Profile updated successfully!")
        }
        .onChange(of: selectedPhoto) { _, newPhoto in
            guard let newPhoto else { return }
            Task(priority: TaskPriority.userInitiated) {
                await loadSelectedPhoto(newPhoto)
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var isFormValid: Bool {
        // First name is required
        !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        // Phone is required if user has home uploads
        (!hasHomeUploads || !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    
    // MARK: - Methods
    
    @MainActor
    private func loadCurrentProfile() async {
        guard let session = svc.session else { return }
        
        // Load current user data
        email = session.user.email ?? ""
        
        // Parse full name into first and last name
        let fullName = session.user.userMetadata["full_name"]?.description
            ?? session.user.userMetadata["name"]?.description
            ?? ""
        
        let nameComponents = fullName.components(separatedBy: " ")
        if !nameComponents.isEmpty {
            firstName = nameComponents.first ?? ""
            if nameComponents.count > 1 {
                lastName = nameComponents.dropFirst().joined(separator: " ")
            }
        }
        
        // Load phone
        phone = session.user.userMetadata["phone"]?.description ?? ""
        
        // Check if user has home uploads (would require phone)
        // For now, we'll assume false since we don't have the data structure
        hasHomeUploads = false
    }
    
    @MainActor
    private func saveProfile() async {
        isLoading = true
        
        do {
            try await svc.updateProfile(
                firstName: firstName.trimmingCharacters(in: .whitespacesAndNewlines),
                lastName: lastName.trimmingCharacters(in: .whitespacesAndNewlines),
                phone: phone.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            
            showingSuccess = true
        } catch {
            errorMessage = error.localizedDescription
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
            errorMessage = "Failed to load selected photo"
            showingError = true
        }
    }
}


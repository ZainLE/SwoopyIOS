# UI Test Setup Guide for TrashPicker

This guide walks you through setting up UI tests with mock API support.

## Step 1: Create UI Test Target

1. **Open Xcode** → Select TrashPicker project
2. **File** → **New** → **Target**
3. Select **iOS** → **UI Testing Bundle**
4. Name it: `TrashPickerUITests`
5. Language: Swift
6. Click **Finish**

## Step 2: Configure Test Target

1. Select **TrashPickerUITests** target
2. Go to **Build Settings**
3. Search for "Test Host"
4. Ensure it points to: `$(BUILT_PRODUCTS_DIR)/TrashPicker.app/TrashPicker`

## Step 3: Add Mock Files to Test Target

1. **Select MockApiService.swift** in Project Navigator
2. Open **File Inspector** (right panel)
3. Under **Target Membership**, check:
   - ✅ TrashPickerTests
   - ✅ TrashPickerUITests
   - ❌ TrashPicker (should NOT be checked)

4. **Repeat for AppConfiguration.swift**:
   - ✅ TrashPicker (main app needs this)
   - ✅ TrashPickerTests
   - ✅ TrashPickerUITests

## Step 4: Update TrashPickerApp.swift

Replace the current `TrashPickerApp` struct with:

```swift
import SwiftUI
import UIKit

@main
struct TrashPickerApp: App {
    init() {
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: UIColor.label]
        AppearanceEnforcer.forceLight()
    }

    // Use mock services when -USE_MOCK_API YES is set
    @StateObject private var svc: SupabaseService = {
        if AppConfiguration.useMockAPI {
            return MockSupabaseService()
        }
        return SupabaseService.shared
    }()
    
    @StateObject private var api: ApiService = {
        if AppConfiguration.useMockAPI {
            let mockSvc = MockSupabaseService()
            return MockApiService(supabaseService: mockSvc)
        }
        return ApiService(supabaseService: SupabaseService.shared)
    }()
    
    @StateObject private var ck = CKTrashService()
    @StateObject private var draftStore = UploadDraftStore()

    var body: some Scene {
        WindowGroup {
            RootGateView()
                .environmentObject(svc)
                .environmentObject(api)
                .environmentObject(ck)
                .environmentObject(draftStore)
                .onOpenURL { url in
                    Task {
                        await svc.handleOAuthRedirect(url)
                    }
                }
                .tint(AppTheme.ColorToken.primary)
                .preferredColorScheme(.light)
        }
    }
}

private struct RootGateView: View {
    @EnvironmentObject var svc: SupabaseService

    var body: some View {
        Group {
            if !svc.didCheckSession {
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()
                    Image("SwoopyLogo")
                        .resizable().scaledToFit()
                        .frame(width: 140, height: 140)
                }
            } else if svc.isAuthenticated && ((svc.currentAccessTokenOrNil() ?? "").isEmpty == false) {
                RootView()
            } else {
                AuthView()
            }
        }
    }
}
```

## Step 5: Add UI Test File

Copy the contents of `TrashPickerUITests.swift` (provided separately) to:
`TrashPickerUITests/TrashPickerUITests.swift`

## Step 6: Run UI Tests

### Via Xcode:
1. Select **TrashPickerUITests** scheme
2. Press **Cmd+U** or Product → Test

### Via Command Line:
```bash
xcodebuild test \
  -scheme TrashPicker \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:TrashPickerUITests
```

## Step 7: Verify Mock API is Working

The UI test will:
1. ✅ Launch with `-USE_MOCK_API YES`
2. ✅ Skip auth (mock is already "signed in")
3. ✅ Show feed with mock posts
4. ✅ Display "Vintage Desk" card
5. ✅ Allow post creation
6. ✅ Show reservations

## Troubleshooting

### Issue: "MockApiService not found"
**Solution**: Ensure MockApiService.swift is added to TrashPickerUITests target membership.

### Issue: "AppConfiguration not found"
**Solution**: Ensure AppConfiguration.swift is added to both TrashPicker and TrashPickerUITests targets.

### Issue: Test times out
**Solution**: Increase timeout in test or check simulator performance.

### Issue: Elements not found
**Solution**: Check accessibility identifiers match between app and test.

## Adding Accessibility Identifiers

For better test reliability, add these to your views:

```swift
// In SwipeDeckView
Text(post.title)
    .accessibilityIdentifier("feedCard_\(post.id)")

// In UploadFindView
Button("Submit") { ... }
    .accessibilityIdentifier("uploadSubmitButton")

// In ReservationsView
ForEach(reservations) { reservation in
    // ...
}
.accessibilityIdentifier("reservationRow_\(reservation.id)")
```

## Next Steps

1. Add more UI tests for different flows
2. Add accessibility identifiers to key UI elements
3. Create additional mock fixtures for edge cases
4. Set up CI/CD to run UI tests automatically

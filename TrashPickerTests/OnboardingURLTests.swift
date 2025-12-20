import XCTest
@testable import TrashPicker

/// Tests to verify onboarding API URLs are correctly constructed
final class OnboardingURLTests: XCTestCase {
    
    func testAPIBaseURL() {
        // Verify base URL is exactly as specified
        XCTAssertEqual(
            SupabaseConfig.apiBaseURL,
            "https://api.swoopy.eu/custom-api",
            "API base URL must be exactly 'https://api.swoopy.eu/custom-api' with no trailing slash"
        )
    }
    
    func testProfilePhotoUploadURL() {
        // Verify photo upload endpoint
        let expectedURL = "https://api.swoopy.eu/custom-api/me/profile/photo"
        let constructedURL = SupabaseConfig.apiBaseURL + "/me/profile/photo"
        
        XCTAssertEqual(
            constructedURL,
            expectedURL,
            "Photo upload URL must be exactly '\(expectedURL)'"
        )
        
        // Ensure no double /custom-api
        XCTAssertFalse(
            constructedURL.contains("/custom-api/custom-api"),
            "URL must not contain duplicate /custom-api segments"
        )
    }
    
    func testProfileUpdateURL() {
        // Verify profile update endpoint
        let expectedURL = "https://api.swoopy.eu/custom-api/me/profile"
        let constructedURL = SupabaseConfig.apiBaseURL + "/me/profile"
        
        XCTAssertEqual(
            constructedURL,
            expectedURL,
            "Profile update URL must be exactly '\(expectedURL)'"
        )
        
        // Ensure no double /custom-api
        XCTAssertFalse(
            constructedURL.contains("/custom-api/custom-api"),
            "URL must not contain duplicate /custom-api segments"
        )
    }
    
    func testOnboardingCompleteURL() {
        // Verify onboarding complete endpoint
        let expectedURL = "https://api.swoopy.eu/custom-api/me/onboarding/complete"
        let constructedURL = SupabaseConfig.apiBaseURL + "/me/onboarding/complete"
        
        XCTAssertEqual(
            constructedURL,
            expectedURL,
            "Onboarding complete URL must be exactly '\(expectedURL)'"
        )
        
        // Ensure no double /custom-api
        XCTAssertFalse(
            constructedURL.contains("/custom-api/custom-api"),
            "URL must not contain duplicate /custom-api segments"
        )
    }
    
    func testPhoneOTPSendURL() {
        let expectedURL = "https://api.swoopy.eu/custom-api/me/phone/otp/send"
        let constructedURL = SupabaseConfig.apiBaseURL + "/me/phone/otp/send"
        
        XCTAssertEqual(constructedURL, expectedURL, "Phone OTP send URL must be exactly '\(expectedURL)'")
        XCTAssertFalse(constructedURL.contains("/custom-api/custom-api"))
    }
    
    func testPhoneOTPVerifyURL() {
        let expectedURL = "https://api.swoopy.eu/custom-api/me/phone/otp/verify"
        let constructedURL = SupabaseConfig.apiBaseURL + "/me/phone/otp/verify"
        
        XCTAssertEqual(constructedURL, expectedURL, "Phone OTP verify URL must be exactly '\(expectedURL)'")
        XCTAssertFalse(constructedURL.contains("/custom-api/custom-api"))
    }
    
    func testNoTrailingSlashInBaseURL() {
        // Verify base URL has no trailing slash
        XCTAssertFalse(
            SupabaseConfig.apiBaseURL.hasSuffix("/"),
            "API base URL must not have a trailing slash"
        )
    }
    
    func testAllEndpointsStartWithSlash() {
        // Verify all path components start with /
        let paths = [
            "/me/profile/photo",
            "/me/profile",
            "/me/onboarding/complete"
        ]
        
        for path in paths {
            XCTAssertTrue(
                path.hasPrefix("/"),
                "Path '\(path)' must start with /"
            )
        }
    }
}

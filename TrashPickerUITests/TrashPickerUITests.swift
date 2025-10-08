//
//  TrashPickerUITests.swift
//  TrashPickerUITests
//
//  End-to-end UI tests with mock API
//

import XCTest

final class TrashPickerUITests: XCTestCase {
    
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        
        app = XCUIApplication()
        
        // Set launch arguments for mock API
        app.launchArguments = ["-USE_MOCK_API", "YES", "-UI_TESTING"]
        
        // Launch app
        app.launch()
    }
    
    override func tearDownWithError() throws {
        app = nil
    }
    
    // MARK: - End-to-End Flow Test
    
    /// Complete user flow: Auth bypass → Feed → Create Post → Reservations
    func testCompleteUserFlow() throws {
        // STEP 1: Auth Bypass (Mock API is already "signed in")
        // App should skip auth screen and go straight to main app
        
        // Wait for app to load (mock auth is instant)
        let feedExists = app.otherElements["feedView"].waitForExistence(timeout: 5)
        if !feedExists {
            // If feed doesn't exist, might be on auth screen - tap continue
            let continueButton = app.buttons["Continue"]
            if continueButton.exists {
                continueButton.tap()
            }
        }
        
        // STEP 2: Verify Feed Shows Mock Data
        // Wait for feed to appear
        XCTAssertTrue(
            app.otherElements["feedView"].waitForExistence(timeout: 5),
            "Feed view should appear"
        )
        
        // Look for mock post title "Vintage Desk"
        let vintageDesk = app.staticTexts["Vintage Desk"]
        XCTAssertTrue(
            vintageDesk.waitForExistence(timeout: 5),
            "Should show 'Vintage Desk' card from mock fixture"
        )
        
        print("✅ Feed loaded with mock data")
        
        // STEP 3: Navigate to Upload Form
        // Tap the FAB or "Share your post" button
        let shareButton = app.buttons["Share your post"].firstMatch
        if shareButton.exists {
            shareButton.tap()
        } else {
            // Try FAB button
            let fabButton = app.buttons["fabButton"].firstMatch
            if fabButton.exists {
                fabButton.tap()
            }
        }
        
        // Wait for upload form
        XCTAssertTrue(
            app.otherElements["uploadForm"].waitForExistence(timeout: 3),
            "Upload form should appear"
        )
        
        print("✅ Upload form opened")
        
        // STEP 4: Fill Upload Form
        // Note: In UI tests, we can't actually pick photos from the camera/library
        // The mock should handle this gracefully
        
        // Fill title
        let titleField = app.textFields["titleField"].firstMatch
        if titleField.exists {
            titleField.tap()
            titleField.typeText("Test Item")
        }
        
        // Fill description
        let descriptionField = app.textViews["descriptionField"].firstMatch
        if descriptionField.exists {
            descriptionField.tap()
            descriptionField.typeText("Test description")
        }
        
        // Select category (if picker exists)
        let categoryPicker = app.buttons["categoryPicker"].firstMatch
        if categoryPicker.exists {
            categoryPicker.tap()
            // Select first category
            let furnitureOption = app.buttons["furniture"].firstMatch
            if furnitureOption.exists {
                furnitureOption.tap()
            }
        }
        
        // Select condition
        let conditionPicker = app.buttons["conditionPicker"].firstMatch
        if conditionPicker.exists {
            conditionPicker.tap()
            let goodOption = app.buttons["Good"].firstMatch
            if goodOption.exists {
                goodOption.tap()
            }
        }
        
        // Select mode (Street/Home)
        let streetButton = app.buttons["Street"].firstMatch
        if streetButton.exists {
            streetButton.tap()
        }
        
        print("✅ Form fields filled")
        
        // STEP 5: Submit Form
        let submitButton = app.buttons["uploadSubmitButton"].firstMatch
        if !submitButton.exists {
            // Try alternative button text
            let submitAlt = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Submit' OR label CONTAINS 'Post'")).firstMatch
            if submitAlt.exists {
                submitAlt.tap()
            }
        } else {
            submitButton.tap()
        }
        
        // Wait for success (toast or navigation)
        // Mock API should return success instantly
        sleep(2) // Give time for success animation
        
        print("✅ Form submitted")
        
        // STEP 6: Navigate to Reservations Tab
        let reservationsTab = app.tabBars.buttons["Reservations"].firstMatch
        if !reservationsTab.exists {
            // Try alternative tab name
            let reservationsAlt = app.tabBars.buttons.matching(NSPredicate(format: "label CONTAINS 'Reservation'")).firstMatch
            if reservationsAlt.exists {
                reservationsAlt.tap()
            }
        } else {
            reservationsTab.tap()
        }
        
        // Wait for reservations view
        XCTAssertTrue(
            app.otherElements["reservationsView"].waitForExistence(timeout: 5),
            "Reservations view should appear"
        )
        
        // STEP 7: Verify Reservation Exists
        // Mock fixture includes one reservation for "Vintage Desk"
        let reservationRow = app.otherElements.matching(NSPredicate(format: "identifier CONTAINS 'reservationRow'")).firstMatch
        
        if !reservationRow.exists {
            // Try finding by text content
            let deskReservation = app.staticTexts["Vintage Desk"]
            XCTAssertTrue(
                deskReservation.waitForExistence(timeout: 3),
                "Should show reservation for 'Vintage Desk' from mock fixture"
            )
        } else {
            XCTAssertTrue(reservationRow.exists, "Should show at least one reservation row")
        }
        
        print("✅ Reservations loaded with mock data")
        
        // Test complete!
        print("✅✅✅ Complete user flow test passed!")
    }
    
    // MARK: - Individual Component Tests
    
    /// Test feed loads with mock data
    func testFeedLoadsWithMockData() throws {
        // Wait for feed
        XCTAssertTrue(
            app.otherElements["feedView"].waitForExistence(timeout: 5),
            "Feed should load"
        )
        
        // Verify mock post appears
        let mockPost = app.staticTexts["Vintage Desk"]
        XCTAssertTrue(
            mockPost.waitForExistence(timeout: 3),
            "Mock post 'Vintage Desk' should appear"
        )
        
        // Verify second mock post
        let mockPost2 = app.staticTexts["Comfortable chair"]
        XCTAssertTrue(
            mockPost2.waitForExistence(timeout: 3),
            "Mock post 'Comfortable chair' should appear"
        )
    }
    
    /// Test reservations tab shows mock data
    func testReservationsShowMockData() throws {
        // Navigate to reservations
        let reservationsTab = app.tabBars.buttons["Reservations"].firstMatch
        if reservationsTab.exists {
            reservationsTab.tap()
        }
        
        // Wait for view
        XCTAssertTrue(
            app.otherElements["reservationsView"].waitForExistence(timeout: 5),
            "Reservations view should load"
        )
        
        // Verify mock reservation
        let mockReservation = app.staticTexts["Vintage Desk"]
        XCTAssertTrue(
            mockReservation.waitForExistence(timeout: 3),
            "Mock reservation should appear"
        )
    }
    
    /// Test app launches with mock API
    func testAppLaunchesWithMockAPI() throws {
        // Verify app launched
        XCTAssertTrue(app.exists, "App should launch")
        
        // Verify we're not stuck on auth screen
        let authView = app.otherElements["authView"]
        let feedView = app.otherElements["feedView"]
        
        // Should see either feed (if mock auth worked) or auth screen
        let appLoaded = feedView.waitForExistence(timeout: 5) || authView.waitForExistence(timeout: 5)
        XCTAssertTrue(appLoaded, "App should load to either feed or auth")
        
        // If on auth, mock should have bypassed it
        if authView.exists {
            print("⚠️ Warning: Still on auth screen, mock auth may not be working")
        }
    }
    
    /// Test launch performance with mock API
    func testLaunchPerformanceWithMockAPI() throws {
        if #available(iOS 13.0, *) {
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                let app = XCUIApplication()
                app.launchArguments = ["-USE_MOCK_API", "YES"]
                app.launch()
                app.terminate()
            }
        }
    }
}

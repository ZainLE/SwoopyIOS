//
//  ImageStorageTests.swift
//  TrashPickerTests
//
//  Tests for ImageStorage path generation and options
//

import XCTest
@testable import Swoopy

final class ImageStorageTests: XCTestCase {
    
    // MARK: - Path Generation Tests
    
    /// Test that uploadJPEGs builds standard paths without network calls
    /// Verifies: posts/<userId>/<postId>/<index>.jpg format
    func test_uploadJPEGs_buildsStandardPaths() throws {
        // Arrange: Create test UUIDs
        let userId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")! // U1 equivalent
        let postId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")! // P1 equivalent
        
        // Act: Generate paths for 3 images
        let path0 = ImageStorage.buildPostImagePath(userId: userId, postId: postId, index: 0)
        let path1 = ImageStorage.buildPostImagePath(userId: userId, postId: postId, index: 1)
        let path2 = ImageStorage.buildPostImagePath(userId: userId, postId: postId, index: 2)
        
        // Assert: Verify path format
        let expectedPrefix = "posts/\(userId.uuidString.lowercased())/\(postId.uuidString)"
        
        XCTAssertEqual(path0, "\(expectedPrefix)/0.jpg", "First image path should end with /0.jpg")
        XCTAssertEqual(path1, "\(expectedPrefix)/1.jpg", "Second image path should end with /1.jpg")
        XCTAssertEqual(path2, "\(expectedPrefix)/2.jpg", "Third image path should end with /2.jpg")
        
        // Verify path structure
        XCTAssertTrue(path0.hasPrefix("posts/"), "Path should start with 'posts/'")
        XCTAssertTrue(path0.contains(userId.uuidString.lowercased()), "Path should contain lowercased user ID")
        XCTAssertTrue(path0.contains(postId.uuidString), "Path should contain post ID")
        XCTAssertTrue(path0.hasSuffix(".jpg"), "Path should end with .jpg")
        
        print("✅ Path generation test passed")
        print("   Path 0: \(path0)")
        print("   Path 1: \(path1)")
        print("   Path 2: \(path2)")
    }
    
    /// Test FileOptions for JPEG uploads
    func test_buildJPEGFileOptions_hasCorrectSettings() throws {
        // Act: Get file options
        let options = ImageStorage.buildJPEGFileOptions()
        
        // Assert: Verify options
        XCTAssertEqual(options.contentType, "image/jpeg", "Content type should be image/jpeg")
        XCTAssertEqual(options.upsert, false, "Upsert should be disabled to avoid overwriting uploads")
        XCTAssertEqual(options.cacheControl, "3600", "Cache control should be 3600")
        
        print("✅ FileOptions test passed")
        print("   Content-Type: \(options.contentType ?? "nil")")
        print("   Upsert: \(options.upsert ?? false)")
        print("   Cache-Control: \(options.cacheControl ?? "nil")")
    }
    
    /// Test path generation with different user and post IDs
    func test_buildPostImagePath_withDifferentIds() throws {
        // Arrange: Create different UUIDs
        let user1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let user2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let post1 = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let post2 = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        
        // Act: Generate paths
        let path1 = ImageStorage.buildPostImagePath(userId: user1, postId: post1, index: 0)
        let path2 = ImageStorage.buildPostImagePath(userId: user2, postId: post2, index: 0)
        
        // Assert: Paths should be different
        XCTAssertNotEqual(path1, path2, "Different user/post IDs should produce different paths")
        
        // Verify structure
        XCTAssertTrue(path1.contains(user1.uuidString.lowercased()))
        XCTAssertTrue(path1.contains(post1.uuidString))
        XCTAssertTrue(path2.contains(user2.uuidString.lowercased()))
        XCTAssertTrue(path2.contains(post2.uuidString))
        
        print("✅ Different IDs test passed")
    }
    
    /// Test path generation for multiple indices
    func test_buildPostImagePath_multipleIndices() throws {
        // Arrange
        let userId = UUID()
        let postId = UUID()
        
        // Act: Generate paths for indices 0-9
        let paths = (0..<10).map { index in
            ImageStorage.buildPostImagePath(userId: userId, postId: postId, index: index)
        }
        
        // Assert: All paths should be unique
        let uniquePaths = Set(paths)
        XCTAssertEqual(uniquePaths.count, 10, "All paths should be unique")
        
        // Verify each path has correct index
        for (index, path) in paths.enumerated() {
            XCTAssertTrue(path.hasSuffix("/\(index).jpg"), "Path should end with /\(index).jpg")
        }
        
        print("✅ Multiple indices test passed")
    }
    
    /// Test path format matches expected pattern
    func test_buildPostImagePath_matchesExpectedFormat() throws {
        // Arrange: Use specific UUIDs for predictable output
        let userId = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let postId = UUID(uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB")!
        
        // Act
        let path = ImageStorage.buildPostImagePath(userId: userId, postId: postId, index: 0)
        
        // Assert: Exact format check
        let expected = "posts/12345678-1234-1234-1234-123456789012/ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB/0.jpg"
        XCTAssertEqual(path, expected, "Path should match exact expected format")
        
        // Verify no extra slashes or spaces
        XCTAssertFalse(path.contains("//"), "Path should not contain double slashes")
        XCTAssertFalse(path.contains(" "), "Path should not contain spaces")
        
        print("✅ Format validation test passed")
        print("   Expected: \(expected)")
        print("   Actual:   \(path)")
    }
    
    /// Test that paths are consistent (deterministic)
    func test_buildPostImagePath_isDeterministic() throws {
        // Arrange
        let userId = UUID()
        let postId = UUID()
        let index = 0
        
        // Act: Generate same path multiple times
        let path1 = ImageStorage.buildPostImagePath(userId: userId, postId: postId, index: index)
        let path2 = ImageStorage.buildPostImagePath(userId: userId, postId: postId, index: index)
        let path3 = ImageStorage.buildPostImagePath(userId: userId, postId: postId, index: index)
        
        // Assert: All should be identical
        XCTAssertEqual(path1, path2)
        XCTAssertEqual(path2, path3)
        XCTAssertEqual(path1, path3)
        
        print("✅ Deterministic test passed - same inputs produce same output")
    }
    
    /// Test edge case: index 0
    func test_buildPostImagePath_indexZero() throws {
        // Arrange
        let userId = UUID()
        let postId = UUID()
        
        // Act
        let path = ImageStorage.buildPostImagePath(userId: userId, postId: postId, index: 0)
        
        // Assert
        XCTAssertTrue(path.hasSuffix("/0.jpg"), "Index 0 should produce /0.jpg")
        
        print("✅ Index zero test passed")
    }
    
    /// Test that FileOptions can be used multiple times (no side effects)
    func test_buildJPEGFileOptions_isReusable() throws {
        // Act: Get options multiple times
        let options1 = ImageStorage.buildJPEGFileOptions()
        let options2 = ImageStorage.buildJPEGFileOptions()
        
        // Assert: Should have same values
        XCTAssertEqual(options1.contentType, options2.contentType)
        XCTAssertEqual(options1.upsert, options2.upsert)
        XCTAssertEqual(options1.cacheControl, options2.cacheControl)
        
        print("✅ Reusable options test passed")
    }
}

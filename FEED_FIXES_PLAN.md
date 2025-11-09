# Feed System Fixes - Implementation Plan

## Problem Analysis

### Issue 1: Feed Loading Problems
**Symptoms**: Infinite loading, request cancellation loops, empty feed
**Root Causes**:
1. SwipeDeckView calls `await feedVM.refresh()` but refresh() is NOT async
2. Direct manipulation of `feedVM.items` in multiple places (lines 907, 971, 2039)
3. Loading state not properly synced with FeedViewModel's async operations
4. Two competing feed loading paths: one through FeedViewModel, one direct API calls

**Current Flow (BROKEN)**:
```
SwipeDeckView.task → maybeLoadFeed() → loadFeedWithOneShotLocation()
  → await feedVM.refresh() [WRONG: not async]
  → isLoading never set to false properly
```

**Also has DIRECT path**:
```
SwipeDeckView.fetchFeed() → api.getFeed() → feedVM.items = result [BYPASSES VM]
```

### Issue 2: Map Pins & Own Posts
**Symptoms**: Map shows user's own posts
**Root Cause**: Client-side filtering not applied (backend may include them)

### Issue 3: Notifications Decoding
**Symptoms**: "Couldn't load notifications" error
**Root Cause**: Decoder expecting different format than backend provides

### Issue 4: Profile Update Not Reflecting
**Symptoms**: UI shows old data after successful update
**Root Cause**: View binds to stale cache, not refreshed server state

---

## Fix Strategy

### Fix 1: Feed Loading (Priority 1)

#### A) Remove Incorrect await Usage
- Line 1011: `await feedVM.refresh()` → `feedVM.refresh()`
- Line 1022: `await feedVM.refresh()` → `feedVM.refresh()`
- Line 1037: `await feedVM.refresh()` → `feedVM.refresh()`

#### B) Use FeedViewModel Consistently
Remove direct `feedVM.items =` assignments:
- Line 907: Stop bypassing FeedViewModel
- Line 971: Stop bypassing FeedViewModel  
- Line 2039: Stop bypassing FeedViewModel (in FeedMapScreen)

#### C) Observe FeedViewModel State
Add `.onChange(of: feedVM.items)` to update deck when FeedViewModel finishes:
```swift
.onChange(of: feedVM.items) { oldItems, newItems in
    // Update visible cards when feed data changes
    let visiblePosts = newItems.filter { post in
        !dismissedIds.contains(post.id) && !reservedIds.contains(post.id)
    }
    deckState.updateItems(visiblePosts)
}
```

#### D) Fix Loading State
Observe `feedVM.isLoading`:
```swift
.onChange(of: feedVM.isLoading) { _, loading in
    isLoading = loading
}
```

#### E) Simplify loadFeedWithOneShotLocation
```swift
@MainActor
private func loadFeedWithOneShotLocation() async {
    guard !feedVM.isLoading else { return }
    
    // Try cached first
    if let cached = LocationService.shared.lastKnownFromSystem() {
        let coord = cached.coordinate
        if LocationReadiness.isUsable(coord) {
            feedVM.refresh(currentLocation: coord)  // No await
            return
        }
    }
    
    // Get fresh fix
    do {
        let loc = try await LocationService.shared.firstFix(timeout: 2.5)
        if LocationReadiness.isUsable(loc.coordinate) {
            feedVM.refresh(currentLocation: loc.coordinate)  // No await
        }
    } catch {
        // Show error state
        showError = true
    }
}
```

---

### Fix 2: Map Pins - Exclude Own Posts

In TrashMapView.swift MapVM.refresh():
```swift
// Build pins from Post models provided by FeedViewModel
let posts = feedVM.items
let currentUserId = // Get from SupabaseService or ApiService

self.pins = posts.compactMap { (post) -> MapPin? in
    // Skip own posts
    if post.ownerId == currentUserId {
        return nil
    }
    
    // Skip if no coordinate
    let coord = post.exactLocation?.coordinate ?? post.approxLocation?.coordinate
    guard let c = coord else { return nil }
    
    // ... rest of mapping
}
```

---

### Fix 3: Notifications Decoding

Check NotificationsResponse model and add proper date decoding:
```swift
extension JSONDecoder {
    static func swoopyAPI() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            
            // Try with fractional seconds first
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) {
                return date
            }
            
            // Fallback without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: dateString) {
                return date
            }
            
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format")
        }
        return decoder
    }
}
```

---

### Fix 4: Profile Update Reflection

After profile PATCH success:
```swift
// In profile save handler
do {
    try await api.updateProfile(...)
    // Immediately fetch fresh profile from server
    await svc.fetchProfile()  // This updates @Published profile
    // UI will auto-update via bindings
} catch {
    // Handle error
}
```

---

## Implementation Order

1. ✅ Fix Feed Loading (most critical - blocks app usage)
2. ✅ Fix Map Pins (user experience issue)
3. ✅ Fix Notifications Decoding (blocks notifications feature)
4. ✅ Fix Profile Update (minor UX issue)

---

## Testing Checklist

### Feed Loading
- [ ] App opens, feed loads within 1-2 seconds
- [ ] Cards visible on screen
- [ ] Logs show ONE request: `GET /feed?lng=...&lat=...&radius_km=10&limit=50`
- [ ] No "NET cancel underlying request" in logs
- [ ] Pull-to-refresh works
- [ ] Post-upload triggers refresh

### Map Pins
- [ ] Map shows pins for nearby posts
- [ ] My own posts NOT visible as pins
- [ ] Newly created post doesn't appear on map
- [ ] Pan/zoom doesn't cause duplicate requests

### Notifications  
- [ ] List loads without errors
- [ ] Action cards show Approve/Skip
- [ ] Info cards display properly
- [ ] Pull-to-refresh works

### Profile
- [ ] After save, name/phone immediately visible
- [ ] Avatar updates reflected
- [ ] Logs show profile fetch after update

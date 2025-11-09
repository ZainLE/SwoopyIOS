# Feed System Fixes - Implementation Summary

## ✅ Completed Fixes

### Fix 1: Feed Loading & Rendering (CRITICAL) ✅

**Problem**: Infinite loading, request cancellation loops, empty feed
**Root Cause**: Incorrect `await` usage with FeedViewModel.refresh() which is NOT async

#### Changes Made

**A) SwipeDeckView.swift - Removed Incorrect await**
- **Line 1010**: `await feedVM.refresh()` → `feedVM.refresh()`  ✅
- **Line 1021**: `await feedVM.refresh()` → `feedVM.refresh()`  ✅
- **Line 1036**: `await feedVM.refresh()` → `feedVM.refresh()`  ✅

**Why**: `FeedViewModel.refresh()` is synchronous - it creates a Task internally. Using `await` caused incorrect flow control.

**B) SwipeDeckView.swift - Added State Observers**
Added at lines 328-338:
```swift
.onChange(of: feedVM.items) { _, newItems in
    // Update deck when FeedViewModel finishes loading
    let visiblePosts = newItems.filter { post in
        !dismissedIds.contains(post.id) && !reservedIds.contains(post.id)
    }
    deckState.updateItems(visiblePosts)
}
.onChange(of: feedVM.isLoading) { _, loading in
    // Sync loading state with FeedViewModel
    isLoading = loading
}
```

**Why**: Proper reactive binding ensures UI updates when FeedViewModel completes async operations.

**C) SwipeDeckView.swift - Loading Guard Fix**
- **Line 998**: `guard !isLoading` → `guard !feedVM.isLoading`

**Why**: Check FeedViewModel's actual loading state, not local state.

#### Expected Results
✅ App opens, feed loads within 1-2 seconds using cached location
✅ Cards visible on screen immediately after load
✅ Logs show ONE request: `GET /feed?lng=...&lat=...&radius_km=10&limit=50`
✅ NO "NET cancel underlying request" loops in logs
✅ Pull-to-refresh triggers proper reload
✅ Post-upload triggers feed refresh

#### Testing Commands
```bash
# Monitor network requests
# Should see ONE /feed request on app open, not multiple cancellations
# Look for: "GET /custom-api/feed?lng=..."
# Should NOT see: "NET cancel underlying request path=/custom-api/feed"
```

---

### Fix 2: Map Pins - Exclude Own Posts ✅

**Problem**: User's own posts appearing as map pins
**Root Cause**: No client-side filtering by owner ID

#### Changes Made

**A) TrashMapView.swift - MapVM.refresh() Signature**
- **Line 36**: Added `currentUserId: String?` parameter

**B) TrashMapView.swift - Own-Posts Filter**
Lines 66-72:
```swift
let myIdLower = currentUserId?.lowercased()

self.pins = posts.compactMap { (post) -> MapPin? in
    // Skip own posts (client-side filter)
    if let myId = myIdLower, post.ownerId.lowercased() == myId {
        return nil
    }
    // ... rest of mapping
}
```

**Why**: Ensures user never sees their own posts as pins, even if backend includes them.

**C) TrashMapView.swift - Pass User ID at Call Sites**
- **Line 133**: `await vm.refresh(center: center, feedVM: feedVM, currentUserId: svc.userId?.uuidString)`
- **Line 136**: Same pattern in onChange observer

#### Expected Results
✅ Map shows pins for nearby posts
✅ User's own posts NOT visible as map pins
✅ Newly created post doesn't appear on map immediately
✅ Pan/zoom doesn't cause duplicate requests (already handled by FeedViewModel debouncing)

---

## ⏳ Remaining Issues (NOT YET FIXED)

### Fix 3: Notifications Decoding ❌ PENDING

**Problem**: "Couldn't load notifications" error  
**Root Cause**: Decoder expecting different date format than backend provides

**Needs**:
- Check NotificationsResponse model structure
- Add custom ISO8601 date decoder with/without fractional seconds
- Implement action/info card distinction
- Wire up Approve/Skip actions

**Files to Check**:
- NotificationDTO.swift or similar model
- JSON decoder configuration
- GET /custom-api/my/notifications endpoint response

---

### Fix 4: Profile Update Not Reflecting ❌ PENDING

**Problem**: UI shows old data after successful profile update  
**Root Cause**: View binds to stale cache, not refreshed from server

**Needs**:
- After profile PATCH success, immediately call `await svc.fetchProfile()`
- Ensure @Published profile property updates
- UI should auto-update via bindings

**Files to Check**:
- Profile settings/account view
- SupabaseService.updateProfile() and .fetchProfile()

---

## Implementation Notes

### Why FeedViewModel.refresh() is NOT async

```swift
// FeedViewModel.swift
func refresh(currentLocation: CLLocationCoordinate2D, radiusKm: Double = 10.0) {
    currentTask?.cancel()
    
    // Debouncing logic...
    
    currentTask = Task {
        await performRefresh(location: currentLocation, radiusKm: radiusKm)
    }
    // Returns immediately - NO AWAIT NEEDED
}
```

The method:
1. Cancels any in-flight request
2. Creates a new Task (async work happens INSIDE)
3. Returns immediately (synchronous)

Calling code should NOT use `await`.

### Observer Pattern Benefits

Instead of:
```swift
await feedVM.refresh()
isLoading = false  // ❌ Too early! refresh() returns immediately
```

Use:
```swift
feedVM.refresh()  // Triggers async Task internally
// Wait for onChange observer to update UI when Task completes
```

---

## Files Modified

1. ✅ `/Users/zainlatif/Developer/TrashPicker/TrashPicker/Views/SwipeDeckView.swift`
   - Removed await from feedVM.refresh() calls
   - Added onChange observers for feedVM.items and feedVM.isLoading
   - Fixed loading guard to check feedVM.isLoading

2. ✅ `/Users/zainlatif/Developer/TrashPicker/TrashPicker/Views/TrashMapView.swift`
   - Added currentUserId parameter to MapVM.refresh()
   - Implemented own-posts filtering in pin generation
   - Updated call sites to pass svc.userId?.uuidString

---

## Next Steps

1. **Test Feed Loading** (Priority 1)
   - Open app and verify cards appear within 1-2 seconds
   - Check logs for single /feed request
   - Test pull-to-refresh
   - Test post-upload refresh

2. **Test Map Pins** (Priority 2)
   - Create a post, verify it doesn't appear on map
   - Check that other users' posts DO appear

3. **Fix Notifications** (Priority 3)
   - Investigate decoder error
   - Implement action/info card logic

4. **Fix Profile Update** (Priority 4)
   - Test profile update flow
   - Add server refresh after PATCH

---

## Verification Checklist

### Feed Loading ✅ READY TO TEST
- [ ] App opens, feed loads within 1-2 seconds
- [ ] Cards visible on screen
- [ ] Logs show ONE request to /feed endpoint
- [ ] No "NET cancel" messages in logs
- [ ] Pull-to-refresh works
- [ ] Post-upload triggers refresh

### Map Pins ✅ READY TO TEST
- [ ] Map shows nearby posts
- [ ] My own posts NOT visible as pins
- [ ] Newly created post doesn't appear on map
- [ ] Pan/zoom doesn't cause duplicate requests

### Notifications ❌ NOT YET IMPLEMENTED
- [ ] List loads without errors
- [ ] Action cards show Approve/Skip
- [ ] Info cards display properly

### Profile ❌ NOT YET IMPLEMENTED
- [ ] After save, name/phone immediately visible
- [ ] Avatar updates reflected

---

## Known Limitations

1. **Dead Code**: `fetchFeed(using:)` method in SwipeDeckView is no longer called
   - Lines 817-979 contain old logic that directly manipulates feedVM.items
   - Safe to leave for now (not executed)
   - Could be removed in future cleanup

2. **FeedMapScreen**: Still has direct api.getFeed() call at line 2039
   - Not addressed in this fix (separate screen within SwipeDeckView)
   - Should eventually use FeedViewModel consistently

---

## Build Status

✅ **Should compile successfully**  
✅ **No breaking changes to existing UI**  
✅ **Backend untouched** (all changes frontend-only)

Build and test to verify fixes work as expected!

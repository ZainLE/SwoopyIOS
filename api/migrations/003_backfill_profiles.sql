-- P0: Backfill missing profiles
-- This ensures every user in auth.users has a corresponding profile row
-- Prevents FK constraint errors when creating reservations

-- Insert profiles for any auth.users that don't have a profile yet
INSERT INTO profiles (id, created_at, updated_at, given_count, picked_count)
SELECT 
    au.id,
    COALESCE(au.created_at, NOW()) as created_at,
    NOW() as updated_at,
    0 as given_count,
    0 as picked_count
FROM auth.users au
LEFT JOIN profiles p ON au.id = p.id
WHERE p.id IS NULL;

-- Log the result
DO $$
DECLARE
    backfilled_count INTEGER;
BEGIN
    GET DIAGNOSTICS backfilled_count = ROW_COUNT;
    RAISE NOTICE 'Backfilled % missing profile(s)', backfilled_count;
END $$;

-- Verify no orphaned reservations exist
-- This query will help identify any reservations with invalid reserver IDs
DO $$
DECLARE
    orphaned_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO orphaned_count
    FROM reservations r
    LEFT JOIN profiles p ON r.reserver = p.id
    WHERE p.id IS NULL;
    
    IF orphaned_count > 0 THEN
        RAISE WARNING 'Found % orphaned reservation(s) with invalid reserver IDs', orphaned_count;
        -- Optionally, you could delete these or handle them differently
        -- DELETE FROM reservations WHERE reserver NOT IN (SELECT id FROM profiles);
    ELSE
        RAISE NOTICE 'No orphaned reservations found';
    END IF;
END $$;

-- Add helpful comment
COMMENT ON TABLE profiles IS 'User profiles. Auto-created by auth_required middleware for every authenticated user.';


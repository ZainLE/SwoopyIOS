-- Storage policies for profile-photos bucket
-- NOTE: Before running this, create the 'profile-photos' bucket in Supabase Dashboard
-- and set it to PUBLIC for read access.

-- Allow authenticated users to upload their own photos
-- Photos are stored at: profile-photos/{user_id}/avatar_{timestamp}.{ext}
CREATE POLICY "Users can upload their own profile photos"
ON storage.objects FOR INSERT
WITH CHECK (
  bucket_id = 'profile-photos' AND
  auth.uid()::text = (storage.foldername(name))[1]
);

-- Allow authenticated users to update their own photos
CREATE POLICY "Users can update their own profile photos"
ON storage.objects FOR UPDATE
USING (
  bucket_id = 'profile-photos' AND
  auth.uid()::text = (storage.foldername(name))[1]
);

-- Allow authenticated users to delete their own photos
CREATE POLICY "Users can delete their own profile photos"
ON storage.objects FOR DELETE
USING (
  bucket_id = 'profile-photos' AND
  auth.uid()::text = (storage.foldername(name))[1]
);

-- Allow public read access to all profile photos
CREATE POLICY "Public can view profile photos"
ON storage.objects FOR SELECT
USING (bucket_id = 'profile-photos');

-- Add helpful comments
COMMENT ON POLICY "Users can upload their own profile photos" ON storage.objects IS 
  'Allows authenticated users to upload photos to their own folder in profile-photos bucket';

COMMENT ON POLICY "Public can view profile photos" ON storage.objects IS 
  'Allows public read access to all profile photos for displaying avatars in the app';


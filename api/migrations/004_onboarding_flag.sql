-- Add onboarding_completed flag to profiles table
-- This flag is used to track whether a user has completed onboarding
ALTER TABLE profiles ADD COLUMN onboarding_completed BOOLEAN NOT NULL DEFAULT false;

-- Add index for faster queries on onboarding status
CREATE INDEX idx_profiles_onboarding_completed ON profiles(onboarding_completed);

-- Add helpful comment
COMMENT ON COLUMN profiles.onboarding_completed IS 'Tracks whether user has completed onboarding flow. Set to true when onboarding finishes.';


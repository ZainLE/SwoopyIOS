-- Create function to automatically update updated_at timestamp
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Add trigger to profiles table
DROP TRIGGER IF EXISTS trigger_set_updated_at_profiles ON profiles;
CREATE TRIGGER trigger_set_updated_at_profiles
    BEFORE UPDATE ON profiles
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- Add trigger to posts table (if not already present)
DROP TRIGGER IF EXISTS trigger_set_updated_at_posts ON posts;
CREATE TRIGGER trigger_set_updated_at_posts
    BEFORE UPDATE ON posts
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- Add trigger to reservations table (if not already present)
DROP TRIGGER IF EXISTS trigger_set_updated_at_reservations ON reservations;
CREATE TRIGGER trigger_set_updated_at_reservations
    BEFORE UPDATE ON reservations
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- Add helpful comment
COMMENT ON FUNCTION set_updated_at() IS 'Automatically sets updated_at to current timestamp on row update';


-- Enable PostGIS for geographic data types
CREATE EXTENSION IF NOT EXISTS postgis;

-- Enums
CREATE TYPE item_mode AS ENUM ('street', 'home');
CREATE TYPE item_condition AS ENUM ('bad', 'good', 'excellent');
CREATE TYPE reservation_status AS ENUM ('pending', 'active', 'canceled', 'picked', 'expired');

-- Tables
CREATE TABLE profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    first_name TEXT,
    last_name TEXT,
    city TEXT,
    phone TEXT,
    avatar_url TEXT,
    given_count INTEGER DEFAULT 0 CHECK (given_count >= 0),
    picked_count INTEGER DEFAULT 0 CHECK (picked_count >= 0),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE posts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL CHECK (LENGTH(title) BETWEEN 1 AND 80),
    description TEXT CHECK (LENGTH(description) <= 100),
    category TEXT NOT NULL CHECK (LENGTH(category) >= 1),
    condition item_condition NOT NULL,
    mode item_mode NOT NULL,
    exact_location GEOGRAPHY(Point),
    approx_location GEOGRAPHY(Point),
    expires_at TIMESTAMPTZ NOT NULL,
    owner_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),

    -- Constraint: Only one location type based on mode
    CONSTRAINT valid_location_mode CHECK (
        (mode = 'street' AND exact_location IS NOT NULL AND approx_location IS NULL) OR
        (mode = 'home' AND approx_location IS NOT NULL AND exact_location IS NULL)
    )
);

CREATE TABLE images (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id UUID NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    url TEXT NOT NULL CHECK (url ~ '^https?://'),
    order_index INTEGER NOT NULL DEFAULT 0 CHECK (order_index >= 0),
    created_at TIMESTAMPTZ DEFAULT NOW(),

    -- Ensure unique ordering per post
    UNIQUE(post_id, order_index)
);

CREATE TABLE reservations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    item_id UUID NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    reserver UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    status reservation_status NOT NULL DEFAULT 'pending',
    requested_at TIMESTAMPTZ DEFAULT NOW(),
    approved_at TIMESTAMPTZ,
    start_at TIMESTAMPTZ,
    end_at TIMESTAMPTZ,
    canceled_at TIMESTAMPTZ,
    picked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),

    -- Constraint: Valid status transitions and timestamps
    CONSTRAINT valid_approval_time CHECK (
        (approved_at IS NULL AND status IN ('pending', 'canceled', 'expired')) OR
        (approved_at IS NOT NULL AND status IN ('active', 'picked', 'canceled'))
    ),
    CONSTRAINT valid_cancellation_time CHECK (
        canceled_at IS NULL OR status = 'canceled'
    ),
    CONSTRAINT valid_pickup_time CHECK (
        picked_at IS NULL OR status = 'picked'
    )
);

-- Indexes for better performance
CREATE INDEX idx_posts_owner_id ON posts(owner_id);
CREATE INDEX idx_posts_category ON posts(category);
CREATE INDEX idx_posts_condition ON posts(condition);
CREATE INDEX idx_posts_mode ON posts(mode);
CREATE INDEX idx_posts_expires_at ON posts(expires_at);
CREATE INDEX idx_posts_created_at ON posts(created_at);

-- Spatial indexes for geographic queries
CREATE INDEX idx_posts_exact_location ON posts USING GIST(exact_location);
CREATE INDEX idx_posts_approx_location ON posts USING GIST(approx_location);

CREATE INDEX idx_images_post_id ON images(post_id);
CREATE INDEX idx_images_order_index ON images(post_id, order_index);

CREATE INDEX idx_reservations_item_id ON reservations(item_id);
CREATE INDEX idx_reservations_reserver ON reservations(reserver);
CREATE INDEX idx_reservations_status ON reservations(status);
CREATE INDEX idx_reservations_requested_at ON reservations(requested_at);

-- RLS (Row Level Security) Policies
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE images ENABLE ROW LEVEL SECURITY;
ALTER TABLE reservations ENABLE ROW LEVEL SECURITY;

-- Profiles policies
CREATE POLICY "Users can view all profiles"
    ON profiles FOR SELECT
    USING (true);

CREATE POLICY "Users can update their own profile"
    ON profiles FOR UPDATE
    USING (auth.uid() = id);

CREATE POLICY "Users can insert their own profile"
    ON profiles FOR INSERT
    WITH CHECK (auth.uid() = id);

-- Posts policies
CREATE POLICY "Users can view all posts"
    ON posts FOR SELECT
    USING (true);

CREATE POLICY "Users can create their own posts"
    ON posts FOR INSERT
    WITH CHECK (auth.uid() = owner_id);

CREATE POLICY "Users can update their own posts"
    ON posts FOR UPDATE
    USING (auth.uid() = owner_id);

CREATE POLICY "Users can delete their own posts"
    ON posts FOR DELETE
    USING (auth.uid() = owner_id);

-- Images policies
CREATE POLICY "Users can view all images"
    ON images FOR SELECT
    USING (true);

CREATE POLICY "Users can create images for their posts"
    ON images FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM posts
            WHERE posts.id = images.post_id
            AND posts.owner_id = auth.uid()
        )
    );

CREATE POLICY "Users can update images for their posts"
    ON images FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM posts
            WHERE posts.id = images.post_id
            AND posts.owner_id = auth.uid()
        )
    );

CREATE POLICY "Users can delete images for their posts"
    ON images FOR DELETE
    USING (
        EXISTS (
            SELECT 1 FROM posts
            WHERE posts.id = images.post_id
            AND posts.owner_id = auth.uid()
        )
    );

-- Reservations policies
CREATE POLICY "Users can view reservations they are involved in"
    ON reservations FOR SELECT
    USING (
        auth.uid() = reserver OR
        EXISTS (
            SELECT 1 FROM posts
            WHERE posts.id = reservations.item_id
            AND posts.owner_id = auth.uid()
        )
    );

CREATE POLICY "Users can create reservations"
    ON reservations FOR INSERT
    WITH CHECK (auth.uid() = reserver);

CREATE POLICY "Users can update their own reservations"
    ON reservations FOR UPDATE
    USING (auth.uid() = reserver);

CREATE POLICY "Post owners can update reservations for their items"
    ON reservations FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM posts
            WHERE posts.id = reservations.item_id
            AND posts.owner_id = auth.uid()
        )
    );

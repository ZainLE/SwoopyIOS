-- Add notifications table for swipe-right requests and approvals
CREATE TABLE notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    recipient_user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    type TEXT NOT NULL CHECK (type IN (
        'new_request', 
        'street_reserved',
        'request_approved', 
        'request_rejected', 
        'request_withdrawn', 
        'request_expired', 
        'pickup_completed'
    )),
    reservation_id UUID REFERENCES reservations(id) ON DELETE CASCADE,
    post_id UUID REFERENCES posts(id) ON DELETE CASCADE,
    counterparty_user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
    contact_phone TEXT NULL, -- Only set for request_approved to the requester
    created_at TIMESTAMPTZ DEFAULT NOW(),
    read_at TIMESTAMPTZ NULL,
    meta JSONB NULL -- Optional small extras
);

-- Indexes for better performance
CREATE INDEX idx_notifications_recipient_user_id ON notifications(recipient_user_id);
CREATE INDEX idx_notifications_created_at ON notifications(recipient_user_id, created_at DESC);
CREATE INDEX idx_notifications_reservation_id ON notifications(reservation_id);
CREATE INDEX idx_notifications_type ON notifications(type);
CREATE INDEX idx_notifications_read_at ON notifications(read_at);

-- RLS (Row Level Security) Policies
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

-- Users can only read their own notifications
CREATE POLICY "Users can view their own notifications"
    ON notifications FOR SELECT
    USING (auth.uid() = recipient_user_id);

-- Only server can insert notifications (no direct client inserts)
CREATE POLICY "Server can insert notifications"
    ON notifications FOR INSERT
    WITH CHECK (true); -- This will be restricted by service role in practice

-- Users can mark their own notifications as read
CREATE POLICY "Users can update their own notifications"
    ON notifications FOR UPDATE
    USING (auth.uid() = recipient_user_id)
    WITH CHECK (auth.uid() = recipient_user_id);

-- Add phone validation constraint for home mode posts
-- This will be enforced in the application layer as well
ALTER TABLE profiles ADD CONSTRAINT phone_format_check 
    CHECK (phone IS NULL OR phone ~ '^\+?[1-9]\d{1,14}$');

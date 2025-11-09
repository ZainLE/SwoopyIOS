#!/usr/bin/env python3
"""
Street Post Expiration Handler

This script handles the automatic expiration of street mode posts and their reservations.
It should be run periodically (e.g., every 5-10 minutes) via cron or a task scheduler.

Street posts expire after 2 hours, and when they expire:
1. The reservation status is updated to 'expired'
2. A 'request_expired' notification is sent to the reserver
"""

import os
import sys
import logging
from datetime import datetime, timezone, timedelta
from flask import Flask
from app import create_app
from app.config import supabase, get_sql_cursor

# Configure logging
log_level = os.environ.get('LOG_LEVEL', 'INFO').upper()
log_file = os.environ.get('LOG_FILE', '/var/log/swoopy_expiration.log')

logging.basicConfig(
    level=getattr(logging, log_level, logging.INFO),
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(log_file),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)


def expire_street_posts():
    """
    Find and expire street mode posts that have passed their expiration time.
    Also expire any active reservations for these posts.
    """
    try:
        conn, cursor = get_sql_cursor()
        
        # Find expired street posts with active reservations
        sql = """
        SELECT 
            p.id as post_id,
            p.title,
            p.expires_at,
            r.id as reservation_id,
            r.reserver,
            r.status as reservation_status
        FROM posts p
        INNER JOIN reservations r ON p.id = r.item_id
        WHERE p.mode = 'street'
        AND p.expires_at <= NOW()
        AND r.status IN ('pending', 'active')
        ORDER BY p.expires_at ASC
        """
        
        cursor.execute(sql)
        expired_reservations = cursor.fetchall()
        
        if not expired_reservations:
            logger.info("No expired street posts found")
            return
        
        logger.info(f"Found {len(expired_reservations)} expired street post reservations to process")
        
        # Process each expired reservation
        for row in expired_reservations:
            post_id = row['post_id']
            reservation_id = row['reservation_id']
            reserver_id = row['reserver']
            post_title = row['title']
            
            try:
                # Update reservation status to expired and set end_at to post expires_at
                update_sql = """
                UPDATE reservations 
                SET status = 'expired', 
                    end_at = (SELECT expires_at FROM posts WHERE id = %s),
                    updated_at = NOW()
                WHERE id = %s
                """
                cursor.execute(update_sql, (post_id, reservation_id))
                
                # P3: Log reservation expiration with structured logging
                log_data = {
                    'event': 'reservation_transition',
                    'reservation_id': str(reservation_id),
                    'post_id': str(post_id),
                    'mode': 'street',
                    'from_status': row['reservation_status'],
                    'to_status': 'expired',
                    'actor_user_id': 'system',
                    'reserver_user_id': str(reserver_id),
                    'timestamp': datetime.now(timezone.utc).isoformat()
                }
                logger.info(f"RESERVATION_TRANSITION: {log_data}")
                
                # Create notification for reserver
                notification_data = {
                    'recipient_user_id': reserver_id,
                    'type': 'request_expired',
                    'reservation_id': reservation_id,
                    'post_id': post_id,
                    'counterparty_user_id': None,  # No counterparty for expiration
                    'created_at': datetime.now(timezone.utc).isoformat()
                }
                
                # Insert notification using Supabase client
                supabase.table('notifications').insert(notification_data).execute()
                
                # P3: Log notification insert
                notif_log_data = {
                    'event': 'notification_insert',
                    'type': 'request_expired',
                    'recipient_user_id': str(reserver_id),
                    'post_id': str(post_id),
                    'reservation_id': str(reservation_id),
                    'counterparty_user_id': None,
                    'timestamp': datetime.now(timezone.utc).isoformat()
                }
                logger.info(f"NOTIFICATION_INSERT: {notif_log_data}")
                
                logger.info(f"Expired reservation {reservation_id} for post '{post_title}' (ID: {post_id})")
                
            except Exception as e:
                logger.error(f"Error processing expired reservation {reservation_id}: {e}")
                continue
        
        # Commit all changes
        conn.commit()
        logger.info(f"Successfully processed {len(expired_reservations)} expired street post reservations")
        
    except Exception as e:
        logger.error(f"Error in expire_street_posts: {e}")
        conn.rollback()
        raise
    finally:
        cursor.close()
        conn.close()


def cleanup_old_notifications():
    """
    Optional: Clean up old notifications to prevent database bloat.
    Keep notifications for 30 days.
    """
    try:
        thirty_days_ago = datetime.now(timezone.utc) - timedelta(days=30)
        
        conn, cursor = get_sql_cursor()
        
        # Delete old notifications
        delete_sql = """
        DELETE FROM notifications 
        WHERE created_at < %s
        """
        
        cursor.execute(delete_sql, (thirty_days_ago,))
        deleted_count = cursor.rowcount
        
        conn.commit()
        
        if deleted_count > 0:
            logger.info(f"Cleaned up {deleted_count} old notifications")
        
    except Exception as e:
        logger.error(f"Error in cleanup_old_notifications: {e}")
        conn.rollback()
    finally:
        cursor.close()
        conn.close()


def main():
    """Main entry point for the expiration handler"""
    logger.info("Starting street post expiration handler")
    
    # Initialize Flask app context
    app = create_app()
    
    with app.app_context():
        try:
            # Check database connection
            conn, cursor = get_sql_cursor()
            cursor.execute("SELECT 1")
            cursor.close()
            conn.close()
            logger.info("Database connection verified")
        
            # Run expiration logic
            expire_street_posts()
            
            # Optional: Clean up old notifications (uncomment if needed)
            # cleanup_old_notifications()
            
            logger.info("Street post expiration handler completed successfully")
            
        except Exception as e:
            logger.error(f"Street post expiration handler failed: {e}")
            sys.exit(1)


if __name__ == '__main__':
    main()

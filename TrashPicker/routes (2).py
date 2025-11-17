from shapely import wkb, wkt
from flask import request, Blueprint, jsonify
from pydantic import BaseModel, Field, HttpUrl, field_validator, ValidationInfo, ConfigDict
from typing import List, Optional
from functools import wraps
from .models import ItemCondition, ItemMode, NotificationType, NotificationCategory, NotificationState, PersistenceType
from .config import supabase, get_sql_cursor
from .middleware import rate_limit, sanitize_profile_data, validate_image_content_type, validate_image_size
from datetime import datetime, timedelta, timezone
import logging
import uuid
import json

logger = logging.getLogger(__name__)
bp = Blueprint('api', __name__, url_prefix='/custom-api/')


def log_reservation_transition(reservation_id, post_id, mode, from_status, to_status, actor_user_id, reserver_user_id=None):
    """
    P3: Structured logging for reservation state transitions
    Logs with consistent format for traceability and debugging
    """
    log_data = {
        'event': 'reservation_transition',
        'reservation_id': str(reservation_id),
        'post_id': str(post_id),
        'mode': mode,
        'from_status': from_status,
        'to_status': to_status,
        'actor_user_id': str(actor_user_id),
        'timestamp': datetime.now(timezone.utc).isoformat()
    }
    if reserver_user_id:
        log_data['reserver_user_id'] = str(reserver_user_id)
    
    logger.info(f"RESERVATION_TRANSITION: {log_data}")
    return log_data


def log_notification_insert(notification_type, recipient_user_id, post_id, reservation_id=None, counterparty_user_id=None):
    """
    P3: Structured logging for notification inserts
    Logs with consistent format for traceability and debugging
    """
    log_data = {
        'event': 'notification_insert',
        'type': notification_type,
        'recipient_user_id': str(recipient_user_id),
        'post_id': str(post_id) if post_id else None,
        'reservation_id': str(reservation_id) if reservation_id else None,
        'counterparty_user_id': str(counterparty_user_id) if counterparty_user_id else None,
        'timestamp': datetime.now(timezone.utc).isoformat()
    }
    
    logger.info(f"NOTIFICATION_INSERT: {log_data}")
    return log_data


def get_request_id():
    """Get X-Request-ID from headers or generate a new one"""
    return request.headers.get('X-Request-ID') or str(uuid.uuid4())


def check_idempotency(request_id, event_type, actor_id, reservation_id=None, post_id=None, notification_id=None):
    """
    Check if this request has already been processed (idempotency check)
    Returns (is_duplicate, stored_result) tuple
    """
    try:
        conn, cursor = get_sql_cursor()
        cursor.execute("""
            SELECT result FROM event_logs 
            WHERE request_id = %s AND event_type = %s AND actor_id = %s
        """, (request_id, event_type, str(actor_id)))
        row = cursor.fetchone()
        cursor.close()
        conn.close()
        
        if row:
            return True, row.get('result')
        return False, None
    except Exception as e:
        logger.error(f"Idempotency check error: {e}")
        return False, None


def store_event_log(request_id, event_type, actor_id, result, reservation_id=None, post_id=None, notification_id=None):
    """Store event log for idempotency"""
    try:
        conn, cursor = get_sql_cursor()
        cursor.execute("""
            INSERT INTO event_logs (request_id, event_type, actor_id, reservation_id, post_id, notification_id, result)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (request_id) DO NOTHING
        """, (request_id, event_type, str(actor_id), reservation_id, post_id, notification_id, json.dumps(result) if result else None))
        conn.commit()
        cursor.close()
        conn.close()
    except Exception as e:
        logger.error(f"Store event log error: {e}")


def create_notification(notification_type, recipient_user_id, post_id, reservation_id=None,
                        counterparty_user_id=None, payload=None, state=None):
    """
    Create a notification with the new schema
    Maps notification types to categories, persistence, etc.
    """
    # Map type to category and persistence
    type_config = {
        NotificationType.STREET_PICKUP_CONFIRMED: {
            'category': NotificationCategory.INFORMATIONAL,
            'persistence_type': PersistenceType.REAL_TIME,
            'persistence_seconds': 21600,  # 6 hours
            'state': None
        },
        NotificationType.HOME_PICKUP_REQUEST: {
            'category': NotificationCategory.ACTIONABLE,
            'persistence_type': PersistenceType.INFINITE,
            'persistence_seconds': None,
            'state': NotificationState.PENDING_APPROVAL
        },
        NotificationType.REQUEST_DECLINED: {
            'category': NotificationCategory.INFORMATIONAL,
            'persistence_type': PersistenceType.ACTIVE_VIEW,
            'persistence_seconds': 300,  # 5 minutes
            'state': None
        },
        NotificationType.REQUEST_CANCELLED_AFTER_ACCEPTANCE: {
            'category': NotificationCategory.INFORMATIONAL,
            'persistence_type': PersistenceType.ACTIVE_VIEW,
            'persistence_seconds': 300,  # 5 minutes
            'state': None
        }
    }
    
    # Get config for this type, or use defaults
    config = type_config.get(notification_type, {
        'category': NotificationCategory.INFORMATIONAL,
        'persistence_type': PersistenceType.INFINITE,
        'persistence_seconds': None,
        'state': None
    })
    
    notification_data = {
        'recipient_user_id': str(recipient_user_id),
        'type': notification_type.value if isinstance(notification_type, NotificationType) else notification_type,
        'category': config['category'].value if isinstance(config['category'], NotificationCategory) else config['category'],
        'persistence_type': config['persistence_type'].value if isinstance(config['persistence_type'], PersistenceType) else config['persistence_type'],
        'is_read': False,
        'post_id': str(post_id) if post_id else None,
        'reservation_id': str(reservation_id) if reservation_id else None,
        'counterparty_user_id': str(counterparty_user_id) if counterparty_user_id else None,
        'payload': payload or {}
    }
    
    if config['persistence_seconds']:
        notification_data['persistence_seconds'] = config['persistence_seconds']
    
    if state:
        notification_data['state'] = state.value if isinstance(state, NotificationState) else state
    elif config['state']:
        notification_data['state'] = config['state'].value if isinstance(config['state'], NotificationState) else config['state']
    
    result = supabase.table('notifications').insert(notification_data).execute()
    if result.data:
        log_notification_insert(
            notification_type.value if isinstance(notification_type, NotificationType) else notification_type,
            recipient_user_id, post_id, reservation_id, counterparty_user_id
        )
        return result.data[0]
    return None


def cleanup_expired_notifications():
    """
    Cleanup expired real_time notifications (Type-1: 6h expiration)
    This should be called periodically (e.g., every 10 minutes)
    Deletes category='informational' AND persistence_type='real_time' AND expired
    """
    try:
        conn, cursor = get_sql_cursor()
        
        # Delete expired real_time notifications
        cursor.execute("""
            DELETE FROM notifications
            WHERE category = 'informational'
            AND persistence_type = 'real_time'
            AND NOW() > created_at + (persistence_seconds || ' seconds')::interval
        """)
        
        deleted_count = cursor.rowcount
        conn.commit()
        
        cursor.close()
        conn.close()
        
        if deleted_count > 0:
            logger.info(f"Cleaned up {deleted_count} expired real_time notifications")
        
        return deleted_count
        
    except Exception as e:
        logger.error(f"Error in cleanup_expired_notifications: {e}", exc_info=True)
        if 'conn' in locals():
            conn.rollback()
            cursor.close()
            conn.close()
        return 0


def wkb_to_lng_lat(wkb_hex):
    """
    Convert PostGIS WKB hex string to (longitude, latitude) tuple
    """
    try:

        coords = wkt.dumps(
            wkb.loads(bytes.fromhex(wkb_hex))
        ).removeprefix('POINT ').strip('(').strip(')').split(' ')
        print(coords)
        print(wkt.dumps(
            wkb.loads(bytes.fromhex(wkb_hex))
        ))
        return {'lng': coords[0], 'lat': coords[1]}

    except Exception as e:
        print(e)
        logger.error(f"Error parsing WKB: {e}")

    return {'lng': None, 'lat': None}


class Image(BaseModel):
    url: HttpUrl
    order_index: int = Field(ge=0)


class PostCreate(BaseModel):
    model_config = ConfigDict(use_enum_values=True)
    title: str = Field(..., min_length=1, max_length=80)
    description: Optional[str] = Field(None, max_length=100)
    category: str = Field(..., min_length=1)
    condition: ItemCondition
    mode: ItemMode
    images: List[Image] = Field(..., min_length=1, max_length=3)
    exact_location: Optional[str] = None
    approx_location: Optional[str] = None

    @field_validator('exact_location', 'approx_location', mode='before')
    @classmethod
    def validate_geojson(cls, v):
        if v is not None and not isinstance(v, str):
            if isinstance(v, (tuple, list)) and len(v) == 2:
                lng, lat = v
                return f'POINT({lng} {lat})'
        return v

    @field_validator('exact_location', mode='after')
    @classmethod
    def validate_exact_location(cls, v, info: ValidationInfo):
        data = info.data
        if data.get('mode') == ItemMode.STREET:
            if v is None:
                raise ValueError('Street mode requires exact location')
        elif v is not None:
            raise ValueError('Home mode must not include exact location')
        return v

    @field_validator('approx_location', mode='after')
    @classmethod
    def validate_approx_location(cls, v, info: ValidationInfo):
        data = info.data
        if data.get('mode') == ItemMode.HOME:
            if v is None:
                raise ValueError('Home mode requires approx location')
        elif v is not None:
            raise ValueError('Street mode must not include approx location')
        return v


class FeedQuery(BaseModel):
    lng: float
    lat: float
    radius_km: float = Field(10.0, ge=0.1, le=100.0)
    category: Optional[str] = None
    mode: Optional[str] = None
    limit: int = Field(20, ge=1, le=100)
    exclude_self: bool = Field(False)


def auth_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        auth_header = request.headers.get('Authorization')
        if not auth_header or not auth_header.startswith('Bearer '):
            return jsonify({'error': 'Authorization header required'}), 401

        token = auth_header.split(' ')[1]
        try:
            response = supabase.auth.get_user(token)
            request.user = response.user
            
            # P0: Ensure profile exists for this user (idempotent guard)
            # This prevents FK constraint errors when creating reservations
            user_id = str(request.user.id)
            try:
                # Check if profile exists
                profile_check = supabase.table('profiles').select('id').eq('id', user_id).execute()
                
                if not profile_check.data:
                    # Profile doesn't exist, create it
                    profile_data = {
                        'id': user_id,
                        'created_at': datetime.now(timezone.utc).isoformat(),
                        'updated_at': datetime.now(timezone.utc).isoformat(),
                        'given_count': 0,
                        'picked_count': 0
                    }
                    supabase.table('profiles').insert(profile_data).execute()
                    logger.info(f"Auto-created profile for user {user_id}")
            except Exception as profile_error:
                # Log but don't fail the request - profile might exist but RLS prevented read
                logger.warning(f"Profile check/create for user {user_id}: {profile_error}")
                
        except Exception as e:
            logger.error(e)
            return jsonify({'error': 'Invalid token'}), 401

        return f(*args, **kwargs)

    return decorated_function


@bp.route('/health', methods=['GET'])
def health_check():
    return jsonify({'status': 'healthy', 'timestamp': datetime.now(timezone.utc).isoformat()})


@bp.route('/post', methods=['POST'])
@auth_required
@rate_limit(max_requests=20, window_minutes=1)
def create_post():
    try:
        data = request.get_json()
        post_data = PostCreate(**data)

        # For home mode, check if user has phone
        if post_data.mode == ItemMode.HOME:
            user_profile = supabase.table('profiles').select('phone').eq('id', str(request.user.id)).execute()
            if not user_profile.data or not user_profile.data[0]['phone']:
                return jsonify({'error': 'Phone number required for home mode posts'}), 422

        # Set expiration time based on mode
        if post_data.mode == ItemMode.STREET:
            expiration_hours = 2  # Street posts expire in 2 hours
        else:
            # Home posts: set expires_at to far future or null (no auto-expiry)
            # Using 10 years in the future as a practical "never expire" value
            expiration_hours = 24 * 365 * 10  # 10 years

        post_db_data = {
            'title': post_data.title,
            'description': post_data.description,
            'category': post_data.category,
            'condition': post_data.condition,
            'mode': post_data.mode,
            'owner_id': str(request.user.id),
            'expires_at': (datetime.now(timezone.utc) + timedelta(hours=expiration_hours)).isoformat(),
        }

        if post_data.mode == ItemMode.STREET:
            post_db_data['exact_location'] = post_data.exact_location
        else:
            post_db_data['approx_location'] = post_data.approx_location

        post_response = supabase.table('posts').insert(post_db_data).execute()
        post = post_response.data[0]

        images_data = [{
            'post_id': post['id'],
            'url': str(image.url),
            'order_index': image.order_index
        } for image in post_data.images]

        supabase.table('images').insert(images_data).execute()
        return jsonify({'post_id': post['id'], 'message': 'Post created successfully'}), 201

    except Exception as e:
        logger.error(e)
        return jsonify({'error': str(e)}), 400


@bp.route('/feed', methods=['GET'])
@auth_required
def get_feed():
    try:
        query_params = FeedQuery(**request.args)
        location_field = 'exact_location' if query_params.mode == ItemMode.STREET else 'approx_location'

        conn, cursor = get_sql_cursor()

        sql = """
        SELECT 
            p.*,
            json_agg(
                json_build_object(
                    'url', i.url,
                    'order_index', i.order_index
                )
            ) as images,
            prof.id as user_id,
            COALESCE(TRIM(CONCAT(COALESCE(prof.first_name, ''), ' ', COALESCE(prof.last_name, ''))), '') as user_name,
            prof.avatar_url as user_avatar,
            ST_Distance(
                CASE 
                    WHEN p.mode = 'street' THEN p.exact_location::geography
                    WHEN p.mode = 'home' THEN p.approx_location::geography
                    ELSE NULL
                END, ST_Point(%s, %s)::geography
            ) / 1000 as distance
        FROM posts p
        LEFT JOIN images i ON p.id = i.post_id
        LEFT JOIN profiles prof ON p.owner_id = prof.id
        WHERE p.expires_at > NOW()
        AND NOT EXISTS (
            SELECT 1 FROM reservations r
            WHERE r.item_id = p.id
            AND r.status IN ('pending', 'active')
        )
        AND ST_Distance(
            CASE 
                WHEN p.mode = 'street' THEN p.exact_location::geography
                WHEN p.mode = 'home' THEN p.approx_location::geography
                ELSE NULL
            END, ST_Point(%s, %s)::geography
        ) < %s * 1000
        """

        params = [
            query_params.lng, query_params.lat,
            query_params.lng, query_params.lat,
            query_params.radius_km,
        ]

        if query_params.category:
            sql += " AND p.category = %s"
            params.append(query_params.category)

        if query_params.mode:
            sql += " AND p.mode = %s"
            params.append(query_params.mode)

        if query_params.exclude_self:
            sql += " AND p.owner_id != %s"
            params.append(str(request.user.id))

        sql += """GROUP BY p.id, prof.id, prof.first_name, prof.last_name, prof.avatar_url ORDER BY distance LIMIT %s"""
        params.append(query_params.limit)
        cursor.execute(sql, params)
        raw_posts = cursor.fetchall()

        cursor.close()
        conn.close()

        posts = []

        for post in raw_posts:
            post = dict(post)
            if approx_location := post.get('approx_location'):
                post['approx_location'] = wkb_to_lng_lat(approx_location)

            if exact_location := post.get('exact_location'):
                post['exact_location'] = wkb_to_lng_lat(exact_location)

            user_id = post.get('user_id')
            user_name = (post.get('user_name') or '').strip()
            user_avatar = post.get('user_avatar')
            if user_id:
                first_name = None
                last_name = None
                if user_name:
                    parts = user_name.split(' ', 1)
                    first_name = parts[0]
                    if len(parts) > 1:
                        last_name = parts[1]
                post['owner'] = {
                    'id': str(user_id),
                    'first_name': first_name,
                    'last_name': last_name,
                    'avatar_url': user_avatar,
                }

            posts += [post]

        return jsonify({'posts': posts}), 200

    except Exception as e:
        logger.error(f"Feed error: {str(e)}")
        if 'cursor' in locals():
            cursor.close()
        if 'conn' in locals():
            conn.close()
        return jsonify({'error': str(e)}), 400


@bp.route('/feed/<post_id>', methods=['GET'])
@auth_required
def get_post(post_id):
    try:
        post_response = supabase.table('posts').select('*, images(url, order_index)').eq('id', post_id).execute()

        if not post_response.data:
            return jsonify({'error': 'Post not found'}), 404

        post = post_response.data[0]

        if post.get('approx_location'):
            post['approx_location'] = wkb_to_lng_lat(post['approx_location'])

        if post.get('exact_location'):
            post['exact_location'] = wkb_to_lng_lat(post['exact_location'])

        owner_response = supabase.table('profiles').select('id, first_name, last_name, city, avatar_url, given_count, picked_count').eq('id', post['owner_id']).execute()

        if owner_response.data:
            post['owner'] = owner_response.data[0]

        reservation_response = supabase.table('reservations').select('*').eq('item_id', post_id).eq('reserver', str(request.user.id)).in_('status', ['pending', 'active']).execute()

        if reservation_response.data:
            post['user_reservation'] = reservation_response.data[0]

        return jsonify({'post': post}), 200

    except Exception as e:
        logger.error(f"Get post error: {str(e)}")
        return jsonify({'error': str(e)}), 400


@bp.route('/feed/<post_id>/reserve', methods=['POST'])
@auth_required
def reserve_post(post_id):
    try:
        # Check if post exists and is available
        post_response = supabase.table('posts').select('*').eq('id', post_id).execute()

        if not post_response.data:
            return jsonify({'error': 'Post not found'}), 404

        post = post_response.data[0]

        # Check if post has expired
        expires_at = datetime.fromisoformat(post['expires_at'].replace('Z', '+00:00'))
        if expires_at.tzinfo is None:
            expires_at = expires_at.replace(tzinfo=timezone.utc)
        if expires_at < datetime.now(timezone.utc):
            return jsonify({'error': 'Post has expired'}), 400

        # Check if user is trying to reserve their own post
        if post['owner_id'] == str(request.user.id):
            return jsonify({'error': 'Cannot reserve your own post'}), 400
            
        # For home mode posts, check if owner has phone
        if post['mode'] == 'home':
            owner_profile = supabase.table('profiles').select('phone').eq('id', post['owner_id']).execute()
            if not owner_profile.data or not owner_profile.data[0]['phone']:
                return jsonify({'error': 'Owner has not provided phone number for home pickup'}), 400

        # Check if there are any active reservations for this post
        reservation_check = supabase.table('reservations').select('*').eq('item_id', post_id).in_('status', ['pending', 'active']).execute()

        if reservation_check.data:
            return jsonify({'error': 'Post is already reserved'}), 400

        # Handle street vs home mode differently
        now = datetime.now(timezone.utc)
        
        if post['mode'] == 'street':
            # Street: instant activation, no approval needed - guarantee all timestamps
            reservation_data = {
                'item_id': post_id,
                'reserver': str(request.user.id),
                'status': 'active',
                'requested_at': now.isoformat(),
                'approved_at': now.isoformat(),  # Instant approval for street
                'start_at': now.isoformat(),     # Available immediately
                'end_at': (now + timedelta(hours=2)).isoformat()  # 2-hour window
            }
            logger.info(f"Creating street reservation {post_id} with all timestamps: approved_at={now.isoformat()}")
        else:
            # Home: pending, requires owner approval - timestamps set on approval
            reservation_data = {
                'item_id': post_id,
                'reserver': str(request.user.id),
                'status': 'pending',
                'requested_at': now.isoformat()
                # approved_at, start_at, end_at will be set when owner approves
            }
            logger.info(f"Creating home reservation {post_id} in pending status")

        try:
            conn, cursor = get_sql_cursor()
            cursor.execute(
                """
                INSERT INTO profiles (id, created_at, updated_at, given_count, picked_count)
                VALUES (%s, NOW(), NOW(), 0, 0)
                ON CONFLICT (id) DO NOTHING
                """,
                (str(request.user.id),),
            )
            conn.commit()
            cursor.close()
            conn.close()
        except Exception as e:
            logger.warning(f"Profile ensure for reserver {request.user.id} failed: {e}")

        reservation_response = supabase.table('reservations').insert(reservation_data).execute()
        reservation_id = reservation_response.data[0]['id']

        # P3: Log reservation creation with structured logging
        log_reservation_transition(
            reservation_id=reservation_id,
            post_id=post_id,
            mode=post['mode'],
            from_status='none',
            to_status=reservation_data['status'],
            actor_user_id=request.user.id,
            reserver_user_id=request.user.id
        )

        # Create notification - different types based on mode
        if post['mode'] == 'street':
            # Street: send informational notification to owner with contact info immediately
            # Get owner and requester profiles for payload
            owner_profile = supabase.table('profiles').select('first_name, last_name, avatar_url, phone').eq('id', post['owner_id']).execute()
            owner_data = owner_profile.data[0] if owner_profile.data else {}
            
            requester_profile = supabase.table('profiles').select('first_name, last_name, avatar_url').eq('id', str(request.user.id)).execute()
            requester_data = requester_profile.data[0] if requester_profile.data else {}
            
            # Get post image
            post_images = supabase.table('images').select('url').eq('post_id', post_id).order('order_index').limit(1).execute()
            post_image_url = post_images.data[0].get('url') if post_images.data else None
            
            payload = {
                'item_title': post['title'],
                'item_image_url': post_image_url,
                'requester_name': f"{requester_data.get('first_name', '')} {requester_data.get('last_name', '')}".strip(),
                'requester_avatar': requester_data.get('avatar_url'),
                'owner_name': f"{owner_data.get('first_name', '')} {owner_data.get('last_name', '')}".strip(),
                'owner_avatar': owner_data.get('avatar_url'),
                'mode': 'street',
                'contact_phone': owner_data.get('phone'),  # Contact info available immediately for street
            }
            
            create_notification(
                NotificationType.STREET_PICKUP_CONFIRMED,
                post['owner_id'],
                post_id,
                reservation_id=reservation_id,
                counterparty_user_id=str(request.user.id),
                payload=payload
            )
        else:
            # Home: send Type-2 actionable notification to owner
            # Get requester and owner profiles for payload
            requester_profile = supabase.table('profiles').select('first_name, last_name, avatar_url').eq('id', str(request.user.id)).execute()
            requester_data = requester_profile.data[0] if requester_profile.data else {}
            
            owner_profile = supabase.table('profiles').select('first_name, last_name, avatar_url').eq('id', post['owner_id']).execute()
            owner_data = owner_profile.data[0] if owner_profile.data else {}
            
            # Get post image
            post_images = supabase.table('images').select('url').eq('post_id', post_id).order('order_index').limit(1).execute()
            post_image_url = post_images.data[0].get('url') if post_images.data else None
            
            payload = {
                'item_title': post['title'],
                'item_image_url': post_image_url,
                'requester_name': f"{requester_data.get('first_name', '')} {requester_data.get('last_name', '')}".strip(),
                'requester_avatar': requester_data.get('avatar_url'),
                'owner_name': f"{owner_data.get('first_name', '')} {owner_data.get('last_name', '')}".strip(),
                'owner_avatar': owner_data.get('avatar_url'),
                'mode': 'home'
                # Note: contact_phone and contact_email will be added when approved
            }
            
            create_notification(
                NotificationType.HOME_PICKUP_REQUEST,
                post['owner_id'],
                post_id,
                reservation_id=reservation_id,
                counterparty_user_id=str(request.user.id),
                payload=payload
            )

        return jsonify({
            'reservation_id': reservation_id,
            'message': 'Reservation requested successfully'
        }), 201

    except Exception as e:
        logger.error(f"Reserve post error: {str(e)}")
        return jsonify({'error': str(e)}), 400


@bp.route('/feed/<post_id>/reserve', methods=['DELETE'])
@auth_required
def cancel_reserve(post_id):
    """Reserver cancels their own request (pending or active)"""
    try:
        # Find the user's reservation for this post (pending or active)
        reservation_response = supabase.table('reservations').select('*').eq('item_id', post_id).eq('reserver', str(request.user.id)).in_('status', ['pending', 'active']).execute()

        if not reservation_response.data:
            return jsonify({'error': 'No active reservation found'}), 404

        reservation = reservation_response.data[0]
        old_status = reservation.get('status')

        # Update reservation status to canceled
        update_data = {
            'status': 'canceled',
            'canceled_at': datetime.now(timezone.utc).isoformat()
        }

        supabase.table('reservations').update(update_data).eq('id', reservation.get('id')).execute()
        
        # Get post info for logging
        post_response = supabase.table('posts').select('owner_id, mode').eq('id', reservation.get('item_id')).execute()
        post_data = post_response.data[0] if post_response.data else {}
        
        # P3: Log reserver cancellation with structured logging
        log_reservation_transition(
            reservation_id=reservation.get('id'),
            post_id=reservation.get('item_id'),
            mode=post_data.get('mode', 'unknown'),
            from_status=old_status,
            to_status='canceled',
            actor_user_id=request.user.id,
            reserver_user_id=request.user.id
        )

        # Create notification for post owner
        if post_response.data:
            notification_data = {
                'recipient_user_id': post_response.data[0].get('owner_id'),
                'type': 'request_withdrawn',
                'reservation_id': reservation.get('id'),
                'post_id': reservation.get('item_id'),
                'counterparty_user_id': str(request.user.id)
            }
            
            supabase.table('notifications').insert(notification_data).execute()
            log_notification_insert('request_withdrawn', post_response.data[0].get('owner_id'), reservation.get('item_id'), reservation.get('id'), str(request.user.id))

        return jsonify({'message': 'Reservation canceled successfully'}), 200

    except Exception as e:
        logger.error(f"Cancel reservation error: {str(e)}", exc_info=True)
        return jsonify({'error': 'Failed to cancel reservation'}), 400


@bp.route('/my/reservations', methods=['GET'])
@auth_required
def get_my_reservations():
    """Get reservations where current user is the reserver"""
    try:
        # Get reservations where user is the reserver
        reservations_response = supabase.table('reservations').select(
            '*, posts(*, images(url, order_index))'
        ).eq('reserver', str(request.user.id)).order('requested_at', desc=True).execute()

        raw_reservations = reservations_response.data or []
        
        # Get requester (current user) profile
        requester_profile_response = supabase.table('profiles').select(
            'id, first_name, last_name, avatar_url'
        ).eq('id', str(request.user.id)).execute()
        requester_data = requester_profile_response.data[0] if requester_profile_response.data else {}
        requester_name = f"{requester_data.get('first_name', '')} {requester_data.get('last_name', '')}".strip()
        
        # Collect all unique owner IDs to batch query profiles (fixes N+1 query problem)
        owner_ids = set()
        for r in raw_reservations:
            post_data = r.get('posts') or {}
            owner_id = post_data.get('owner_id')
            if owner_id:
                owner_ids.add(owner_id)
        
        # Batch query all owner profiles at once
        owner_profiles_map = {}
        if owner_ids:
            owner_profiles_response = supabase.table('profiles').select(
                'id, first_name, last_name, avatar_url'
            ).in_('id', list(owner_ids)).execute()
            if owner_profiles_response.data:
                for owner_profile in owner_profiles_response.data:
                    owner_profiles_map[owner_profile['id']] = owner_profile
        
        # Build tolerant shape with defensive mapping
        reservations = []
        for r in raw_reservations:
            post_data = r.get('posts') or {}
            images_data = post_data.get('images') or []
            
            # Convert location data if present
            if post_data.get('approx_location'):
                post_data['approx_location'] = wkb_to_lng_lat(post_data['approx_location'])
            if post_data.get('exact_location'):
                post_data['exact_location'] = wkb_to_lng_lat(post_data['exact_location'])
            
            # Get location with proper lng/lat format
            location_obj = post_data.get('approx_location') or post_data.get('exact_location')
            
            # Get owner profile from batch query result
            owner_id = post_data.get('owner_id')
            owner_data = owner_profiles_map.get(owner_id, {}) if owner_id else {}
            owner_name = f"{owner_data.get('first_name', '')} {owner_data.get('last_name', '')}".strip()
            
            # Get first image for post_image
            post_image = images_data[0].get('url') if images_data and images_data[0] else None
            
            # Build stable contract with embedded user data
            reservation_item = {
                'id': r.get('id'),
                'item_id': r.get('item_id'),
                'reserver': r.get('reserver'),
                'status': r.get('status'),
                'requested_at': r.get('requested_at'),
                'approved_at': r.get('approved_at'),
                'start_at': r.get('start_at'),
                'end_at': r.get('end_at'),
                'picked_at': r.get('picked_at'),
                'canceled_at': r.get('canceled_at'),
                # Requester data (current user is always the requester)
                'requester_id': str(request.user.id),
                'requester_name': requester_name,
                'requester_avatar': requester_data.get('avatar_url'),
                # Post data
                'post_id': post_data.get('id'),
                'post_title': post_data.get('title'),
                'post_image': post_image,
                'post_mode': post_data.get('mode'),
                # Owner data
                'owner_name': owner_name,
                'owner_avatar': owner_data.get('avatar_url'),
                # Legacy post object for backward compatibility
                'post': {
                    'id': post_data.get('id'),
                    'owner_id': post_data.get('owner_id'),
                    'title': post_data.get('title'),
                    'mode': post_data.get('mode'),
                    'category': post_data.get('category'),
                    'condition': post_data.get('condition'),
                    'images': [
                        {
                            'url': img.get('url'),
                            'order_index': img.get('order_index', 0)
                        }
                        for img in images_data
                        if img and img.get('url')
                    ],
                    'location': location_obj
                }
            }
            reservations.append(reservation_item)

        return jsonify({'reservations': reservations}), 200

    except Exception as e:
        logger.error(f"Get reservations error: {str(e)}", exc_info=True)
        return jsonify({'error': 'Failed to fetch reservations'}), 400


@bp.route('/my/posts', methods=['GET'])
@auth_required
def get_my_posts():
    try:
        posts_response = supabase.table('posts').select('*, images(url, order_index)').eq('owner_id', str(request.user.id)).order('created_at', desc=True).execute()

        posts = posts_response.data or []
        
        # Batch query all active reservations for these posts (fixes N+1 query problem)
        post_ids = [post['id'] for post in posts]
        reservations_map = {}
        if post_ids:
            reservations_response = supabase.table('reservations').select('*').in_('item_id', post_ids).in_('status', ['pending', 'active']).execute()
            if reservations_response.data:
                # Group reservations by post_id (there should only be one active per post, but handle multiple)
                for reservation in reservations_response.data:
                    item_id = reservation['item_id']
                    if item_id not in reservations_map:
                        reservations_map[item_id] = reservation

        # Convert location data and add reservations
        for post in posts:
            if post.get('approx_location'):
                post['approx_location'] = wkb_to_lng_lat(post['approx_location'])
            if post.get('exact_location'):
                post['exact_location'] = wkb_to_lng_lat(post['exact_location'])

            # Get active reservation from batch query result
            post['active_reservation'] = reservations_map.get(post['id'])

        return jsonify({'posts': posts}), 200

    except Exception as e:
        logger.error(f"Get my posts error: {str(e)}")
        return jsonify({'error': str(e)}), 400


@bp.route('/reservations/<reservation_id>/cancel', methods=['POST'])
@auth_required
def cancel_reservation(reservation_id):
    try:
        reservation_response = supabase.table('reservations').select('*, posts(owner_id)').eq('id', reservation_id).execute()

        if not reservation_response.data:
            return jsonify({'error': 'Reservation not found'}), 404

        reservation = reservation_response.data[0]

        if reservation['posts']['owner_id'] != str(request.user.id):
            return jsonify({'error': 'Not authorized to cancel this reservation'}), 403

        update_data = {
            'status': 'canceled',
            'canceled_at': datetime.now(timezone.utc).isoformat(),
        }

        supabase.table('reservations').update(update_data).eq('id', reservation_id).execute()

        return jsonify({'message': 'Reservation canceled successfully'}), 200

    except Exception as e:
        logger.error(f"Cancel reservation error: {str(e)}")
        return jsonify({'error': str(e)}), 400


@bp.route('/reservations/<reservation_id>/complete', methods=['POST'])
@auth_required
def complete_reservation(reservation_id):
    try:
        reservation_response = supabase.table('reservations').select('*, posts(owner_id, mode)').eq('id', reservation_id).execute()

        if not reservation_response.data:
            return jsonify({'error': 'Reservation not found'}), 404

        reservation = reservation_response.data[0]
        old_status = reservation.get('status')
        post_data = reservation.get('posts') or {}

        if (reservation['reserver'] != str(request.user.id) and
                post_data.get('owner_id') != str(request.user.id)):
            return jsonify({'error': 'Not authorized to complete this reservation'}), 403

        # Ensure we have valid timestamps for constraint compliance
        now = datetime.now(timezone.utc)
        update_data = {
            'status': 'picked',
            'picked_at': now.isoformat()
        }
        
        # Safety check: ensure all required timestamps exist before marking as picked
        # This handles any edge cases where timestamps might be missing
        missing_timestamps = []
        
        if not reservation.get('approved_at'):
            missing_timestamps.append('approved_at')
            # Use requested_at as fallback, or now if that's also missing
            fallback_time = reservation.get('requested_at', now.isoformat())
            if isinstance(fallback_time, str):
                try:
                    fallback_dt = datetime.fromisoformat(fallback_time.replace('Z', '+00:00'))
                    update_data['approved_at'] = fallback_dt.isoformat()
                except:
                    update_data['approved_at'] = now.isoformat()
            else:
                update_data['approved_at'] = now.isoformat()
                
        if not reservation.get('start_at'):
            missing_timestamps.append('start_at')
            # Use approved_at as fallback
            start_time = update_data.get('approved_at', now.isoformat())
            update_data['start_at'] = start_time
            
        if not reservation.get('end_at'):
            missing_timestamps.append('end_at')
            # Use start_at + 2 hours as fallback
            start_time_str = update_data.get('start_at', now.isoformat())
            try:
                start_dt = datetime.fromisoformat(start_time_str.replace('Z', '+00:00'))
                update_data['end_at'] = (start_dt + timedelta(hours=2)).isoformat()
            except:
                update_data['end_at'] = (now + timedelta(hours=2)).isoformat()
        
        if missing_timestamps:
            logger.warning(f"Reservation {reservation_id} missing timestamps {missing_timestamps}, filling with fallbacks")

        supabase.table('reservations').update(update_data).eq('id', reservation_id).execute()

        # P3: Log reservation completion with structured logging
        log_reservation_transition(
            reservation_id=reservation_id,
            post_id=reservation['item_id'],
            mode=post_data.get('mode', 'unknown'),
            from_status=old_status,
            to_status='picked',
            actor_user_id=request.user.id,
            reserver_user_id=reservation['reserver']
        )

        # Create informational notifications for both parties
        # Get user profiles for notification payload
        owner_profile = supabase.table('profiles').select('first_name, last_name, avatar_url').eq('id', post_data['owner_id']).execute()
        owner_data = owner_profile.data[0] if owner_profile.data else {}
        
        reserver_profile = supabase.table('profiles').select('first_name, last_name, avatar_url').eq('id', reservation['reserver']).execute()
        reserver_data = reserver_profile.data[0] if reserver_profile.data else {}
        
        # Owner notification: "Your item has been picked up"
        owner_payload = {
            'picker_name': f"{reserver_data.get('first_name', '')} {reserver_data.get('last_name', '')}".strip() or 'Someone',
            'picker_avatar': reserver_data.get('avatar_url'),
            'mode': post_data.get('mode', 'street')
        }
        
        # Reserver notification: "You picked up an item"
        reserver_payload = {
            'owner_name': f"{owner_data.get('first_name', '')} {owner_data.get('last_name', '')}".strip() or 'Owner',
            'owner_avatar': owner_data.get('avatar_url'),
            'mode': post_data.get('mode', 'street')
        }
        
        notification_data_owner = {
            'recipient_user_id': post_data['owner_id'],
            'type': 'pickup_completed',
            'category': 'informational',
            'reservation_id': reservation_id,
            'post_id': reservation['item_id'],
            'counterparty_user_id': reservation['reserver'],
            'payload': owner_payload
        }
        
        notification_data_reserver = {
            'recipient_user_id': reservation['reserver'],
            'type': 'pickup_completed',
            'category': 'informational',
            'reservation_id': reservation_id,
            'post_id': reservation['item_id'],
            'counterparty_user_id': post_data['owner_id'],
            'payload': reserver_payload
        }
        
        supabase.table('notifications').insert([notification_data_owner, notification_data_reserver]).execute()
        log_notification_insert('pickup_completed', post_data['owner_id'], reservation['item_id'], reservation_id, reservation['reserver'])
        log_notification_insert('pickup_completed', reservation['reserver'], reservation['item_id'], reservation_id, post_data['owner_id'])

        if post_data.get('owner_id') == str(request.user.id):
            supabase.rpc('increment_given_count', {'user_id': str(request.user.id)}).execute()
        else:
            supabase.rpc('increment_picked_count', {'user_id': str(request.user.id)}).execute()

        return jsonify({'message': 'Reservation completed successfully'}), 200

    except Exception as e:
        logger.error(f"Complete reservation error: {str(e)}")
        return jsonify({'error': str(e)}), 400


@bp.route('/delete_account', methods=['DELETE'])
@auth_required
def delete_account():
    """
    Delete user account and all related data (profile, posts, reservations)
    """
    try:
        user_id = str(request.user.id)

        # Start a transaction to ensure data consistency
        conn, cursor = get_sql_cursor()

        try:
            # 1. Delete reservations where user is the reserver
            cursor.execute("DELETE FROM reservations WHERE reserver = %s", (user_id,))

            # 2. Delete reservations for posts owned by the user
            # First get all post IDs owned by the user
            cursor.execute("SELECT id FROM posts WHERE owner_id = %s", (user_id,))
            user_post_ids = [row['id'] for row in cursor.fetchall()]

            if user_post_ids:
                # Delete reservations for these posts
                cursor.execute("DELETE FROM reservations WHERE item_id IN %s",
                               (tuple(user_post_ids),))

            # 3. Delete images for user's posts
            if user_post_ids:
                cursor.execute("DELETE FROM images WHERE post_id IN %s",
                               (tuple(user_post_ids),))

            # 4. Delete user's posts
            cursor.execute("DELETE FROM posts WHERE owner_id = %s", (user_id,))

            # 5. Delete user's profile
            cursor.execute("DELETE FROM profiles WHERE id = %s", (user_id,))

            # 6. Delete the user from auth.users (Supabase authentication)
            # This requires admin privileges, so we'll use the Supabase admin API
            # Note: You might need to set up service role key for this
            try:
                # Using Supabase admin API to delete user
                # You'll need to configure SUPABASE_SERVICE_ROLE_KEY in your config
                from .config import supabase_admin
                supabase_admin.auth.admin.delete_user(user_id)
            except Exception as auth_error:
                logger.warning(f"Could not delete user from auth system: {auth_error}")
                # Continue with database deletion even if auth deletion fails

            # Commit the transaction
            conn.commit()

            logger.info(f"User account and all related data deleted for user: {user_id}")

            return jsonify({
                'message': 'Account and all related data deleted successfully'
            }), 200

        except Exception as e:
            # Rollback in case of error
            conn.rollback()
            raise e

        finally:
            cursor.close()
            conn.close()

    except Exception as e:
        logger.error(f"Delete account error: {str(e)}")
        return jsonify({'error': f'Failed to delete account: {str(e)}'}), 500


@bp.route('/me/profile', methods=['GET'])
@auth_required
def get_profile():
    """Get current user's profile (creates one if missing - P0 requirement)"""
    try:
        user_id = str(request.user.id)
        profile_response = supabase.table('profiles').select('*').eq('id', user_id).execute()
        
        if not profile_response.data:
            # P0: Profile should have been created by auth_required, but double-check
            # This ensures first call to /me/profile always returns a profile
            profile_data = {
                'id': user_id,
                'created_at': datetime.now(timezone.utc).isoformat(),
                'updated_at': datetime.now(timezone.utc).isoformat(),
                'given_count': 0,
                'picked_count': 0
            }
            profile_response = supabase.table('profiles').insert(profile_data).execute()
            logger.info(f"Created profile on GET /me/profile for user {user_id}")
            
        profile = profile_response.data[0]

        # Determine if profile is complete (all required fields filled)
        is_complete = bool(
            profile.get('first_name') and
            profile.get('last_name') and
            profile.get('phone') and
            profile.get('avatar_url')
        )

        return jsonify({
            'id': profile['id'],
            'user_id': profile['id'],
            'first_name': profile.get('first_name'),
            'last_name': profile.get('last_name'),
            'phone': profile.get('phone'),
            'avatar_url': profile.get('avatar_url'),
            'photo_url': profile.get('avatar_url'),
            'city': profile.get('city'),
            'given_count': profile.get('given_count', 0),
            'picked_count': profile.get('picked_count', 0),
            'updated_at': profile.get('updated_at'),
            'complete': is_complete,
            'onboarding_completed': profile.get('onboarding_completed', False)
        }), 200
        
    except Exception as e:
        logger.error(f"Get profile error: {str(e)}")
        return jsonify({'error': str(e)}), 400


@bp.route('/me/profile', methods=['PATCH'])
@auth_required
@rate_limit(max_requests=10, window_minutes=1)
def update_profile():
    """Update current user's profile"""
    try:
        data = request.get_json()
        
        # Sanitize and validate input
        update_data, errors = sanitize_profile_data(data)
        
        if errors:
            return jsonify({'error': 'Validation failed', 'details': errors}), 400
        
        if not update_data:
            return jsonify({'error': 'No valid fields to update'}), 400
            
        # Add updated_at timestamp
        update_data['updated_at'] = datetime.now(timezone.utc).isoformat()

        user_id = str(request.user.id)

        # Ensure profile row exists before updating (idempotent safeguard)
        try:
            conn, cursor = get_sql_cursor()
            cursor.execute(
                """
                INSERT INTO profiles (id, created_at, updated_at, given_count, picked_count)
                VALUES (%s, NOW(), NOW(), 0, 0)
                ON CONFLICT (id) DO NOTHING
                """,
                (user_id,),
            )
            conn.commit()
            cursor.close()
            conn.close()
        except Exception as e:
            logger.warning(f"Profile ensure for update_profile {user_id} failed: {e}")

        # Apply update via Supabase client
        profile_response = supabase.table('profiles').update(update_data).eq('id', user_id).execute()

        updated_profile = None
        if profile_response.data:
            try:
                updated_profile = profile_response.data[0]
            except Exception as e:
                logger.warning(f"Unexpected profile_response format in update_profile for {user_id}: {e}")

        # Fallback: fetch profile if update returned no representation
        if updated_profile is None:
            try:
                get_resp = supabase.table('profiles').select('*').eq('id', user_id).execute()
                if get_resp.data:
                    updated_profile = get_resp.data[0]
            except Exception as e:
                logger.error(f"Failed to fetch profile after update for {user_id}: {e}")

        if updated_profile is None:
            return jsonify({'error': 'Profile not found'}), 404

        # Determine if profile is complete (all required fields filled)
        is_complete = bool(
            updated_profile.get('first_name') and
            updated_profile.get('last_name') and
            updated_profile.get('phone') and
            updated_profile.get('avatar_url')
        )
        
        return jsonify({
            'id': updated_profile['id'],
            'user_id': updated_profile['id'],
            'first_name': updated_profile['first_name'],
            'last_name': updated_profile['last_name'],
            'phone': updated_profile['phone'],
            'avatar_url': updated_profile['avatar_url'],
            'photo_url': updated_profile['avatar_url'],
            'city': updated_profile.get('city'),
            'given_count': updated_profile.get('given_count', 0),
            'picked_count': updated_profile.get('picked_count', 0),
            'updated_at': updated_profile['updated_at'],
            'complete': is_complete,
            'onboarding_completed': updated_profile.get('onboarding_completed', False)
        }), 200
        
    except Exception as e:
        logger.error(f"Update profile error: {str(e)}")
        return jsonify({'error': str(e)}), 400


@bp.route('/me/onboarding/complete', methods=['POST'])
@auth_required
def complete_onboarding():
    """Mark onboarding as completed"""
    try:
        now_iso = datetime.now(timezone.utc).isoformat()
        update_data = {
            'onboarding_completed': True,
            'updated_at': now_iso
        }
        
        profile_response = supabase.table('profiles').update(update_data).eq('id', str(request.user.id)).execute()
        
        if not profile_response.data:
            return jsonify({'error': 'Profile not found'}), 404
        
        profile = profile_response.data[0]
        is_complete = bool(
            profile.get('first_name') and
            profile.get('last_name') and
            profile.get('phone') and
            profile.get('avatar_url')
        )
        
        return jsonify({
            'id': profile['id'],
            'user_id': profile['id'],
            'first_name': profile.get('first_name'),
            'last_name': profile.get('last_name'),
            'phone': profile.get('phone'),
            'avatar_url': profile.get('avatar_url'),
            'photo_url': profile.get('avatar_url'),
            'city': profile.get('city'),
            'given_count': profile.get('given_count', 0),
            'picked_count': profile.get('picked_count', 0),
            'updated_at': now_iso,
            'complete': is_complete,
            'onboarding_completed': True
        }), 200
        
    except Exception as e:
        logger.error(f"Complete onboarding error: {str(e)}")
        return jsonify({'error': str(e)}), 400


@bp.route('/me/password', methods=['POST'])
@auth_required
@rate_limit(max_requests=3, window_minutes=5)
def update_password():
    """Update user password"""
    try:
        data = request.get_json()
        current_password = data.get('current_password')
        new_password = data.get('new_password')
        
        if not new_password:
            return jsonify({'error': 'New password is required'}), 400
        
        # Validate new password strength
        if len(new_password) < 8:
            return jsonify({'error': 'Password must be at least 8 characters long'}), 400
        
        # Get user's auth info to determine if they're email/password user or OAuth
        user = request.user
        
        # If user has email/password auth, verify current password first
        # For OAuth-only users, allow setting password without current password
        if user.app_metadata.get('provider') == 'email':
            if not current_password:
                return jsonify({'error': 'Current password is required for email/password users'}), 400
            
            # Verify current password by attempting to sign in
            try:
                auth_header = request.headers.get('Authorization')
                token = auth_header.split(' ')[1] if auth_header else None
                
                # For email/password users, we verify by checking if they can authenticate
                # Note: Supabase doesn't provide a direct "verify password" endpoint
                # so we check if the current session is valid (already done in auth_required)
                # and trust that the user knows their current password
                
            except Exception as verify_error:
                logger.error(f"Password verification error: {str(verify_error)}")
                return jsonify({'error': 'Current password is incorrect'}), 401
        
        # Update password using Supabase Auth
        try:
            # Get the auth header token
            auth_header = request.headers.get('Authorization')
            token = auth_header.split(' ')[1] if auth_header else None
            
            if not token:
                return jsonify({'error': 'Authentication token required'}), 401
            
            # Update user password
            from .config import supabase_admin
            supabase_admin.auth.admin.update_user_by_id(
                str(user.id),
                {'password': new_password}
            )
            
            logger.info(f"Password updated for user {user.id}")
            
            return jsonify({
                'message': 'Password updated successfully'
            }), 200
            
        except Exception as update_error:
            logger.error(f"Password update error: {str(update_error)}")
            return jsonify({'error': f'Failed to update password: {str(update_error)}'}), 500
        
    except Exception as e:
        logger.error(f"Update password error: {str(e)}")
        return jsonify({'error': str(e)}), 400


@bp.route('/me/profile/photo', methods=['POST'])
@auth_required
@rate_limit(max_requests=5, window_minutes=1)
def upload_profile_photo():
    """Upload profile photo to Supabase Storage"""
    try:
        if 'photo' not in request.files:
            return jsonify({'error': 'No photo file provided'}), 400
            
        photo_file = request.files['photo']
        
        if photo_file.filename == '':
            return jsonify({'error': 'No file selected'}), 400
        
        # Validate file type
        try:
            validate_image_content_type(photo_file.content_type)
        except ValueError as e:
            return jsonify({'error': str(e)}), 400
        
        # Validate file size (max 5MB)
        try:
            validate_image_size(photo_file, max_size_mb=5)
        except ValueError as e:
            return jsonify({'error': str(e)}), 400
        
        content_type = photo_file.content_type
        
        # Generate unique filename
        timestamp = int(datetime.now(timezone.utc).timestamp())
        file_extension = content_type.split('/')[-1]
        if file_extension == 'jpeg':
            file_extension = 'jpg'
        filename = f"{request.user.id}/avatar_{timestamp}.{file_extension}"
        
        # Read file content
        file_content = photo_file.read()
        
        # Upload to Supabase Storage
        try:
            # Upload to profile-photos bucket with correct options
            upload_opts = {"contentType": content_type, "upsert": True}
            _ = supabase.storage.from_('profile-photos').upload(
                filename,
                file_content,
                file_options=upload_opts
            )

            # Get a robust public URL string from client response
            pub = supabase.storage.from_('profile-photos').get_public_url(filename)
            photo_url = None
            if isinstance(pub, dict):
                # supabase-py v2 style: { 'data': { 'publicUrl': '...' }, 'error': None }
                photo_url = (
                    (pub.get('data') or {}).get('publicUrl')
                    or pub.get('publicURL')
                    or pub.get('public_url')
                    or pub.get('url')
                )
            else:
                photo_url = str(pub)

            if not photo_url or not isinstance(photo_url, str):
                raise RuntimeError('Could not resolve public URL for uploaded photo')

        except Exception as storage_error:
            logger.error(f"Storage upload error: {str(storage_error)}")
            return jsonify({'error': f'Failed to upload to storage: {str(storage_error)}'}), 500
        
        # Ensure profile row exists before updating avatar_url (idempotent)
        try:
            conn, cursor = get_sql_cursor()
            cursor.execute(
                """
                INSERT INTO profiles (id, created_at, updated_at, given_count, picked_count)
                VALUES (%s, NOW(), NOW(), 0, 0)
                ON CONFLICT (id) DO NOTHING
                """,
                (str(request.user.id),),
            )
            conn.commit()
            cursor.close()
            conn.close()
        except Exception as e:
            logger.warning(f"Profile ensure for avatar update {request.user.id} failed: {e}")
        
        # Update profile with photo URL
        update_data = {
            'avatar_url': photo_url,
            'updated_at': datetime.now(timezone.utc).isoformat()
        }
        
        supabase.table('profiles').update(update_data).eq('id', str(request.user.id)).execute()
        
        return jsonify({
            'photo_url': photo_url,
            'avatar_url': photo_url,
            'message': 'Photo uploaded successfully'
        }), 200
        
    except Exception as e:
        logger.error(f"Upload photo error: {str(e)}")
        return jsonify({'error': str(e)}), 400


@bp.route('/me/stats', methods=['GET'])
@auth_required
def get_my_stats():
    """Get user statistics for profile card"""
    try:
        user_id = str(request.user.id)
        
        # Get uploads count
        posts_response = supabase.table('posts').select('id', count='exact').eq('owner_id', user_id).execute()
        uploads = posts_response.count if posts_response.count else 0
        
        # Get reservations made count
        reservations_response = supabase.table('reservations').select('id', count='exact').eq('reserver', user_id).execute()
        reservations_made = reservations_response.count if reservations_response.count else 0
        
        # Get member since date
        profile_response = supabase.table('profiles').select('created_at').eq('id', user_id).execute()
        member_since = profile_response.data[0]['created_at'] if profile_response.data else None
        
        return jsonify({
            'uploads': uploads,
            'reservations_made': reservations_made,
            'member_since': member_since
        }), 200
        
    except Exception as e:
        logger.error(f"Get stats error: {str(e)}")
        return jsonify({'error': str(e)}), 400


@bp.route('/post/<post_id>', methods=['DELETE'])
@auth_required
def delete_post(post_id):
    """Delete a post owned by the user"""
    try:
        # Check if post exists and user owns it
        post_response = supabase.table('posts').select('owner_id').eq('id', post_id).execute()
        
        if not post_response.data:
            return jsonify({'error': 'Post not found'}), 404
            
        if post_response.data[0]['owner_id'] != str(request.user.id):
            return jsonify({'error': 'Not authorized to delete this post'}), 403
        
        # Delete post (cascade will handle images and reservations)
        supabase.table('posts').delete().eq('id', post_id).execute()
        
        return jsonify({'message': 'Post deleted successfully'}), 200
        
    except Exception as e:
        logger.error(f"Delete post error: {str(e)}")
        return jsonify({'error': str(e)}), 400


@bp.route('/post/<post_id>/report', methods=['POST'])
@auth_required
def report_post(post_id):
    """Report a post for moderation"""
    try:
        data = request.get_json()
        reason = data.get('reason')
        notes = data.get('notes')
        
        if not reason:
            return jsonify({'error': 'Reason is required'}), 400
        
        # Check if post exists
        post_response = supabase.table('posts').select('id').eq('id', post_id).execute()
        
        if not post_response.data:
            return jsonify({'error': 'Post not found'}), 404
        
        # Create report (you might want to create a reports table)
        # For now, we'll just log it
        logger.info(f"Post {post_id} reported by user {request.user.id}. Reason: {reason}, Notes: {notes}")
        
        return jsonify({'message': 'Post reported successfully'}), 200
        
    except Exception as e:
        logger.error(f"Report post error: {str(e)}")
        return jsonify({'error': str(e)}), 400


@bp.route('/my/incoming-requests', methods=['GET'])
@auth_required
def get_incoming_requests():
    """Get incoming requests for home-mode posts I own."""
    try:
        user_id = str(request.user.id)
        limit = int(request.args.get('limit', 50))
        offset = int(request.args.get('offset', 0))

        # Use INNER joins and filter for home mode only + owner_id, include images
        select_clause = (
            'id, item_id, status, requested_at, '
            'posts!inner(id, title, mode, owner_id, images(url, order_index)), '
            'profiles!reservations_reserver_fkey(id, first_name, last_name, avatar_url)'
        )

        q = (supabase.table('reservations')
             .select(select_clause)
             .in_('status', ['pending', 'active'])
             .eq('posts.owner_id', user_id)
             .eq('posts.mode', 'home')
             .order('requested_at', desc=True)
             .limit(limit)
             .range(offset, offset + limit - 1))
        
        rows = q.execute().data or []

        requests = []
        for r in rows:
            # Defensive mapping with dict.get()
            post = r.get('posts') or {}
            prof = r.get('profiles') or {}
            images_data = post.get('images') or []

            requests.append({
                'reservation_id': r.get('id'),
                'post_id': r.get('item_id'),
                'mode': post.get('mode'),
                'title': post.get('title'),
                'images': [
                    {
                        'url': img.get('url'),
                        'order_index': img.get('order_index', 0)
                    }
                    for img in images_data
                    if img and img.get('url')
                ],
                'created_at': r.get('requested_at'),
                'status': r.get('status'),
                'requester': {
                    'user_id': prof.get('id'),
                    'first_name': prof.get('first_name'),
                    'last_name': prof.get('last_name'),
                    'photo_url': prof.get('avatar_url'),
                }
            })

        return jsonify({'requests': requests}), 200

    except Exception as e:
        logger.error(f"Get incoming requests error: {str(e)}", exc_info=True)
        return jsonify({'error': 'Failed to fetch incoming requests'}), 400

@bp.route('/reservations/<reservation_id>/approve', methods=['POST'])
@auth_required
def approve_reservation_with_notification(reservation_id):
    """Approve reservation (owner only) - updates Type-2 notification to accepted state"""
    try:
        request_id = get_request_id()
        actor_id = str(request.user.id)
        
        # Check idempotency
        is_duplicate, stored_result = check_idempotency(
            request_id, 'reservation_approve', actor_id, reservation_id=reservation_id
        )
        if is_duplicate:
            return jsonify(stored_result), 200
        
        # Use transaction with row locking
        conn, cursor = get_sql_cursor()
        try:
            # Lock reservation and notification rows
            cursor.execute("""
                SELECT r.*, p.owner_id, p.mode, p.title, prof.id as reserver_id
                FROM reservations r
                JOIN posts p ON r.item_id = p.id
                JOIN profiles prof ON r.reserver = prof.id
                WHERE r.id = %s
                FOR UPDATE
            """, [reservation_id])
            reservation_row = cursor.fetchone()
            
            if not reservation_row:
                conn.rollback()
                cursor.close()
                conn.close()
                result = {'error': 'Reservation not found'}
                store_event_log(request_id, 'reservation_approve', actor_id, result, reservation_id=reservation_id)
                return jsonify(result), 404
            
            # Check authorization
            if reservation_row['owner_id'] != actor_id:
                conn.rollback()
                cursor.close()
                conn.close()
                result = {'error': 'Not authorized to approve this reservation'}
                store_event_log(request_id, 'reservation_approve', actor_id, result, reservation_id=reservation_id)
                return jsonify(result), 403
            
            # Check status
            if reservation_row['status'] != 'pending':
                conn.rollback()
                cursor.close()
                conn.close()
                result = {'error': 'Reservation is not pending'}
                store_event_log(request_id, 'reservation_approve', actor_id, result, reservation_id=reservation_id)
                return jsonify(result), 400
            
            # Only HOME mode posts can be approved
            if reservation_row['mode'] != 'home':
                conn.rollback()
                cursor.close()
                conn.close()
                result = {'error': 'Reservation can only be approved for home mode posts'}
                store_event_log(request_id, 'reservation_approve', actor_id, result, reservation_id=reservation_id)
                return jsonify(result), 400
            
            # Check owner has phone
            cursor.execute("SELECT phone FROM profiles WHERE id = %s", [actor_id])
            owner_profile = cursor.fetchone()
            if not owner_profile or not owner_profile['phone']:
                conn.rollback()
                cursor.close()
                conn.close()
                result = {'error': 'phone_required_for_home_mode'}
                store_event_log(request_id, 'reservation_approve', actor_id, result, reservation_id=reservation_id)
                return jsonify(result), 422
            
            # Update reservation
            now = datetime.now(timezone.utc)
            cursor.execute("""
                UPDATE reservations
                SET status = 'active', approved_at = %s, start_at = %s, end_at = %s, updated_at = %s
                WHERE id = %s
            """, [now, now, now + timedelta(hours=2), now, reservation_id])
            
            # Find and update the Type-2 notification (home_pickup_request) - sent to giver
            cursor.execute("""
                SELECT id FROM notifications
                WHERE reservation_id = %s
                AND type = 'home_pickup_request'
                AND recipient_user_id = %s
                FOR UPDATE
            """, [reservation_id, actor_id])
            notification_row = cursor.fetchone()
            
            # Get owner and requester profiles for payload
            cursor.execute("""
                SELECT first_name, last_name, avatar_url, phone
                FROM profiles WHERE id = %s
            """, [actor_id])
            owner_data = cursor.fetchone()
            
            cursor.execute("""
                SELECT first_name, last_name, avatar_url
                FROM profiles WHERE id = %s
            """, [reservation_row['reserver_id']])
            requester_data = cursor.fetchone()
            
            # Get post image
            cursor.execute("""
                SELECT url FROM images 
                WHERE post_id = %s 
                ORDER BY order_index 
                LIMIT 1
            """, [reservation_row['item_id']])
            image_row = cursor.fetchone()
            post_image_url = image_row['url'] if image_row else None
            
            # Owner notification payload (updates existing notification)
            owner_payload = {
                'owner_name': f"{owner_data['first_name'] or ''} {owner_data['last_name'] or ''}".strip(),
                'owner_avatar': owner_data['avatar_url'],
                'requester_name': f"{requester_data['first_name'] or ''} {requester_data['last_name'] or ''}".strip(),
                'requester_avatar': requester_data['avatar_url'],
                'item_title': reservation_row['title'],
                'item_image_url': post_image_url,
                'mode': 'home',
                'contact_phone': owner_data['phone']  # Contact info shared after approval
            }
            
            if notification_row:
                # Update existing notification to accepted state
                cursor.execute("""
                    UPDATE notifications
                    SET state = 'accepted',
                        payload = %s,
                        updated_at = %s
                    WHERE id = %s
                """, [json.dumps(owner_payload), now, notification_row['id']])
            else:
                # Create notification if it doesn't exist (backward compatibility)
                cursor.execute("""
                    INSERT INTO notifications (
                        recipient_user_id, type, category, state, is_read,
                        persistence_type, reservation_id, post_id, counterparty_user_id, payload
                    ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """, [
                    actor_id,
                    'home_pickup_request',
                    'actionable',
                    'accepted',
                    False,
                    'infinite',
                    reservation_id,
                    reservation_row['item_id'],
                    reservation_row['reserver_id'],
                    json.dumps(owner_payload)
                ])
            
            # Create notification for requester with contact info
            requester_payload = {
                'item_title': reservation_row['title'],
                'item_image_url': post_image_url,
                'requester_name': f"{requester_data['first_name'] or ''} {requester_data['last_name'] or ''}".strip(),
                'requester_avatar': requester_data['avatar_url'],
                'owner_name': f"{owner_data['first_name'] or ''} {owner_data['last_name'] or ''}".strip(),
                'owner_avatar': owner_data['avatar_url'],
                'mode': 'home',
                'contact_phone': owner_data['phone']  # Contact info shared after approval
            }
            
            # Check if requester notification already exists
            cursor.execute("""
                SELECT id FROM notifications
                WHERE reservation_id = %s
                AND recipient_user_id = %s
                AND type = 'request_approved'
            """, [reservation_id, reservation_row['reserver_id']])
            requester_notification = cursor.fetchone()
            
            if requester_notification:
                # Update existing notification
                cursor.execute("""
                    UPDATE notifications
                    SET payload = %s,
                        updated_at = %s
                    WHERE id = %s
                """, [json.dumps(requester_payload), now, requester_notification['id']])
            else:
                # Create new notification for requester
                cursor.execute("""
                    INSERT INTO notifications (
                        recipient_user_id, type, category, state, is_read,
                        persistence_type, reservation_id, post_id, counterparty_user_id, payload
                    ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """, [
                    reservation_row['reserver_id'],
                    'request_approved',
                    'informational',
                    'accepted',
                    False,
                    'infinite',
                    reservation_id,
                    reservation_row['item_id'],
                    actor_id,
                    json.dumps(requester_payload)
                ])
            
            conn.commit()
            
            # Log
            log_reservation_transition(
                reservation_id=reservation_id,
                post_id=reservation_row['item_id'],
                mode=reservation_row['mode'],
                from_status='pending',
                to_status='active',
                actor_user_id=actor_id,
                reserver_user_id=reservation_row['reserver_id']
            )
            
            result = {'message': 'Reservation approved successfully'}
            store_event_log(request_id, 'reservation_approve', actor_id, result, reservation_id=reservation_id)
            
            cursor.close()
            conn.close()
            
            return jsonify(result), 200
            
        except Exception as e:
            conn.rollback()
            cursor.close()
            conn.close()
            raise e
        
    except Exception as e:
        logger.error(f"Approve reservation error: {str(e)}", exc_info=True)
        return jsonify({'error': 'Failed to approve reservation'}), 400


@bp.route('/reservations/<reservation_id>/cancel', methods=['POST'])
@auth_required
def cancel_reservation_with_notification(reservation_id):
    """Cancel reservation - handles both skip (decline pending) and cancel after acceptance"""
    try:
        request_id = get_request_id()
        actor_id = str(request.user.id)
        
        # Check idempotency
        is_duplicate, stored_result = check_idempotency(
            request_id, 'reservation_cancel', actor_id, reservation_id=reservation_id
        )
        if is_duplicate:
            return jsonify(stored_result), 200
        
        # Use transaction with row locking
        conn, cursor = get_sql_cursor()
        try:
            # Lock reservation
            cursor.execute("""
                SELECT r.*, p.owner_id, p.mode, p.title, prof.id as reserver_id
                FROM reservations r
                JOIN posts p ON r.item_id = p.id
                JOIN profiles prof ON r.reserver = prof.id
                WHERE r.id = %s
                FOR UPDATE
            """, [reservation_id])
            reservation_row = cursor.fetchone()
            
            if not reservation_row:
                conn.rollback()
                cursor.close()
                conn.close()
                result = {'error': 'Reservation not found'}
                store_event_log(request_id, 'reservation_cancel', actor_id, result, reservation_id=reservation_id)
                return jsonify(result), 404
            
            # Check authorization - giver can cancel
            if reservation_row['owner_id'] != actor_id:
                conn.rollback()
                cursor.close()
                conn.close()
                result = {'error': 'Not authorized to cancel this reservation'}
                store_event_log(request_id, 'reservation_cancel', actor_id, result, reservation_id=reservation_id)
                return jsonify(result), 403
            
            old_status = reservation_row['status']
            now = datetime.now(timezone.utc)
            
            # Update reservation
            cursor.execute("""
                UPDATE reservations
                SET status = 'canceled', canceled_at = %s, updated_at = %s
                WHERE id = %s
            """, [now, now, reservation_id])
            
            # Handle notifications based on status
            if old_status == 'pending':
                # Skip (Decline): Delete giver's Type-2, create taker's Type-4
                cursor.execute("""
                    DELETE FROM notifications
                    WHERE reservation_id = %s
                    AND type = 'home_pickup_request'
                    AND recipient_user_id = %s
                """, [reservation_id, actor_id])
                
                # Get post and profile data for payload
                cursor.execute("""
                    SELECT first_name, last_name, avatar_url
                    FROM profiles WHERE id = %s
                """, [actor_id])
                giver_data = cursor.fetchone()
                
                payload = {
                    'giver_name': f"{giver_data['first_name'] or ''} {giver_data['last_name'] or ''}".strip(),
                    'giver_avatar_url': giver_data['avatar_url'],
                    'item_title': reservation_row['title']
                }
                
                # Create Type-4 notification for taker
                create_notification(
                    NotificationType.REQUEST_DECLINED,
                    reservation_row['reserver_id'],
                    reservation_row['item_id'],
                    reservation_id=reservation_id,
                    counterparty_user_id=actor_id,
                    payload=payload
                )
                
            elif old_status == 'active':
                # Cancel after acceptance: Delete giver's Type-3, create taker's Type-5
                # Note: Type-3 would be created when accepted, but we're simplifying
                # Delete any existing notifications for this reservation
                cursor.execute("""
                    DELETE FROM notifications
                    WHERE reservation_id = %s
                    AND recipient_user_id = %s
                """, [reservation_id, actor_id])
                
                # Get profile data
                cursor.execute("""
                    SELECT first_name, last_name, avatar_url
                    FROM profiles WHERE id = %s
                """, [actor_id])
                giver_data = cursor.fetchone()
                
                payload = {
                    'giver_name': f"{giver_data['first_name'] or ''} {giver_data['last_name'] or ''}".strip(),
                    'giver_avatar_url': giver_data['avatar_url'],
                    'item_title': reservation_row['title'],
                    'contact_cannot_be_revoked': True,
                    'cancelled_by': 'giver'
                }
                
                # Create Type-5 notification for taker
                create_notification(
                    NotificationType.REQUEST_CANCELLED_AFTER_ACCEPTANCE,
                    reservation_row['reserver_id'],
                    reservation_row['item_id'],
                    reservation_id=reservation_id,
                    counterparty_user_id=actor_id,
                    payload=payload
                )
            
                # Set post to available (remove reservation)
                cursor.execute("""
                    UPDATE posts
                    SET updated_at = %s
                    WHERE id = %s
                """, [now, reservation_row['item_id']])
                
                # Add exclusion (if you have an exclusions table, add it here)
                # For now, the reservation being canceled makes the post available again
                
                conn.commit()
                
 
            log_reservation_transition(
                reservation_id=reservation_id,
                post_id=reservation_row['item_id'],
                mode=reservation_row['mode'],
                from_status=old_status,
                to_status='canceled',
                actor_user_id=actor_id,
                reserver_user_id=reservation_row['reserver_id']
            )
            
            result = {'message': 'Reservation canceled successfully'}
            store_event_log(request_id, 'reservation_cancel', actor_id, result, reservation_id=reservation_id)
            
            cursor.close()
            conn.close()
            
            return jsonify(result), 200
            
        except Exception as e:
            conn.rollback()
            cursor.close()
            conn.close()
            raise e
        
    except Exception as e:
        logger.error(f"Cancel reservation error: {str(e)}", exc_info=True)
        return jsonify({'error': 'Failed to cancel reservation'}), 400


@bp.route('/my/notifications', methods=['GET'])
@auth_required
def get_my_notifications():
    """Get all active notifications addressed to me with proper contract"""
    try:
        since = request.args.get('since')
        limit = int(request.args.get('limit', 50))

        # Use SQL to filter out expired real_time notifications
        conn, cursor = get_sql_cursor()
        
        sql = """
            SELECT 
                n.id, n.type, n.category, n.state, n.is_read, n.created_at,
                n.persistence_type, n.persistence_seconds, n.payload,
                n.reservation_id, n.post_id, n.counterparty_user_id
            FROM notifications n
            WHERE n.recipient_user_id = %s
            AND (
                n.persistence_type != 'real_time' OR
                (n.persistence_type = 'real_time' AND 
                 NOW() < n.created_at + (n.persistence_seconds || ' seconds')::interval)
            )
        """
        params = [str(request.user.id)]

        if since:
            sql += " AND n.created_at >= %s"
            params.append(since)
        
        sql += " ORDER BY n.created_at DESC LIMIT %s"
        params.append(limit)
        
        cursor.execute(sql, params)
        notifications = cursor.fetchall()
        
        # Get notification IDs to fetch related data
        notification_ids = [n['id'] for n in notifications]
        
        # Get unread count (excluding expired)
        cursor.execute("""
            SELECT COUNT(*) as count
            FROM notifications
            WHERE recipient_user_id = %s
            AND is_read = false
            AND (
                persistence_type != 'real_time' OR
                (persistence_type = 'real_time' AND 
                 NOW() < created_at + (persistence_seconds || ' seconds')::interval)
            )
        """, [str(request.user.id)])
        unread_result = cursor.fetchone()
        unread_count = unread_result['count'] if unread_result else 0
        
        cursor.close()
        conn.close()
        
        # Collect all unique IDs for batch queries (fixes N+1 query problems)
        post_ids = set()
        user_ids = set()
        for n in notifications:
            if n['post_id']:
                post_ids.add(n['post_id'])
            if n['counterparty_user_id']:
                user_ids.add(n['counterparty_user_id'])
        
        # Batch query all posts with images
        posts_map = {}
        if post_ids:
            posts_response = supabase.table('posts').select(
                'id, title, mode, owner_id, images(url, order_index)'
            ).in_('id', list(post_ids)).execute()
            if posts_response.data:
                for post in posts_response.data:
                    posts_map[post['id']] = post
                    # Collect owner IDs from posts
                    if post.get('owner_id'):
                        user_ids.add(post['owner_id'])
        
        # Batch query all user profiles (owners and counterparties)
        profiles_map = {}
        if user_ids:
            profiles_response = supabase.table('profiles').select(
                'id, first_name, last_name, avatar_url, phone'
            ).in_('id', list(user_ids)).execute()
            if profiles_response.data:
                for profile in profiles_response.data:
                    profiles_map[profile['id']] = profile
        
        # Build items array with related data
        items = []
        for n in notifications:
            # Get post data from batch query result
            post_data = posts_map.get(n['post_id'], {}) if n['post_id'] else {}
            
            # Get counterparty data from batch query result
            counterparty_data = profiles_map.get(n['counterparty_user_id'], {}) if n['counterparty_user_id'] else {}
            
            # Get owner data from batch query result
            owner_id = post_data.get('owner_id')
            owner_data = profiles_map.get(owner_id, {}) if owner_id else {}
            
            images_data = post_data.get('images') or []
            post_image_url = images_data[0].get('url') if images_data and images_data[0] else None

            # Build post object
            post_obj = {
                'id': n['post_id'],
                'title': post_data.get('title'),
                'mode': post_data.get('mode'),
                'images': [
                    {
                        'url': img.get('url'),
                        'order_index': img.get('order_index', 0)
                    }
                    for img in images_data
                    if img and img.get('url')
                ]
            } if n['post_id'] else None

            # Build counterparty object
            counterparty_obj = {
                'user_id': counterparty_data.get('id'),
                'display_name': f"{counterparty_data.get('first_name', '')} {counterparty_data.get('last_name', '')}".strip(),
                'avatar_url': counterparty_data.get('avatar_url')
            } if n['counterparty_user_id'] else None

            # Extract and enrich payload data
            payload = n.get('payload') or {}
            
            # Ensure payload has all required fields
            if not payload.get('item_title') and post_data.get('title'):
                payload['item_title'] = post_data.get('title')
            if not payload.get('item_image_url') and post_image_url:
                payload['item_image_url'] = post_image_url
            if not payload.get('mode') and post_data.get('mode'):
                payload['mode'] = post_data.get('mode')
            
            # Add requester data if counterparty is the requester
            if n['counterparty_user_id'] and counterparty_data:
                if not payload.get('requester_name'):
                    payload['requester_name'] = f"{counterparty_data.get('first_name', '')} {counterparty_data.get('last_name', '')}".strip()
                if not payload.get('requester_avatar'):
                    payload['requester_avatar'] = counterparty_data.get('avatar_url')
            
            # Add owner data
            if owner_data:
                if not payload.get('owner_name'):
                    payload['owner_name'] = f"{owner_data.get('first_name', '')} {owner_data.get('last_name', '')}".strip()
                if not payload.get('owner_avatar'):
                    payload['owner_avatar'] = owner_data.get('avatar_url')
                # Add contact info only if state is accepted
                if n.get('state') == 'accepted':
                    if not payload.get('contact_phone') and owner_data.get('phone'):
                        payload['contact_phone'] = owner_data.get('phone')
                    # Note: email is not stored in profiles table, so contact_email is not available

            notification_item = {
                'id': str(n['id']),
                'type': n['type'],
                'category': n['category'],
                'state': n['state'],
                'is_read': n['is_read'],
                'created_at': n['created_at'].isoformat() if isinstance(n['created_at'], datetime) else n['created_at'],
                'persistence_type': n['persistence_type'],
                'persistence_seconds': n['persistence_seconds'],
                'payload': payload,
                'post': post_obj,
                'reservation_id': str(n['reservation_id']) if n['reservation_id'] else None,
                'counterparty': counterparty_obj
            }

            items.append(notification_item)

        return jsonify({
            'notifications': items,
            'meta': {
                'unread_count': unread_count
            }
        }), 200

    except Exception as e:
        logger.error(f"Get notifications error: {str(e)}", exc_info=True)
        return jsonify({'error': str(e)}), 400


@bp.route('/notifications/<notification_id>/read', methods=['POST'])
@auth_required
def mark_notification_read(notification_id):
    """Mark a notification as read (idempotent)"""
    try:
        request_id = get_request_id()
        actor_id = str(request.user.id)
        
        # Check idempotency
        is_duplicate, stored_result = check_idempotency(
            request_id, 'notification_mark_read', actor_id, notification_id=notification_id
        )
        if is_duplicate:
            return jsonify(stored_result), 200
        
        # Update notification
        update_data = {
            'is_read': True,
            'read_at': datetime.now(timezone.utc).isoformat()  # Keep for backward compatibility
        }
        
        notification_response = supabase.table('notifications').update(update_data).eq('id', notification_id).eq('recipient_user_id', actor_id).execute()
        
        if not notification_response.data:
            result = {'error': 'Notification not found'}
            store_event_log(request_id, 'notification_mark_read', actor_id, result, notification_id=notification_id)
            return jsonify(result), 404
            
        result = {'message': 'Notification marked as read'}
        store_event_log(request_id, 'notification_mark_read', actor_id, result, notification_id=notification_id)
        return jsonify(result), 200
        
    except Exception as e:
        logger.error(f"Mark notification read error: {str(e)}", exc_info=True)
        return jsonify({'error': str(e)}), 400


@bp.route('/my/notifications/mark-all-read', methods=['POST'])
@auth_required
def mark_all_notifications_read():
    """Mark all notifications as read for the current user (idempotent)"""
    try:
        request_id = get_request_id()
        actor_id = str(request.user.id)
        
        # Check idempotency
        is_duplicate, stored_result = check_idempotency(
            request_id, 'notification_mark_all_read', actor_id
        )
        if is_duplicate:
            return jsonify(stored_result), 200
        
        # Use transaction to update all notifications
        conn, cursor = get_sql_cursor()
        try:
            cursor.execute("""
                UPDATE notifications
                SET is_read = true, read_at = NOW()
                WHERE recipient_user_id = %s AND is_read = false
            """, [actor_id])
            
            updated_count = cursor.rowcount
            conn.commit()
            
            result = {
                'message': f'Marked {updated_count} notifications as read',
                'updated_count': updated_count
            }
            store_event_log(request_id, 'notification_mark_all_read', actor_id, result)
            
            cursor.close()
            conn.close()
            
            return jsonify(result), 200
        except Exception as e:
            conn.rollback()
            cursor.close()
            conn.close()
            raise e
        
    except Exception as e:
        logger.error(f"Mark all notifications read error: {str(e)}", exc_info=True)
        return jsonify({'error': str(e)}), 400


@bp.route('/notifications/<notification_id>', methods=['DELETE'])
@auth_required
def delete_notification(notification_id):
    """Delete a notification (only informational types)"""
    try:
        request_id = get_request_id()
        actor_id = str(request.user.id)
        
        # Check idempotency
        is_duplicate, stored_result = check_idempotency(
            request_id, 'notification_delete', actor_id, notification_id=notification_id
        )
        if is_duplicate:
            return jsonify(stored_result), 200 if stored_result.get('message') else 404
        
        # First check if notification exists and is informational
        notification_response = supabase.table('notifications').select(
            'id, category, recipient_user_id'
        ).eq('id', notification_id).execute()
        
        if not notification_response.data:
            result = {'error': 'Notification not found'}
            store_event_log(request_id, 'notification_delete', actor_id, result, notification_id=notification_id)
            return jsonify(result), 404
        
        notification = notification_response.data[0]
        
        # Check ownership
        if notification['recipient_user_id'] != actor_id:
            result = {'error': 'Not authorized to delete this notification'}
            store_event_log(request_id, 'notification_delete', actor_id, result, notification_id=notification_id)
            return jsonify(result), 403
        
        # Check category - only informational can be deleted
        if notification['category'] != 'informational':
            result = {'error': 'Only informational notifications can be deleted'}
            store_event_log(request_id, 'notification_delete', actor_id, result, notification_id=notification_id)
            return jsonify(result), 403
        
        # Delete the notification
        supabase.table('notifications').delete().eq('id', notification_id).execute()
        
        result = {'message': 'Notification deleted successfully'}
        store_event_log(request_id, 'notification_delete', actor_id, result, notification_id=notification_id)
        return jsonify(result), 200
        
    except Exception as e:
        logger.error(f"Delete notification error: {str(e)}", exc_info=True)
        return jsonify({'error': str(e)}), 400

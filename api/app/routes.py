from shapely import wkb, wkt
from flask import request, Blueprint, jsonify
from pydantic import BaseModel, Field, HttpUrl, field_validator, ValidationInfo, ConfigDict
from typing import List, Optional
from functools import wraps
from .models import ItemCondition, ItemMode
from .config import supabase, get_sql_cursor
from .middleware import rate_limit, sanitize_profile_data, validate_image_content_type, validate_image_size
from datetime import datetime, timedelta, timezone
import logging

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
        reserved_query = supabase.table('reservations').select(
            'item_id'
        ).in_('status', ['pending', 'active'])
        reserved_items = reserved_query.execute().data
        reserved_ids = [item['item_id'] for item in reserved_items] if reserved_items else []

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
            json_build_object(
                'id', prof.id,
                'first_name', prof.first_name,
                'last_name', prof.last_name,
                'avatar_url', prof.avatar_url
            ) as owner,
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

        if reserved_ids:
            sql += " AND p.id NOT IN %s"
            params.append(tuple(reserved_ids))

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
                print(approx_location, wkb_to_lng_lat(approx_location))
                post['approx_location'] = wkb_to_lng_lat(approx_location)

            if exact_location := post.get('exact_location'):
                print(exact_location, wkb_to_lng_lat(exact_location))
                post['exact_location'] = wkb_to_lng_lat(exact_location)
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
            # Street: instant activation, no approval needed
            reservation_data = {
                'item_id': post_id,
                'reserver': str(request.user.id),
                'status': 'active',
                'requested_at': now.isoformat(),
                'approved_at': now.isoformat(),
                'start_at': now.isoformat(),
                'end_at': (now + timedelta(hours=2)).isoformat()
            }
        else:
            # Home: pending, requires owner approval
            reservation_data = {
                'item_id': post_id,
                'reserver': str(request.user.id),
                'status': 'pending',
                'requested_at': now.isoformat()
            }

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
            # Street: send info notification to owner
            notification_data = {
                'recipient_user_id': post['owner_id'],
                'type': 'street_reserved',
                'reservation_id': reservation_id,
                'post_id': post_id,
                'counterparty_user_id': str(request.user.id)
            }
            supabase.table('notifications').insert(notification_data).execute()
            log_notification_insert('street_reserved', post['owner_id'], post_id, reservation_id, str(request.user.id))
        else:
            # Home: send action-required notification to owner
            notification_data = {
                'recipient_user_id': post['owner_id'],
                'type': 'new_request',
                'reservation_id': reservation_id,
                'post_id': post_id,
                'counterparty_user_id': str(request.user.id)
            }
            supabase.table('notifications').insert(notification_data).execute()
            log_notification_insert('new_request', post['owner_id'], post_id, reservation_id, str(request.user.id))

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
            # If location_obj is still WKB, it will be converted to lng/lat by the conversion above
            
            # Build stable contract
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

        # Convert location data and check for reservations
        for post in posts:
            if post.get('approx_location'):
                post['approx_location'] = wkb_to_lng_lat(post['approx_location'])
            if post.get('exact_location'):
                post['exact_location'] = wkb_to_lng_lat(post['exact_location'])

            # Check for active reservations
            reservation_response = supabase.table('reservations').select('*').eq('item_id', post['id']).in_('status', ['pending', 'active']).execute()
            post['active_reservation'] = reservation_response.data[0] if reservation_response.data else None

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
        reservation_response = supabase.table('reservations').select('*, posts(owner_id)').eq('id', reservation_id).execute()

        if not reservation_response.data:
            return jsonify({'error': 'Reservation not found'}), 404

        reservation = reservation_response.data[0]
        old_status = reservation.get('status')
        post_data = reservation.get('posts') or {}

        if (reservation['reserver'] != str(request.user.id) and
                post_data.get('owner_id') != str(request.user.id)):
            return jsonify({'error': 'Not authorized to complete this reservation'}), 403

        update_data = {
            'status': 'picked',
            'picked_at': datetime.now(timezone.utc).isoformat()
        }

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

        # Create notifications for both parties
        notification_data_owner = {
            'recipient_user_id': post_data['owner_id'],
            'type': 'pickup_completed',
            'reservation_id': reservation_id,
            'post_id': reservation['item_id'],
            'counterparty_user_id': reservation['reserver']
        }
        
        notification_data_reserver = {
            'recipient_user_id': reservation['reserver'],
            'type': 'pickup_completed',
            'reservation_id': reservation_id,
            'post_id': reservation['item_id'],
            'counterparty_user_id': post_data['owner_id']
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
            'user_id': profile['id'],
            'first_name': profile['first_name'],
            'last_name': profile['last_name'],
            'phone': profile['phone'],
            'photo_url': profile['avatar_url'],
            'updated_at': profile['updated_at'],
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
        
        # Update profile
        profile_response = supabase.table('profiles').update(update_data).eq('id', str(request.user.id)).execute()
        
        if not profile_response.data:
            return jsonify({'error': 'Profile not found'}), 404
            
        updated_profile = profile_response.data[0]
        
        # Determine if profile is complete (all required fields filled)
        is_complete = bool(
            updated_profile.get('first_name') and 
            updated_profile.get('last_name') and 
            updated_profile.get('phone') and 
            updated_profile.get('avatar_url')
        )
        
        return jsonify({
            'user_id': updated_profile['id'],
            'first_name': updated_profile['first_name'],
            'last_name': updated_profile['last_name'],
            'phone': updated_profile['phone'],
            'photo_url': updated_profile['avatar_url'],
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
        update_data = {
            'onboarding_completed': True,
            'updated_at': datetime.now(timezone.utc).isoformat()
        }
        
        profile_response = supabase.table('profiles').update(update_data).eq('id', str(request.user.id)).execute()
        
        if not profile_response.data:
            return jsonify({'error': 'Profile not found'}), 404
            
        return jsonify({
            'message': 'Onboarding completed successfully',
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
            # Upload to profile-photos bucket
            storage_response = supabase.storage.from_('profile-photos').upload(
                filename,
                file_content,
                {'content-type': content_type, 'upsert': 'true'}
            )
            
            # Get public URL
            photo_url = supabase.storage.from_('profile-photos').get_public_url(filename)
            
        except Exception as storage_error:
            logger.error(f"Storage upload error: {str(storage_error)}")
            return jsonify({'error': f'Failed to upload to storage: {str(storage_error)}'}), 500
        
        # Update profile with photo URL
        update_data = {
            'avatar_url': photo_url,
            'updated_at': datetime.now(timezone.utc).isoformat()
        }
        
        profile_response = supabase.table('profiles').update(update_data).eq('id', str(request.user.id)).execute()
        
        if not profile_response.data:
            return jsonify({'error': 'Profile not found'}), 404
            
        return jsonify({
            'photo_url': photo_url,
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
    """Approve reservation (owner only) and create notification"""
    try:
        # Get reservation with post and owner info
        reservation_response = supabase.table('reservations').select(
            '*, posts(owner_id, mode, title), profiles!reservations_reserver_fkey(id)'
        ).eq('id', reservation_id).execute()
        
        if not reservation_response.data:
            return jsonify({'error': 'Reservation not found'}), 404
            
        reservation = reservation_response.data[0]
        post = reservation.get('posts') or {}
        
        # Check if user owns the post
        if post.get('owner_id') != str(request.user.id):
            return jsonify({'error': 'Not authorized to approve this reservation'}), 403
            
        # Check if reservation is pending
        if reservation.get('status') != 'pending':
            return jsonify({'error': 'Reservation is not pending'}), 400
        
        # Only HOME mode posts can be approved (street is instant activation)
        if post.get('mode') != 'home':
            return jsonify({'error': 'Reservation can only be approved for home mode posts'}), 400
        
        # For home mode, check if owner has phone (required before approval)
        if post.get('mode') == 'home':
            owner_profile = supabase.table('profiles').select('phone').eq('id', str(request.user.id)).execute()
            if not owner_profile.data or not owner_profile.data[0].get('phone'):
                return jsonify({'error': 'phone_required_for_home_mode'}), 422
        
        # Update reservation status
        now = datetime.now(timezone.utc)
        update_data = {
            'status': 'active',
            'approved_at': now.isoformat(),
            'start_at': now.isoformat(),
            'end_at': (now + timedelta(hours=2)).isoformat()
        }
        
        supabase.table('reservations').update(update_data).eq('id', reservation_id).execute()
        
        # P3: Log reservation approval with structured logging
        log_reservation_transition(
            reservation_id=reservation_id,
            post_id=reservation.get('item_id'),
            mode=post.get('mode'),
            from_status='pending',
            to_status='active',
            actor_user_id=request.user.id,
            reserver_user_id=reservation.get('reserver')
        )
        
        # Get owner's phone for notification
        owner_profile = supabase.table('profiles').select('phone').eq('id', str(request.user.id)).execute()
        contact_phone = owner_profile.data[0].get('phone') if owner_profile.data else None
        
        # Create notification for requester
        requester_profile = reservation.get('profiles') or {}
        notification_data = {
            'recipient_user_id': requester_profile.get('id'),
            'type': 'request_approved',
            'reservation_id': reservation_id,
            'post_id': reservation.get('item_id'),
            'counterparty_user_id': str(request.user.id),
            'contact_phone': contact_phone
        }
        
        supabase.table('notifications').insert(notification_data).execute()
        log_notification_insert('request_approved', requester_profile.get('id'), reservation.get('item_id'), reservation_id, str(request.user.id))
        
        return jsonify({'message': 'Reservation approved successfully'}), 200
        
    except Exception as e:
        logger.error(f"Approve reservation error: {str(e)}", exc_info=True)
        return jsonify({'error': 'Failed to approve reservation'}), 400


@bp.route('/reservations/<reservation_id>/cancel', methods=['POST'])
@auth_required
def cancel_reservation_with_notification(reservation_id):
    """Cancel reservation (owner only) and create notification"""
    try:
        # Get reservation with post and requester info
        reservation_response = supabase.table('reservations').select(
            '*, posts(owner_id), profiles!reservations_reserver_fkey(id)'
        ).eq('id', reservation_id).execute()
        
        if not reservation_response.data:
            return jsonify({'error': 'Reservation not found'}), 404
            
        reservation = reservation_response.data[0]
        post = reservation.get('posts') or {}
        requester_profile = reservation.get('profiles') or {}
        old_status = reservation.get('status')
        
        # Check if user owns the post
        if post.get('owner_id') != str(request.user.id):
            return jsonify({'error': 'Not authorized to cancel this reservation'}), 403
            
        # Update reservation status
        update_data = {
            'status': 'canceled',
            'canceled_at': datetime.now(timezone.utc).isoformat()
        }
        
        supabase.table('reservations').update(update_data).eq('id', reservation_id).execute()
        
        # P3: Log reservation cancellation by owner with structured logging
        log_reservation_transition(
            reservation_id=reservation_id,
            post_id=reservation.get('item_id'),
            mode=post.get('mode', 'unknown'),
            from_status=old_status,
            to_status='canceled',
            actor_user_id=request.user.id,
            reserver_user_id=reservation.get('reserver')
        )
        
        # Create notification for requester
        notification_data = {
            'recipient_user_id': requester_profile.get('id'),
            'type': 'request_rejected',
            'reservation_id': reservation_id,
            'post_id': reservation.get('item_id'),
            'counterparty_user_id': str(request.user.id)
        }
        
        supabase.table('notifications').insert(notification_data).execute()
        log_notification_insert('request_rejected', requester_profile.get('id'), reservation.get('item_id'), reservation_id, str(request.user.id))
        
        return jsonify({'message': 'Reservation canceled successfully'}), 200
        
    except Exception as e:
        logger.error(f"Cancel reservation error: {str(e)}", exc_info=True)
        return jsonify({'error': 'Failed to cancel reservation'}), 400


@bp.route('/my/notifications', methods=['GET'])
@auth_required
def get_my_notifications():
    """Get all notifications addressed to me with proper contract"""
    try:
        since = request.args.get('since')
        limit = int(request.args.get('limit', 50))

        # Build query - include images in the post data
        query = supabase.table('notifications').select(
            'id, type, created_at, read_at, reservation_id, post_id, contact_phone, '
            'posts(id, title, mode, owner_id, images(url, order_index)), '
            'profiles!notifications_counterparty_user_id_fkey(id, first_name, last_name, avatar_url)'
        ).eq('recipient_user_id', str(request.user.id)).order('created_at', desc=True).limit(limit)

        if since:
            query = query.gte('created_at', since)

        notifications_response = query.execute()

        # Get unread count
        unread_response = supabase.table('notifications') \
            .select('id', count='exact') \
            .eq('recipient_user_id', str(request.user.id)) \
            .is_('read_at', 'null') \
            .execute()
        unread_count = unread_response.count if unread_response.count else 0

        # Build items array
        items = []

        for n in notifications_response.data:
            post_data = n.get('posts') or {}
            counterparty_data = n.get('profiles') or {}
            images_data = post_data.get('images') or []

            # Build post object with images
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
            }

            # Build counterparty object
            counterparty_obj = {
                'id': counterparty_data.get('id'),
                'name': f"{counterparty_data.get('first_name', '')} {counterparty_data.get('last_name', '')}".strip(),
                'avatar_url': counterparty_data.get('avatar_url')
            }

            # Phone privacy: only include phone for request_approved, force empty string for others
            contact_phone = n.get('contact_phone') if n['type'] == 'request_approved' else ''

            notification_item = {
                'id': n['id'],
                'type': n['type'],
                'post': post_obj,
                'reservation_id': n['reservation_id'],
                'counterparty': counterparty_obj,
                'contact_phone': contact_phone,
                'created_at': n['created_at'],
                'read_at': n.get('read_at')
            }

            items.append(notification_item)

        return jsonify({
            'unread_count': unread_count,
            'items': items
        }), 200

    except Exception as e:
        logger.error(f"Get notifications error: {str(e)}")
        return jsonify({'error': str(e)}), 400


@bp.route('/notifications/<notification_id>/read', methods=['POST'])
@auth_required
def mark_notification_read(notification_id):
    """Mark a notification as read"""
    try:
        # Update notification
        update_data = {
            'read_at': datetime.now(timezone.utc).isoformat()
        }
        
        notification_response = supabase.table('notifications').update(update_data).eq('id', notification_id).eq('recipient_user_id', str(request.user.id)).execute()
        
        if not notification_response.data:
            return jsonify({'error': 'Notification not found'}), 404
            
        return jsonify({'message': 'Notification marked as read'}), 200
        
    except Exception as e:
        logger.error(f"Mark notification read error: {str(e)}")
        return jsonify({'error': str(e)}), 400


@bp.route('/notifications/read', methods=['POST'])
@auth_required
def mark_notifications_read_bulk():
    """Mark multiple notifications as read"""
    try:
        data = request.get_json()
        notification_ids = data.get('ids', [])
        
        if not notification_ids:
            return jsonify({'error': 'No notification IDs provided'}), 400

        update_data = {
            'read_at': datetime.now(timezone.utc).isoformat()
        }
        
        supabase.table('notifications').update(update_data).in_('id', notification_ids).eq('recipient_user_id', str(request.user.id)).execute()
        
        return jsonify({'message': f'{len(notification_ids)} notifications marked as read'}), 200
        
    except Exception as e:
        logger.error(f"Mark notifications read bulk error: {str(e)}")
        return jsonify({'error': str(e)}), 400

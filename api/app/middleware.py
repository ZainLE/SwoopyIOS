"""
Middleware for validation and rate limiting
"""
import re
import time
from functools import wraps
from flask import request, jsonify
from collections import defaultdict
from datetime import datetime, timedelta, timezone
import logging

logger = logging.getLogger(__name__)

# In-memory rate limiting storage (for production, use Redis)
# Structure: {user_id: {endpoint: [(timestamp, count)]}}
rate_limit_store = defaultdict(lambda: defaultdict(list))

# Rate limit cleanup interval
CLEANUP_INTERVAL = 300  # 5 minutes
last_cleanup = time.time()


def cleanup_old_entries():
    """Remove old rate limit entries to prevent memory bloat"""
    global last_cleanup
    current_time = time.time()
    
    if current_time - last_cleanup > CLEANUP_INTERVAL:
        cutoff = current_time - 3600  # Remove entries older than 1 hour
        for user_id in list(rate_limit_store.keys()):
            for endpoint in list(rate_limit_store[user_id].keys()):
                rate_limit_store[user_id][endpoint] = [
                    (ts, count) for ts, count in rate_limit_store[user_id][endpoint]
                    if ts > cutoff
                ]
                if not rate_limit_store[user_id][endpoint]:
                    del rate_limit_store[user_id][endpoint]
            if not rate_limit_store[user_id]:
                del rate_limit_store[user_id]
        last_cleanup = current_time


def rate_limit(max_requests=10, window_minutes=1):
    """
    Rate limiting decorator
    
    Args:
        max_requests: Maximum number of requests allowed in the time window
        window_minutes: Time window in minutes
    """
    def decorator(f):
        @wraps(f)
        def decorated_function(*args, **kwargs):
            # Get user ID from request
            user_id = str(request.user.id) if hasattr(request, 'user') else request.remote_addr
            endpoint = request.endpoint
            current_time = time.time()
            window_seconds = window_minutes * 60
            
            # Cleanup old entries periodically
            cleanup_old_entries()
            
            # Get user's rate limit data for this endpoint
            user_requests = rate_limit_store[user_id][endpoint]
            
            # Remove requests outside the time window
            user_requests[:] = [
                (ts, count) for ts, count in user_requests
                if current_time - ts < window_seconds
            ]
            
            # Count total requests in the window
            total_requests = sum(count for _, count in user_requests)
            
            if total_requests >= max_requests:
                logger.warning(f"Rate limit exceeded for user {user_id} on endpoint {endpoint}")
                return jsonify({
                    'error': 'Rate limit exceeded. Please try again later.',
                    'retry_after_seconds': int(window_seconds)
                }), 429
            
            # Add current request
            user_requests.append((current_time, 1))
            
            return f(*args, **kwargs)
        
        return decorated_function
    return decorator


def validate_name(name, field_name="name"):
    """
    Validate name fields (first_name, last_name)
    - Length: 1-50 characters
    - Strip emojis and special characters
    - Allow letters, spaces, hyphens, apostrophes
    """
    if not name:
        return None
    
    # Strip leading/trailing whitespace
    name = name.strip()
    
    # Check length
    if len(name) < 1 or len(name) > 50:
        raise ValueError(f"{field_name} must be between 1 and 50 characters")
    
    # Remove emojis and non-letter characters (except space, hyphen, apostrophe)
    # This regex keeps letters from any language, spaces, hyphens, and apostrophes
    name = re.sub(r'[^\w\s\-\']', '', name, flags=re.UNICODE)
    
    # Remove extra spaces
    name = ' '.join(name.split())
    
    if not name:
        raise ValueError(f"{field_name} contains no valid characters")
    
    return name


def validate_phone(phone):
    """
    Validate phone number
    - Must match E.164 format: +[1-9]\d{1,14}
    """
    if not phone:
        return None
    
    # Strip whitespace
    phone = phone.strip()
    
    # Check E.164 format
    if not re.match(r'^\+?[1-9]\d{1,14}$', phone):
        raise ValueError("Phone number must be in valid international format (e.g., +1234567890)")
    
    # Ensure it starts with +
    if not phone.startswith('+'):
        phone = '+' + phone
    
    return phone


def validate_image_content_type(content_type):
    """
    Validate image content type
    """
    allowed_types = ['image/jpeg', 'image/jpg', 'image/png', 'image/webp']
    
    if content_type not in allowed_types:
        raise ValueError("Invalid file type. Only JPEG, PNG, and WebP images are allowed")
    
    return True


def validate_image_size(file, max_size_mb=5):
    """
    Validate image file size
    """
    file.seek(0, 2)  # Seek to end
    file_size = file.tell()
    file.seek(0)  # Reset to beginning
    
    max_size_bytes = max_size_mb * 1024 * 1024
    
    if file_size > max_size_bytes:
        raise ValueError(f"File too large. Maximum size is {max_size_mb}MB")
    
    return True


def sanitize_profile_data(data):
    """
    Sanitize and validate profile update data
    
    Returns: (sanitized_data, errors)
    """
    sanitized = {}
    errors = []
    
    # Validate first_name
    if 'first_name' in data:
        try:
            sanitized['first_name'] = validate_name(data['first_name'], 'first_name')
        except ValueError as e:
            errors.append(str(e))
    
    # Validate last_name
    if 'last_name' in data:
        try:
            sanitized['last_name'] = validate_name(data['last_name'], 'last_name')
        except ValueError as e:
            errors.append(str(e))
    
    # Validate phone
    if 'phone' in data:
        try:
            sanitized['phone'] = validate_phone(data['phone'])
        except ValueError as e:
            errors.append(str(e))
    
    # Pass through onboarding_completed as-is (boolean)
    if 'onboarding_completed' in data:
        if isinstance(data['onboarding_completed'], bool):
            sanitized['onboarding_completed'] = data['onboarding_completed']
        else:
            errors.append("onboarding_completed must be a boolean")
    
    return sanitized, errors


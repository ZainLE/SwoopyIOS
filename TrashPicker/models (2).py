from datetime import datetime, timezone
from enum import Enum
from typing import List, Optional, Tuple, Any
from uuid import UUID
from pydantic import BaseModel, Field, HttpUrl, field_validator, ValidationInfo, ConfigDict


# Enums
class ItemMode(str, Enum):
    STREET = 'street'
    HOME = 'home'


class ItemCondition(str, Enum):
    BAD = 'bad'
    GOOD = 'good'
    EXCELLENT = 'excellent'


class ReservationStatus(str, Enum):
    PENDING = 'pending'
    ACTIVE = 'active'
    CANCELED = 'canceled'
    PICKED = 'picked'
    EXPIRED = 'expired'


class NotificationType(str, Enum):
    # New types per spec
    STREET_PICKUP_CONFIRMED = 'street_pickup_confirmed'
    HOME_PICKUP_REQUEST = 'home_pickup_request'
    REQUEST_DECLINED = 'request_declined'
    REQUEST_CANCELLED_AFTER_ACCEPTANCE = 'request_cancelled_after_acceptance'
    # Legacy types (for backward compatibility)
    NEW_REQUEST = 'new_request'
    STREET_RESERVED = 'street_reserved'
    REQUEST_APPROVED = 'request_approved'
    REQUEST_REJECTED = 'request_rejected'
    REQUEST_WITHDRAWN = 'request_withdrawn'
    REQUEST_EXPIRED = 'request_expired'
    PICKUP_COMPLETED = 'pickup_completed'


class NotificationCategory(str, Enum):
    ACTIONABLE = 'actionable'
    INFORMATIONAL = 'informational'


class NotificationState(str, Enum):
    PENDING_APPROVAL = 'pending_approval'
    ACCEPTED = 'accepted'
    RESOLVED_COMPLETED = 'resolved_completed'
    RESOLVED_DECLINED = 'resolved_declined'
    RESOLVED_CANCELLED_BY_GIVER = 'resolved_cancelled_by_giver'


class PersistenceType(str, Enum):
    REAL_TIME = 'real_time'
    ACTIVE_VIEW = 'active_view'
    INFINITE = 'infinite'


# Models
class Image(BaseModel):
    id: UUID
    post_id: UUID
    url: HttpUrl
    created_at: datetime
    order_index: int = Field(ge=0)  # For sorting multiple images


class Post(BaseModel):
    model_config = ConfigDict(use_enum_values=True)

    title: str = Field(..., min_length=1, max_length=80)
    description: Optional[str] = Field(None, max_length=100)
    category: str = Field(..., min_length=1)
    condition: ItemCondition
    mode: ItemMode
    image_urls: List[HttpUrl] = Field(..., min_length=1, max_length=3)
    # Using Supabase's geography type - will be stored as PostGIS geography
    exact_location: Optional[str] = None  # GeoJSON point for street mode
    approx_location: Optional[str] = None  # GeoJSON point for home mode
    expires_at: datetime

    @field_validator('exact_location', 'approx_location', mode='before')
    @classmethod
    def validate_geojson(cls, v: Any) -> Optional[str]:
        if v is not None and not isinstance(v, str):
            # Convert tuple/list to GeoJSON string
            if isinstance(v, (tuple, list)) and len(v) == 2:
                lon, lat = v
                return f'POINT({lon} {lat})'
        return v

    @field_validator('exact_location', mode='after')
    @classmethod
    def validate_exact_location(cls, v: Optional[str], info: ValidationInfo) -> Optional[str]:
        data = info.data
        if data.get('mode') == ItemMode.STREET:
            if v is None:
                raise ValueError('Street mode requires exact location')
        elif v is not None:
            raise ValueError('Home mode must not include exact location')
        return v

    @field_validator('approx_location', mode='after')
    @classmethod
    def validate_approx_location(cls, v: Optional[str], info: ValidationInfo) -> Optional[str]:
        data = info.data
        if data.get('mode') == ItemMode.HOME:
            if v is None:
                raise ValueError('Home mode requires approx location')
        elif v is not None:
            raise ValueError('Street mode must not include approx location')
        return v

    @field_validator('image_urls', mode='before')
    @classmethod
    def validate_image_urls(cls, v: Any) -> List[Any]:
        if isinstance(v, str):
            return [v]
        return v


class Profile(BaseModel):
    id: UUID
    first_name: Optional[str] = None
    last_name: Optional[str] = None
    city: Optional[str] = None
    phone: Optional[str] = None
    avatar_url: Optional[str] = None
    given_count: int = Field(0, ge=0)
    picked_count: int = Field(0, ge=0)


class Reservation(BaseModel):
    id: UUID
    item_id: UUID
    reserver: UUID
    status: ReservationStatus
    requested_at: datetime
    approved_at: Optional[datetime] = None
    start_at: Optional[datetime] = None
    end_at: Optional[datetime] = None
    canceled_at: Optional[datetime] = None
    picked_at: Optional[datetime] = None


class Notification(BaseModel):
    id: UUID
    recipient_user_id: UUID
    type: NotificationType
    category: NotificationCategory
    state: Optional[NotificationState] = None  # Only for actionable
    is_read: bool = False
    persistence_type: PersistenceType
    persistence_seconds: Optional[int] = None
    reservation_id: Optional[UUID] = None
    post_id: Optional[UUID] = None
    counterparty_user_id: Optional[UUID] = None
    contact_phone: Optional[str] = None  # Only set for request_approved to the requester
    created_at: datetime
    read_at: Optional[datetime] = None  # Legacy field
    payload: Optional[dict] = None  # JSONB with names, photos, item summary, phone if applicable
    meta: Optional[dict] = None  # JSONB for optional small extras (legacy)


class IncomingRequest(BaseModel):
    reservation_id: UUID
    post_id: UUID
    mode: ItemMode
    title: str
    created_at: datetime
    status: ReservationStatus
    requester: 'UserProfile'


class UserProfile(BaseModel):
    user_id: UUID
    first_name: Optional[str] = None
    last_name: Optional[str] = None
    photo_url: Optional[str] = None


class NotificationItem(BaseModel):
    notification_id: UUID
    type: NotificationType
    created_at: datetime
    post: 'NotificationPost'
    counterparty: Optional[UserProfile] = None
    reservation_id: Optional[UUID] = None
    contact_phone: Optional[str] = None  # Only present when type=request_approved and recipient=requester


class NotificationPost(BaseModel):
    post_id: Optional[UUID] = None
    title: Optional[str] = None
    mode: Optional[ItemMode] = None


class NotificationResponse(BaseModel):
    notifications: List[NotificationItem]
    unread_count: int


class ProfileUpdate(BaseModel):
    first_name: Optional[str] = None
    last_name: Optional[str] = None
    phone: Optional[str] = None


class ProfileResponse(BaseModel):
    user_id: UUID
    first_name: Optional[str] = None
    last_name: Optional[str] = None
    phone: Optional[str] = None
    photo_url: Optional[str] = None
    updated_at: datetime


class BulkReadRequest(BaseModel):
    ids: List[UUID] = Field(..., min_length=1)


# Update forward references
IncomingRequest.model_rebuild()
NotificationItem.model_rebuild()

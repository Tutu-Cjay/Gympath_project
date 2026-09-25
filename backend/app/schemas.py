"""Pydantic request/response models."""
from datetime import datetime

from pydantic import BaseModel, ConfigDict, EmailStr, Field


# ---- auth ----
class RegisterRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=6, max_length=72)
    display_name: str = Field(min_length=1, max_length=80)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    email: EmailStr
    display_name: str
    created_at: datetime


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user: UserOut


# ---- sessions ----
class SessionCreate(BaseModel):
    workout_name: str = Field(min_length=1, max_length=120)
    reps: int = Field(ge=0, default=0)
    accuracy: float = Field(ge=0, le=100, default=0)
    performance: str = Field(max_length=4, default="-")
    bonus: int = Field(ge=0, default=0)
    duration_sec: int = Field(ge=0, default=0)
    client_timestamp: datetime | None = None


class SessionOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    workout_name: str
    reps: int
    accuracy: float
    performance: str
    bonus: int
    duration_sec: int
    client_timestamp: datetime
    created_at: datetime


class BulkSessionCreate(BaseModel):
    sessions: list[SessionCreate]


# ---- stats ----
class StatsOut(BaseModel):
    day_number: int
    streak_days: int
    today_reps: int
    today_sessions: int
    total_sessions: int
    total_reps: int
    total_points: int
    week_sessions: int
    avg_accuracy: float
    daily_rep_goal: int


class LeaderboardEntry(BaseModel):
    rank: int
    display_name: str
    points: int
    total_reps: int
    is_me: bool = False

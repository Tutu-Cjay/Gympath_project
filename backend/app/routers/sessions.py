"""Workout-session sync: single create, bulk upload, and listing."""
from datetime import datetime, timezone

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..auth import get_current_user
from ..database import get_db
from ..models import User, WorkoutSession
from ..schemas import (
    BulkSessionCreate,
    SessionCreate,
    SessionOut,
)

router = APIRouter(prefix="/sessions", tags=["sessions"])


def _to_row(user_id: int, s: SessionCreate) -> WorkoutSession:
    ts = s.client_timestamp or datetime.now(timezone.utc)
    if ts.tzinfo is not None:
        ts = ts.astimezone(timezone.utc).replace(tzinfo=None)
    return WorkoutSession(
        user_id=user_id,
        workout_name=s.workout_name,
        reps=s.reps,
        accuracy=s.accuracy,
        performance=s.performance,
        bonus=s.bonus,
        duration_sec=s.duration_sec,
        client_timestamp=ts,
    )


@router.post("", response_model=SessionOut, status_code=201)
def create_session(
    body: SessionCreate,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
):
    row = _to_row(current.id, body)
    db.add(row)
    db.commit()
    db.refresh(row)
    return row


@router.post("/bulk", response_model=list[SessionOut], status_code=201)
def create_bulk(
    body: BulkSessionCreate,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
):
    rows = [_to_row(current.id, s) for s in body.sessions]
    db.add_all(rows)
    db.commit()
    for r in rows:
        db.refresh(r)
    return rows


@router.get("", response_model=list[SessionOut])
def list_sessions(
    limit: int = 50,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
):
    rows = db.scalars(
        select(WorkoutSession)
        .where(WorkoutSession.user_id == current.id)
        .order_by(WorkoutSession.client_timestamp.desc())
        .limit(min(limit, 200))
    ).all()
    return rows

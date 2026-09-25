"""Aggregated stats + leaderboard."""
from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from ..auth import get_current_user
from ..database import get_db
from ..models import User
from ..schemas import LeaderboardEntry, StatsOut
from ..services import compute_leaderboard, compute_stats

router = APIRouter(tags=["stats"])


@router.get("/stats", response_model=StatsOut)
def my_stats(
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
):
    return compute_stats(db, current.id)


@router.get("/leaderboard", response_model=list[LeaderboardEntry])
def leaderboard(
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
):
    return compute_leaderboard(db, current.id)

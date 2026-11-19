"""Aggregated stats + leaderboard."""
from typing import Literal

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
    by: Literal["week_streak", "week", "muscles", "volume", "reps"] = "week_streak",
    period: Literal["week", "all"] = "all",
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
):
    """Ranked by week streak (default), training days this week, share of
    muscle groups worked this week, or weight moved / reps ([period]: this
    week or all time). The caller is always included, also when outside
    the top."""
    return compute_leaderboard(db, current.id, by=by, period=period)

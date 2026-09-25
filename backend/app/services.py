"""Aggregate stats — mirrors the mobile WorkoutStore so the app and server
agree on streak/points/etc."""
from datetime import date, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import DAILY_REP_GOAL
from .models import User, WorkoutSession
from .schemas import LeaderboardEntry, StatsOut


def _day(dt) -> date:
    return dt.date()


def compute_stats(db: Session, user_id: int) -> StatsOut:
    rows = db.scalars(
        select(WorkoutSession).where(WorkoutSession.user_id == user_id)
    ).all()
    if not rows:
        return StatsOut(
            day_number=1, streak_days=0, today_reps=0, today_sessions=0,
            total_sessions=0, total_reps=0, total_points=0, week_sessions=0,
            avg_accuracy=0.0, daily_rep_goal=DAILY_REP_GOAL,
        )

    today = date.today()
    days_with = {_day(r.client_timestamp) for r in rows}

    # current streak — walk back from today (with a one-day grace if no session yet today)
    streak = 0
    if today in days_with:
        cursor = today
    else:
        cursor = today - timedelta(days=1)
    while cursor in days_with:
        streak += 1
        cursor -= timedelta(days=1)

    first_day = min(_day(r.client_timestamp) for r in rows)
    day_number = (today - first_day).days + 1

    today_rows = [r for r in rows if _day(r.client_timestamp) == today]
    week_ago = today - timedelta(days=6)
    week_sessions = sum(1 for r in rows if _day(r.client_timestamp) >= week_ago)

    total_reps = sum(r.reps for r in rows)
    total_points = sum(r.points for r in rows)
    avg_acc = sum(r.accuracy for r in rows) / len(rows)

    return StatsOut(
        day_number=day_number,
        streak_days=streak,
        today_reps=sum(r.reps for r in today_rows),
        today_sessions=len(today_rows),
        total_sessions=len(rows),
        total_reps=total_reps,
        total_points=total_points,
        week_sessions=week_sessions,
        avg_accuracy=round(avg_acc, 1),
        daily_rep_goal=DAILY_REP_GOAL,
    )


def compute_leaderboard(db: Session, me_id: int, limit: int = 20) -> list[LeaderboardEntry]:
    users = db.scalars(select(User)).all()
    scored = []
    for u in users:
        pts = sum(s.points for s in u.sessions)
        reps = sum(s.reps for s in u.sessions)
        scored.append((u, pts, reps))
    scored.sort(key=lambda t: t[1], reverse=True)
    out: list[LeaderboardEntry] = []
    for i, (u, pts, reps) in enumerate(scored[:limit], start=1):
        out.append(LeaderboardEntry(
            rank=i, display_name=u.display_name, points=pts,
            total_reps=reps, is_me=(u.id == me_id),
        ))
    return out

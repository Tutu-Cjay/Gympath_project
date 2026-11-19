"""Aggregate stats — mirrors the mobile WorkoutStore so the app and server
agree on streak/points/etc."""
from collections import Counter
from datetime import date, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import DAILY_REP_GOAL, WEEK_GOAL_DAYS
from .models import User, WorkoutSession
from .schemas import LeaderboardEntry, StatsOut


def _day(dt) -> date:
    return dt.date()


def week_start(d: date) -> date:
    """Monday of the week [d] is in."""
    return d - timedelta(days=d.weekday())


def week_streak(days: set[date], today: date, goal: int = WEEK_GOAL_DAYS) -> tuple[int, int, int]:
    """(current week streak, best week streak, training days this week).

    A week (Monday to Sunday) counts when it has at least [goal] training
    days. The week in progress does not break the streak before it is over:
    until it reaches the goal, the streak is the run up to last week."""
    per_week = Counter(week_start(d) for d in days if d <= today)
    this_week = week_start(today)
    week = timedelta(weeks=1)
    cursor = this_week if per_week[this_week] >= goal else this_week - week
    current = 0
    while per_week[cursor] >= goal:
        current += 1
        cursor -= week
    best, run, prev = 0, 0, None
    for w in sorted(w for w, n in per_week.items() if n >= goal):
        run = run + 1 if prev is not None and w - prev == week else 1
        best = max(best, run)
        prev = w
    return current, best, per_week[this_week]


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
    weeks, best_weeks, days_week = week_streak(days_with, today)

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
        week_streak=weeks,
        best_week_streak=best_weeks,
        days_this_week=days_week,
        week_goal_days=WEEK_GOAL_DAYS,
    )


def compute_leaderboard(db: Session, me_id: int, limit: int = 20,
                        by: str = "week_streak") -> list[LeaderboardEntry]:
    """Users ranked [by] week streak (then days this week, then reps), by
    training days this week, or by total reps. The top [limit], plus the
    caller with their real rank when they are further down."""
    today = date.today()
    rows = []
    for u in db.scalars(select(User)).all():
        days = {_day(s.client_timestamp) for s in u.sessions}
        weeks, best, this_week = week_streak(days, today)
        rows.append(dict(
            user=u, week_streak=weeks, best_week_streak=best, days_this_week=this_week,
            points=sum(s.points for s in u.sessions),
            total_reps=sum(s.reps for s in u.sessions),
        ))
    keys = {
        "week_streak": lambda r: (r["week_streak"], r["days_this_week"], r["total_reps"]),
        "week": lambda r: (r["days_this_week"], r["week_streak"], r["total_reps"]),
        "reps": lambda r: (r["total_reps"], r["week_streak"]),
    }
    rows.sort(key=keys.get(by, keys["week_streak"]), reverse=True)
    out: list[LeaderboardEntry] = []
    for rank, r in enumerate(rows, start=1):
        is_me = r["user"].id == me_id
        if rank > limit and not is_me:
            continue
        out.append(LeaderboardEntry(
            rank=rank, display_name=r["user"].display_name, points=r["points"],
            total_reps=r["total_reps"], is_me=is_me,
            week_streak=r["week_streak"], best_week_streak=r["best_week_streak"],
            days_this_week=r["days_this_week"], week_goal_days=WEEK_GOAL_DAYS,
        ))
    return out

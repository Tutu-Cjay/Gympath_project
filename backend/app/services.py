"""Aggregate stats — mirrors the mobile WorkoutStore so the app and server
agree on streak/points/etc."""
from collections import Counter
from datetime import date, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import DAILY_REP_GOAL, WEEK_GOAL_DAYS
from .exercises import muscle_coverage
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
                        by: str = "week_streak", period: str = "all") -> list[LeaderboardEntry]:
    """Users ranked [by]:
    - week_streak: weeks in a row (then days this week, then reps)
    - week: training days this week
    - muscles: share of muscle groups worked this week
    - volume / reps: weight moved or reps, this week or all time ([period])
    The top [limit], plus the caller with their real rank when further down."""
    today = date.today()
    monday = week_start(today)
    rows = []
    for u in db.scalars(select(User)).all():
        sessions = u.sessions
        days = {_day(s.client_timestamp) for s in sessions}
        weeks, best, this_week = week_streak(days, today)
        week = [s for s in sessions if monday <= _day(s.client_timestamp) <= today]
        active, total = muscle_coverage(s.workout_name for s in week)
        rows.append(dict(
            user=u, week_streak=weeks, best_week_streak=best, days_this_week=this_week,
            points=sum(s.points for s in sessions),
            total_reps=sum(s.reps for s in sessions),
            total_volume_kg=round(sum((s.weight_kg or 0) * s.reps for s in sessions), 1),
            week_volume_kg=round(sum((s.weight_kg or 0) * s.reps for s in week), 1),
            week_reps=sum(s.reps for s in week),
            muscles_active=active, muscles_total=total,
            muscles_pct=round(100 * active / total) if total else 0,
        ))
    weekly = period == "week"
    keys = {
        "week_streak": lambda r: (r["week_streak"], r["days_this_week"], r["total_reps"]),
        "week": lambda r: (r["days_this_week"], r["week_streak"], r["total_reps"]),
        "muscles": lambda r: (r["muscles_active"], r["week_volume_kg"]),
        "volume": lambda r: (r["week_volume_kg"] if weekly else r["total_volume_kg"], r["total_reps"]),
        "reps": lambda r: (r["week_reps"] if weekly else r["total_reps"], r["week_streak"]),
    }
    rows.sort(key=keys.get(by, keys["week_streak"]), reverse=True)
    out: list[LeaderboardEntry] = []
    for rank, r in enumerate(rows, start=1):
        u = r.pop("user")
        is_me = u.id == me_id
        if rank > limit and not is_me:
            continue
        out.append(LeaderboardEntry(rank=rank, display_name=u.display_name, is_me=is_me,
                                    week_goal_days=WEEK_GOAL_DAYS, **r))
    return out

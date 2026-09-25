"""Seed the unified database with demo users + sessions so the leaderboard and
dashboard have data immediately. Safe to re-run: it skips users that exist.

Run (from backend/):  python seed.py
"""
import random
from datetime import datetime, timedelta

from app.auth import hash_password
from app.database import Base, SessionLocal, engine
from app.models import User, WorkoutSession

Base.metadata.create_all(bind=engine)

DEMO_USERS = [
    ("sasha@gympath.test", "Sasha Watson", "password123"),
    ("sarah@gympath.test", "Sarah Lee", "password123"),
    ("alex@gympath.test", "Alex Kim", "password123"),
    ("demo@gympath.test", "Demo User", "password123"),
]

WORKOUTS = ["Pull-Up", "Squats", "Barbell Bench Press", "Deadlift", "Full Body"]
GRADES = ["S", "A", "B", "C"]


def seed():
    db = SessionLocal()
    created = 0
    try:
        for email, name, pw in DEMO_USERS:
            if db.query(User).filter(User.email == email).first():
                continue
            user = User(email=email, display_name=name, password_hash=hash_password(pw))
            db.add(user)
            db.flush()  # get user.id

            # 8–20 sessions over the last ~14 days
            n = random.randint(8, 20)
            for _ in range(n):
                days_ago = random.randint(0, 13)
                ts = datetime.now() - timedelta(
                    days=days_ago, hours=random.randint(0, 10)
                )
                acc = round(random.uniform(82, 99), 1)
                db.add(WorkoutSession(
                    user_id=user.id,
                    workout_name=random.choice(WORKOUTS),
                    reps=random.randint(8, 40),
                    accuracy=acc,
                    performance=("S" if acc >= 97 else "A" if acc >= 92
                                 else "B" if acc >= 85 else "C"),
                    bonus=5 if acc >= 95 else 0,
                    duration_sec=random.randint(120, 900),
                    client_timestamp=ts,
                ))
            created += 1
        db.commit()
        print(f"Seeded {created} new demo user(s).")
        print("Login with any of:  demo@gympath.test / password123")
    finally:
        db.close()


if __name__ == "__main__":
    seed()

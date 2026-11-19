"""End-to-end API smoke test using FastAPI TestClient against a throwaway DB.

Run (from backend/):  python test_api.py
"""
import os
import tempfile

# point the app at a temp DB BEFORE importing it
_tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
_tmp.close()
os.environ["GYMPATH_DATABASE_URL"] = f"sqlite:///{_tmp.name.replace(chr(92), '/')}"
os.environ["GYMPATH_SECRET"] = "test-secret-not-for-prod-but-long-enough-32+bytes"

from fastapi.testclient import TestClient  # noqa: E402
from app.main import app  # noqa: E402

c = TestClient(app)


def main():
    # health
    r = c.get("/health")
    assert r.status_code == 200 and r.json()["status"] == "ok", r.text
    print("health OK")

    # register
    r = c.post("/auth/register", json={
        "email": "Tuvshin@Test.com", "password": "secret123",
        "display_name": "Tuvshin"})
    assert r.status_code == 201, r.text
    tok = r.json()["access_token"]
    assert r.json()["user"]["email"] == "tuvshin@test.com"  # normalized lower
    print("register OK")

    # duplicate register → 409
    r = c.post("/auth/register", json={
        "email": "tuvshin@test.com", "password": "secret123",
        "display_name": "Dup"})
    assert r.status_code == 409, r.text
    print("duplicate register rejected OK")

    # login wrong password → 401
    r = c.post("/auth/login", json={"email": "tuvshin@test.com", "password": "nope"})
    assert r.status_code == 401, r.text
    print("bad login rejected OK")

    # login correct (case-insensitive email)
    r = c.post("/auth/login", json={"email": "TUVSHIN@test.com", "password": "secret123"})
    assert r.status_code == 200, r.text
    tok = r.json()["access_token"]
    print("login OK")

    h = {"Authorization": f"Bearer {tok}"}

    # unauthorized access
    assert c.get("/stats").status_code in (401, 403)
    assert c.get("/sessions", headers={"Authorization": "Bearer garbage"}).status_code == 401
    print("auth guard OK")

    # me
    r = c.get("/auth/me", headers=h)
    assert r.status_code == 200 and r.json()["display_name"] == "Tuvshin", r.text
    print("me OK")

    # create one session
    r = c.post("/sessions", headers=h, json={
        "workout_name": "Pull-Up", "reps": 12, "accuracy": 96.0,
        "performance": "S", "bonus": 5, "duration_sec": 180,
        "client_timestamp": "2026-06-12T08:00:00"})
    assert r.status_code == 201, r.text
    print("create session OK")

    # bulk upload (offline sync)
    r = c.post("/sessions/bulk", headers=h, json={"sessions": [
        {"workout_name": "Squats", "reps": 20, "accuracy": 90, "performance": "A",
         "bonus": 0, "duration_sec": 300, "client_timestamp": "2026-06-11T09:00:00"},
        {"workout_name": "Deadlift", "reps": 15, "accuracy": 88, "performance": "B",
         "bonus": 0, "duration_sec": 240, "client_timestamp": "2026-06-10T09:00:00"},
    ]})
    assert r.status_code == 201 and len(r.json()) == 2, r.text
    print("bulk sync OK")

    # list
    r = c.get("/sessions", headers=h)
    assert r.status_code == 200 and len(r.json()) == 3, r.text
    # newest first
    assert r.json()[0]["workout_name"] == "Pull-Up", r.text
    print("list sessions OK (ordered)")

    # stats
    r = c.get("/stats", headers=h)
    s = r.json()
    assert s["total_sessions"] == 3, s
    assert s["total_reps"] == 47, s            # 12+20+15
    assert s["total_points"] == 52, s          # 47 + 5 bonus
    assert s["daily_rep_goal"] == 60, s
    print(f"stats OK (streak={s['streak_days']}, points={s['total_points']})")

    # leaderboard (just me here)
    r = c.get("/leaderboard", headers=h)
    lb = r.json()
    assert lb[0]["is_me"] is True and lb[0]["rank"] == 1, lb
    print("leaderboard OK")

    # week streak: 3+ training days a week, Monday to Sunday
    from datetime import date, datetime, timedelta
    from app.services import week_streak
    mon = date(2026, 11, 16)
    def days(*offsets):
        return {mon + timedelta(days=o) for o in offsets}
    # last week 3 days, the week before 3 days, this week 1 day so far
    assert week_streak(days(-14, -12, -10, -7, -5, -3, 1), mon + timedelta(days=3)) == (2, 2, 1)
    # this week reaches the goal: it counts already
    assert week_streak(days(-7, -5, -3, 0, 1, 2), mon + timedelta(days=3)) == (2, 2, 3)
    # a gap week breaks it; the best run is remembered
    assert week_streak(days(-28, -27, -26, -21, -20, -19, -7, -6, -5), mon) == (1, 2, 0)
    assert week_streak(set(), mon) == (0, 0, 0)
    print("week streak OK")

    # syncing the same sets again stores them once (client_id)
    today = date.today()
    monday = today - timedelta(days=today.weekday())
    sync = {"sessions": [
        {"workout_name": "Lat Pulldown", "reps": 10, "weight_kg": 40,
         "client_id": f"set-{i}",
         "client_timestamp": datetime.combine(monday - timedelta(days=7 - i), datetime.min.time()).isoformat()}
        for i in range(3)
    ]}
    r = c.post("/sessions/bulk", headers=h, json=sync)
    assert r.status_code == 201 and len(r.json()) == 3, r.text
    r = c.post("/sessions/bulk", headers=h, json=sync)
    assert r.status_code == 201 and len(r.json()) == 0, r.text
    assert len(c.get("/sessions", headers=h).json()) == 6
    s = c.get("/stats", headers=h).json()
    assert s["week_streak"] == 1 and s["week_goal_days"] == 3, s
    print("idempotent sync + week streak in stats OK")

    # a second user with a longer streak ranks first by streak, me first by reps
    r = c.post("/auth/register", json={
        "email": "bat@test.com", "password": "secret123", "display_name": "Bat"})
    h2 = {"Authorization": f"Bearer {r.json()['access_token']}"}
    c.post("/sessions/bulk", headers=h2, json={"sessions": [
        {"workout_name": "Face Pull", "reps": 5,
         "client_timestamp": datetime.combine(monday - timedelta(weeks=w) + timedelta(days=d), datetime.min.time()).isoformat()}
        for w in (1, 2) for d in (0, 1, 2)]})
    lb = c.get("/leaderboard", headers=h).json()
    assert lb[0]["display_name"] == "Bat" and lb[0]["week_streak"] == 2, lb
    assert lb[1]["is_me"] and lb[1]["rank"] == 2, lb
    lb = c.get("/leaderboard?by=reps", headers=h).json()
    assert lb[0]["is_me"], lb
    assert c.get("/leaderboard?by=nope", headers=h).status_code == 422
    print("leaderboard by week streak / reps OK")

    print("\nALL BACKEND TESTS PASSED")


if __name__ == "__main__":
    try:
        main()
    finally:
        try:
            os.unlink(_tmp.name)
        except OSError:
            pass

# Gympath Backend (test server)

FastAPI + SQLite unified user/workout database for the Gympath wearable app.
Designed to run on the developer's PC and serve ~50 users on the local network.

## Run

```bat
:: from backend/  (or just double-click run_server.bat)
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

- Interactive API docs: http://localhost:8000/docs
- The phone (same Wi-Fi) reaches it at `http://<your-PC-IP>:8000`
  (find the IP with `ipconfig`; the `/` endpoint also prints a `lan_hint`).

Seed demo users + sessions (optional, for an immediate leaderboard):

```bat
python seed.py
:: login: demo@gympath.test / password123
```

## Stack

| Piece | Choice | Why |
|---|---|---|
| Framework | FastAPI + Uvicorn | async, auto OpenAPI docs, minimal |
| DB | SQLite (WAL) via SQLAlchemy ORM | zero-install, fine for ~50 users; swap `GYMPATH_DATABASE_URL` to Postgres later with no code change |
| Auth | JWT (HS256) + bcrypt | email/password, 14-day tokens |

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/auth/register` | – | create user → returns token |
| POST | `/auth/login` | – | login → returns token |
| GET  | `/auth/me` | ✓ | current user |
| POST | `/sessions` | ✓ | save one workout session |
| POST | `/sessions/bulk` | ✓ | sync many local sessions at once |
| GET  | `/sessions` | ✓ | list my sessions |
| GET  | `/stats` | ✓ | my aggregated stats (mirrors app `WorkoutStats`) |
| GET  | `/leaderboard?by=week_streak\|week\|reps` | ✓ | ranked by week streak (weeks in a row with ≥ 3 training days, `WEEK_GOAL_DAYS`), by training days this week, or by total reps; the caller is always included |
| GET  | `/health` | – | liveness |

## Config (env vars, all optional)

- `GYMPATH_SECRET` — JWT secret (else auto-generated + persisted to `.secret`)
- `GYMPATH_DATABASE_URL` — SQLAlchemy URL (default local SQLite)

## Schema

`users` 1─∞ `workout_sessions`, `users` 1─∞ `devices`.
`workout_sessions` columns mirror the mobile `WorkoutSession` model 1:1, so the
app's local `WorkoutStore` syncs straight into rows via `/sessions/bulk`.

## App sync

The app (Leaderboard screen) signs in with the server address shown at `/`
(`lan_hint`), then posts its real (not simulated) sets to `/sessions/bulk`
with a `client_id` per set, so resending is safe: sets already stored are
skipped. Times are the phone's local time. Older databases get the new
columns (`weight_kg`, `client_id`) added at start-up.

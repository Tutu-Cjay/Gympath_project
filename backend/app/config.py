"""Runtime settings. Test-server friendly: a stable JWT secret is generated
once and persisted to backend/.secret so tokens survive restarts."""
import os
import secrets
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent  # backend/

# --- JWT secret (persisted so restarting the server doesn't log everyone out)
_secret_file = BASE_DIR / ".secret"


def _load_secret() -> str:
    env = os.environ.get("GYMPATH_SECRET")
    if env:
        return env
    if _secret_file.exists():
        return _secret_file.read_text(encoding="utf-8").strip()
    s = secrets.token_urlsafe(48)
    _secret_file.write_text(s, encoding="utf-8")
    return s


SECRET_KEY = _load_secret()
JWT_ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 60 * 24 * 14  # 14 days — convenient for a test app

# SQLite by default; swap DATABASE_URL to a Postgres URL later with no code change.
DATABASE_URL = os.environ.get(
    "GYMPATH_DATABASE_URL", f"sqlite:///{(BASE_DIR / 'gympath.db').as_posix()}"
)

# Daily rep goal mirrored from the mobile app (WorkoutStore.dailyRepGoal)
DAILY_REP_GOAL = 60

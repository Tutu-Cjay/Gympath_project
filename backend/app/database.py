"""SQLAlchemy engine + session. SQLite is put in WAL mode so the ~50-user
test load (many reads, occasional writes) doesn't block on the single writer."""
from sqlalchemy import create_engine, event
from sqlalchemy.orm import declarative_base, sessionmaker

from .config import DATABASE_URL

_is_sqlite = DATABASE_URL.startswith("sqlite")

engine = create_engine(
    DATABASE_URL,
    # SQLite + threads (uvicorn) needs this; harmless/ignored for Postgres
    connect_args={"check_same_thread": False} if _is_sqlite else {},
    pool_pre_ping=True,
)

if _is_sqlite:

    @event.listens_for(engine, "connect")
    def _sqlite_pragmas(dbapi_conn, _record):
        cur = dbapi_conn.cursor()
        cur.execute("PRAGMA journal_mode=WAL")
        cur.execute("PRAGMA synchronous=NORMAL")
        cur.execute("PRAGMA foreign_keys=ON")
        cur.execute("PRAGMA busy_timeout=5000")
        cur.close()


SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


def upgrade_schema():
    """Add columns that newer versions added to tables an older server
    created (create_all only makes missing tables)."""
    from sqlalchemy import inspect, text

    added = {
        "workout_sessions": {
            "weight_kg": "FLOAT DEFAULT 0",
            "client_id": "VARCHAR(80)",
        },
    }
    insp = inspect(engine)
    with engine.begin() as conn:
        for table, cols in added.items():
            if not insp.has_table(table):
                continue
            have = {c["name"] for c in insp.get_columns(table)}
            for name, ddl in cols.items():
                if name not in have:
                    conn.execute(text(f"ALTER TABLE {table} ADD COLUMN {name} {ddl}"))


def get_db():
    """FastAPI dependency — one DB session per request."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

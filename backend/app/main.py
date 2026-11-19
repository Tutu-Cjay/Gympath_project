"""Gympath FastAPI app — entrypoint.

Run (from backend/):  python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
or just double-click run_server.bat. Interactive docs at /docs."""
import socket

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from . import __version__
from .database import Base, engine, upgrade_schema
from .routers import auth as auth_router
from .routers import sessions as sessions_router
from .routers import stats as stats_router

# create tables on first run (idempotent). For schema changes later, use Alembic.
Base.metadata.create_all(bind=engine)
upgrade_schema()

app = FastAPI(
    title="Gympath API",
    version=__version__,
    description="Unified user + workout database for the Gympath wearable.",
)

# The Flutter app connects from a phone on the same LAN; allow any origin for
# the test server. Tighten this before any public deployment.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth_router.router)
app.include_router(sessions_router.router)
app.include_router(stats_router.router)


@app.get("/health", tags=["meta"])
def health():
    return {"status": "ok", "version": __version__}


@app.get("/", tags=["meta"])
def root():
    # show the LAN address so the phone knows where to point
    try:
        host_ip = socket.gethostbyname(socket.gethostname())
    except OSError:
        host_ip = "127.0.0.1"
    return {
        "name": "Gympath API",
        "version": __version__,
        "docs": "/docs",
        "lan_hint": f"http://{host_ip}:8000",
    }

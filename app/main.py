import io
import os
import secrets
import socket
import string
from contextlib import asynccontextmanager
from pathlib import Path

import qrcode
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from prometheus_fastapi_instrumentator import Instrumentator
from psycopg_pool import ConnectionPool
from pydantic import BaseModel, HttpUrl

DATABASE_URL = os.environ["DATABASE_URL"]
BASE_URL = os.getenv("BASE_URL", "")  # optional, for example https://snip.example.com
ALPHABET = string.ascii_letters + string.digits
INDEX_HTML = Path(__file__).with_name("index.html").read_text(encoding="utf-8")

pool = ConnectionPool(DATABASE_URL, min_size=1, max_size=5, open=False)


@asynccontextmanager
async def lifespan(app: FastAPI):
    pool.open(wait=True, timeout=60)
    with pool.connection() as conn:
        conn.execute(
            """CREATE TABLE IF NOT EXISTS links (
                   code       VARCHAR(10) PRIMARY KEY,
                   url        TEXT NOT NULL,
                   clicks     INTEGER NOT NULL DEFAULT 0,
                   created_at TIMESTAMPTZ NOT NULL DEFAULT now())"""
        )
    yield
    pool.close()


app = FastAPI(title="Snip", lifespan=lifespan)
Instrumentator().instrument(app).expose(app)  # adds /metrics


class ShortenRequest(BaseModel):
    url: HttpUrl


def base_url(request: Request) -> str:
    return BASE_URL or str(request.base_url).rstrip("/")


@app.get("/", response_class=HTMLResponse, include_in_schema=False)  # the web page
def index():
    return INDEX_HTML


@app.get("/healthz")  # liveness: the process is alive
def healthz():
    return {"status": "alive"}


@app.get("/ready")  # readiness: the database is reachable
def ready():
    with pool.connection() as conn:
        conn.execute("SELECT 1")
    return {"status": "ready"}


@app.get("/whoami")
def whoami():
    return {"pod": socket.gethostname()}


@app.post("/shorten", status_code=201)
def shorten(body: ShortenRequest, request: Request):
    for _ in range(5):
        code = "".join(secrets.choice(ALPHABET) for _ in range(6))
        with pool.connection() as conn:
            cur = conn.execute(
                "INSERT INTO links (code, url) VALUES (%s, %s) ON CONFLICT (code) DO NOTHING",
                (code, str(body.url)),
            )
            if cur.rowcount == 1:
                return {"code": code, "short_url": f"{base_url(request)}/{code}"}
    raise HTTPException(500, "Could not generate a unique code")


@app.get("/{code}/qr")  # CPU-heavy on purpose: drives autoscaling
def qr(code: str, request: Request, size: int = 10):
    size = max(1, min(size, 40))
    with pool.connection() as conn:
        found = conn.execute("SELECT 1 FROM links WHERE code = %s", (code,)).fetchone()
    if not found:
        raise HTTPException(404, "Not found")
    img = qrcode.make(f"{base_url(request)}/{code}", box_size=size)
    buf = io.BytesIO()
    img.save(buf)
    return Response(buf.getvalue(), media_type="image/png")


@app.get("/{code}")  # keep this route last: it matches any path
def follow(code: str):
    with pool.connection() as conn:
        row = conn.execute(
            "UPDATE links SET clicks = clicks + 1 WHERE code = %s RETURNING url", (code,)
        ).fetchone()
    if not row:
        raise HTTPException(404, "Not found")
    return RedirectResponse(row[0], status_code=307)

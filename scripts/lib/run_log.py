"""Append-only run log for accountability.

Every pipeline step writes one row here: what ran, when, against which
raw files (by content hash, so a silently-swapped data file is
detectable), and with what result. This table is never rebuilt with
CREATE OR REPLACE, since it accumulates across runs on purpose, unlike the
data tables, which must be bit-for-bit identical every rerun.
"""

import hashlib
import json
from pathlib import Path

import duckdb

_TABLE = "_meta.run_log"


def ensure_schema(con: duckdb.DuckDBPyConnection) -> None:
    con.execute("CREATE SCHEMA IF NOT EXISTS _meta")
    con.execute(f"""
        CREATE TABLE IF NOT EXISTS {_TABLE} (
            run_id      BIGINT,
            step        VARCHAR,
            status      VARCHAR,      -- 'OK' | 'FAILED'
            started_at  TIMESTAMP,
            finished_at TIMESTAMP,
            details     JSON
        )
    """)
    con.execute(f"""
        CREATE SEQUENCE IF NOT EXISTS _meta.run_log_seq START 1
    """)


def file_sha256(path: Path, chunk_size: int = 1 << 20) -> str:
    """Content hash of a raw file, used to prove *which* data a run profiled."""
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(chunk_size), b""):
            h.update(chunk)
    return h.hexdigest()[:16]  # short hash is enough to detect drift


def log_step(
    con: duckdb.DuckDBPyConnection,
    step: str,
    status: str,
    started_at,
    finished_at,
    details: dict,
) -> None:
    ensure_schema(con)
    con.execute(
        f"""
        INSERT INTO {_TABLE}
        SELECT nextval('_meta.run_log_seq'), ?, ?, ?, ?, ?
        """,
        [step, status, started_at, finished_at, json.dumps(details, default=str)],
    )


def recent(con: duckdb.DuckDBPyConnection, limit: int = 20):
    ensure_schema(con)
    return con.execute(
        f"SELECT * FROM {_TABLE} ORDER BY run_id DESC LIMIT ?", [limit]
    ).fetchdf()

"""Central path definitions, anchored to the project root.

Anchoring on this file's location (not cwd) is what lets every script
run identically whether invoked as `uv run python scripts/01_profile_data.py`
from the project root, from inside scripts/, or from an orchestrator
importing these as a library.
"""

from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]

RAW_DIR = PROJECT_ROOT / "data" / "raw_data"
DB_PATH = PROJECT_ROOT / "db" / "kirana.duckdb"
EVIDENCE_DIR = PROJECT_ROOT / "evidence"

DB_PATH.parent.mkdir(parents=True, exist_ok=True)
EVIDENCE_DIR.mkdir(parents=True, exist_ok=True)

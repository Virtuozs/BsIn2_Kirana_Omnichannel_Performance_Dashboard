#!/usr/bin/env bash
# Copies the DuckDB community driver jar into the metabase container's
# /plugins (a named Docker volume) and restarts it so Metabase picks it up.
#
# Why not just bind-mount tools/metabase/plugins straight to /plugins?
# On WSL2 + Docker Desktop, Metabase's own writability probe for the plugins
# directory (Java File.canWrite()) can misreport on a host bind mount even
# though raw reads/writes work fine — Metabase then silently falls back to a
# throwaway /tmp plugins dir and the DuckDB driver never loads. A named
# volume avoids that translation layer entirely.
#
# Usage: ./tools/metabase/load_driver.sh [docker-compose-invocation]
# Example on Windows+WSL2 where `docker` isn't on PATH inside the distro:
#   ./tools/metabase/load_driver.sh "/mnt/c/Program Files/Docker/Docker/resources/bin/docker.exe"

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."  # -> BsIn_UAS/

DOCKER_BIN="${1:-docker}"
JAR="tools/metabase/plugins/duckdb.metabase-driver.jar"

if [ ! -f "$JAR" ]; then
    echo "Missing $JAR — download it first:"
    echo "  curl -L -o $JAR https://github.com/motherduckdb/metabase_duckdb_driver/releases/download/1.5.6.0/duckdb.metabase-driver.jar"
    exit 1
fi

"$DOCKER_BIN" compose up -d metabase
"$DOCKER_BIN" compose cp "$JAR" metabase:/plugins/duckdb.metabase-driver.jar
"$DOCKER_BIN" compose restart metabase

echo "Waiting for Metabase to become healthy..."
until "$DOCKER_BIN" exec kirana-metabase curl -sf http://localhost:3000/api/health >/dev/null 2>&1; do
    sleep 3
done
echo "Metabase healthy. Checking driver load..."
"$DOCKER_BIN" logs kirana-metabase 2>&1 | grep -i duckdb || echo "WARNING: no 'duckdb' lines in logs — driver may not have loaded, check manually."

import subprocess
import sys
import time
from pathlib import Path
from db import get_connection

BASE_DIR = Path(__file__).resolve().parent
SQL_DIR = BASE_DIR / "sql"
INGEST_SCRIPT = BASE_DIR / "binance_ingest.py"


def run_ingestion():
    print("[STEP 1] Running binance_ingest.py...")
    subprocess.run([sys.executable, str(INGEST_SCRIPT)], check=True)
    print("[OK] Staging ingestion complete.")


def run_sql_file(conn, sql_path: Path):
    sql_text = sql_path.read_text(encoding="utf-8")
    with conn.cursor() as cur:
        cur.execute(sql_text)
    conn.commit()
    print(f"[OK] Executed {sql_path.name}")


def run_dq_checks(conn, dq_path: Path):
    queries = [
        q.strip()
        for q in dq_path.read_text(encoding="utf-8").split(";")
        if q.strip()
    ]
    with conn.cursor() as cur:
        for idx, query in enumerate(queries, start=1):
            cur.execute(query)
            rows = cur.fetchall()
            if idx == 1:
                print(f"[DQ #1 Row Counts] {rows}")
            elif rows:
                raise RuntimeError(f"DQ check #{idx} failed with rows: {rows}")
    print(f"[OK] All {len(queries)} DQ checks passed.")

def run_cycle(include_ingest: bool = False):
    if include_ingest:
        run_ingestion()

    conn = get_connection()
    try:
        run_sql_file(conn, SQL_DIR / "transform.sql")
        run_dq_checks(conn, SQL_DIR / "dq_checks.sql")
        run_sql_file(conn, SQL_DIR / "refresh_reports.sql")
        print("[DONE] Pipeline cycle finished.\n")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def run_loop(interval_seconds: int = 60, include_ingest: bool = False):
    print(f"Running pipeline every {interval_seconds}s (Ctrl+C to stop)...\n")
    while True:
        try:
            run_cycle(include_ingest=include_ingest)
        except Exception as exc:
            print(f"[ERROR] Cycle failed: {exc}\n")
        time.sleep(interval_seconds)


if __name__ == "__main__":
    # Single test run first (set include_ingest=True if you want ingestion in each cycle)
    run_loop(interval_seconds=60, include_ingest=True)

    # Once verified, uncomment to run on a loop:
    # run_loop(interval_seconds=60, include_ingest=True)
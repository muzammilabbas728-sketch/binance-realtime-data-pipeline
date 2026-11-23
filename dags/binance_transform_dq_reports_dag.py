from datetime import datetime, timedelta
from pathlib import Path
import sys
from airflow import DAG
from airflow.operators.python import PythonOperator

PROJECT_DIR = Path("/opt/project")
if str(PROJECT_DIR) not in sys.path:
    sys.path.insert(0, str(PROJECT_DIR))

from db import get_connection  # noqa: E402


def _run_sql_file(filename: str):
    sql_path = PROJECT_DIR / "sql" / filename
    sql_text = sql_path.read_text(encoding="utf-8")
    conn = get_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(sql_text)
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _run_dq_checks():
    dq_path = PROJECT_DIR / "sql" / "dq_checks.sql"
    queries = [
        q.strip()
        for q in dq_path.read_text(encoding="utf-8").split(";")
        if q.strip()
    ]
    conn = get_connection()
    try:
        with conn.cursor() as cur:
            for idx, query in enumerate(queries, start=1):
                cur.execute(query)
                rows = cur.fetchall()
                if idx == 1:
                    print(f"[DQ #1 Row Counts] {rows}")
                elif rows:
                    raise RuntimeError(f"DQ check #{idx} failed with rows: {rows}")
    finally:
        conn.close()


default_args = {
    "owner": "data-eng",
    "retries": 1,
    "retry_delay": timedelta(seconds=30),
}

with DAG(
    dag_id="binance_transform_dq_reports_dag",
    default_args=default_args,
    description="Transform staging to main, run DQ checks, and refresh reporting tables",
    start_date=datetime(2026, 11, 23),
    schedule=None,  # Triggered after ingest or set e.g. "*/2 * * * *" / "*/5 * * * *"
    max_active_runs=1,
    catchup=False,
    tags=["binance", "transform", "dq", "reports"],
) as dag:
    transform = PythonOperator(
        task_id="run_transform_sql",
        python_callable=_run_sql_file,
        op_kwargs={"filename": "transform.sql"},
    )

    dq_checks = PythonOperator(
        task_id="run_dq_checks_sql",
        python_callable=_run_dq_checks,
    )

    refresh_reports = PythonOperator(
        task_id="run_refresh_reports_sql",
        python_callable=_run_sql_file,
        op_kwargs={"filename": "refresh_reports.sql"},
    )

    transform >> dq_checks >> refresh_reports
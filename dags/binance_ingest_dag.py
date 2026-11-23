from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.bash import BashOperator

PROJECT_DIR = "/opt/project"

default_args = {
    "owner": "data-eng",
    "retries": 1,
    "retry_delay": timedelta(seconds=30),
}

with DAG(
    dag_id="binance_ingest_dag",
    default_args=default_args,
    description="Ingest Binance ticker, 1m klines, aggTrades, and bookTicker every 2 minutes",
    start_date=datetime(2026, 11, 23),
    schedule="*/2 * * * *",
    max_active_runs=1,
    catchup=False,
    tags=["binance", "ingest"],
) as dag:
    ingest_task = BashOperator(
        task_id="run_binance_ingest",
        bash_command=f"cd {PROJECT_DIR} && python binance_ingest.py",
    )
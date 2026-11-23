import psycopg2
import os

# Database connection configuration for PostgreSQL staging database
DB_CONFIG = {
    "dbname": os.getenv("DB_NAME", "staging"),
    "user": os.getenv("DB_USER", "postgres"),
    "password": os.getenv("DB_PASSWORD", "HUNZA728"),
    "host": os.getenv("DB_HOST", "host.docker.internal"),
    "port": os.getenv("DB_PORT", "5432"),
}

def get_connection():
    """Establish and return a connection to the PostgreSQL staging database."""
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        return conn
    except Exception as e:
        print(f"Error connecting to the database: {e}")
        raise e
import os
import csv
from datetime import datetime
from fastapi import FastAPI
import psycopg2
from psycopg2.extras import RealDictCursor

DB_HOST = os.getenv("DB_HOST", "postgres")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "appdb")
DB_USER = os.getenv("DB_USER", "appuser")
DB_PASSWORD = os.getenv("DB_PASSWORD", "apppassword")

DATA_PATH = os.getenv("DATA_PATH", "/app/data/raw/fridge_sales_with_rating.csv")

app = FastAPI(title="Fridge Sales Stats API")

def get_conn():
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=DB_USER, password=DB_PASSWORD
    )

def init_schema_and_seed():
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS fridge_sales (
                    id TEXT PRIMARY KEY,
                    customer_id TEXT NOT NULL,
                    fridge_model TEXT NOT NULL,
                    brand TEXT NOT NULL,
                    capacity_liters INTEGER NOT NULL,
                    price NUMERIC(12,2) NOT NULL,
                    sales_date DATE NOT NULL,
                    store_name TEXT NOT NULL,
                    store_address TEXT NOT NULL,
                    customer_feedback TEXT NOT NULL,
                    feedback_rating INTEGER NOT NULL,
                    feedback_sentiment_category TEXT NOT NULL
                );
                """
            )

            cur.execute("SELECT COUNT(*) FROM fridge_sales;")
            if cur.fetchone()[0] > 0:
                return

            if not os.path.exists(DATA_PATH):
                raise RuntimeError(f"CSV not found at {DATA_PATH}")

            with open(DATA_PATH, "r", encoding="utf-8") as f:
                reader = csv.DictReader(f)
                rows = []
                for r in reader:
                    rows.append((
                        r["ID"],
                        r["CUSTOMER_ID"],
                        r["FRIDGE_MODEL"],
                        r["BRAND"],
                        int(r["CAPACITY_LITERS"]),
                        float(r["PRICE"]),
                        datetime.strptime(r["SALES_DATE"], "%Y-%m-%d").date(),
                        r["STORE_NAME"],
                        r["STORE_ADDRESS"],
                        r["CUSTOMER_FEEDBACK"],
                        int(r["FEEDBACK_RATING"]),
                        r["FEEDBACK_SENTIMENT_CATEGORY"],
                    ))

            cur.executemany(
                """
                INSERT INTO fridge_sales(
                    id, customer_id, fridge_model, brand, capacity_liters, price, sales_date,
                    store_name, store_address, customer_feedback, feedback_rating, feedback_sentiment_category
                )
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s);
                """,
                rows
            )
        conn.commit()

@app.on_event("startup")
def startup():
    init_schema_and_seed()

@app.get("/healthz")
@app.get("/api/healthz")
def healthz():
    return {"ok": True}

def compute_stats():
    with get_conn() as conn:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                """
                SELECT
                    COUNT(*)::bigint AS row_count,
                    MIN(price)::numeric AS min_price,
                    MAX(price)::numeric AS max_price,
                    ROUND(AVG(price)::numeric, 2) AS avg_price,
                    MIN(feedback_rating)::int AS min_rating,
                    MAX(feedback_rating)::int AS max_rating,
                    ROUND(AVG(feedback_rating)::numeric, 2) AS avg_rating
                FROM fridge_sales;
                """
            )
            base = cur.fetchone()

            cur.execute(
                """
                SELECT feedback_sentiment_category AS sentiment, COUNT(*)::bigint AS count
                FROM fridge_sales
                GROUP BY feedback_sentiment_category
                ORDER BY count DESC, sentiment ASC;
                """
            )
            sentiments = cur.fetchall()

            cur.execute(
                """
                SELECT brand, COUNT(*)::bigint AS count
                FROM fridge_sales
                GROUP BY brand
                ORDER BY count DESC, brand ASC
                LIMIT 5;
                """
            )
            top_brands = cur.fetchall()

            cur.execute(
                """
                SELECT store_name, COUNT(*)::bigint AS count
                FROM fridge_sales
                GROUP BY store_name
                ORDER BY count DESC, store_name ASC
                LIMIT 5;
                """
            )
            top_stores = cur.fetchall()

    return {**base, "sentiments": sentiments, "top_brands": top_brands, "top_stores": top_stores}

@app.get("/stats")
@app.get("/api/stats")
def stats():
    return compute_stats()

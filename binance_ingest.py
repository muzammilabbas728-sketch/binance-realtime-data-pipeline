import sys
import logging
import os
import time
import uuid
from datetime import datetime, timezone
import requests
from psycopg2.extras import execute_values
from db import get_connection

os.makedirs("logs", exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.FileHandler("logs/binance_ingest.log", encoding="utf-8"),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger("binance_ingest")

# Binance public API base URLs
BASE_URL = "https://api.binance.com"
FALLBACK_BASE_URL = "https://data-api.binance.vision"
active_base_url = BASE_URL

SYMBOLS = [
    "BTCUSDT",
    "ETHUSDT",
    "BNBUSDT",
    "SOLUSDT",
    "XRPUSDT",
    "ADAUSDT",
    "DOGEUSDT",
    "AVAXUSDT",
    "DOTUSDT",
    "LINKUSDT",
]

TRADE_SKIP_THRESHOLD_MS = 60 * 60 * 1000  # 60 minutes

# Reuse a single HTTP session with a standard browser-like User-Agent
session = requests.Session()
session.headers.update({"User-Agent": "Mozilla/5.0"})


def _parse_retry_after(resp, default_wait):
    """Return wait seconds from Retry-After header if numeric, else default_wait."""
    header = resp.headers.get("Retry-After")
    if header:
        try:
            seconds = float(header.strip())
            if seconds >= 0:
                return min(seconds, 60.0)
        except ValueError:
            pass
    return default_wait


def fetch_json(path_and_query, retries=3, timeout=30, backoff=2, base_url=None):
    """
    Fetch JSON from Binance with targeted retries:
    - Never retry 400 (bad request) or 418 (IP ban).
    - Retry timeouts, 429 (rate limit), and 5xx errors, honoring Retry-After.
    - If primary/active host returns 451, switch to FALLBACK_BASE_URL stickily.
    """
    global active_base_url
    if base_url is not None:
        active_base_url = base_url

    for attempt in range(1, retries + 1):
        current_host = active_base_url
        url = f"{current_host}{path_and_query}"
        try:
            resp = session.get(url, timeout=timeout)
            status = resp.status_code

            if status == 451 and FALLBACK_BASE_URL and current_host != FALLBACK_BASE_URL:
                active_base_url = FALLBACK_BASE_URL
                logger.warning(
                    f"Got 451 from {current_host}; switching stickily to fallback host {active_base_url}."
                )
                continue

            if status in (400, 418):
                resp.raise_for_status()

            if status == 429 or (500 <= status < 600):
                if attempt == retries:
                    resp.raise_for_status()
                wait_time = _parse_retry_after(resp, backoff * attempt)
                logger.warning(
                    f"HTTP {status} on attempt {attempt}/{retries} for {url}; "
                    f"waiting {wait_time}s before retry..."
                )
                time.sleep(wait_time)
                continue

            resp.raise_for_status()
            return resp.json()

        except requests.exceptions.Timeout as exc:
            if attempt == retries:
                raise
            wait_time = backoff * attempt
            logger.warning(
                f"Timeout on attempt {attempt}/{retries} for {url} ({exc}); "
                f"retrying in {wait_time}s..."
            )
            time.sleep(wait_time)

        except requests.exceptions.HTTPError:
            raise

        except requests.exceptions.RequestException as exc:
            if attempt == retries:
                raise
            wait_time = backoff * attempt
            logger.warning(
                f"Request error on attempt {attempt}/{retries} for {url}: {exc}; "
                f"retrying in {wait_time}s..."
            )
            time.sleep(wait_time)


def get_last_open_time(cursor, symbol):
    """Return the latest stored open_time (ms) for a symbol, or None if no rows exist."""
    cursor.execute(
        """
        SELECT MAX(open_time::BIGINT)
        FROM staging.klines_1m
        WHERE symbol = %s
          AND open_time IS NOT NULL
        """,
        (symbol,),
    )
    row = cursor.fetchone()
    return row[0] if row and row[0] is not None else None


def get_last_trade_id(cursor, symbol):
    """Return the latest stored agg_trade_id for a symbol, or None if no rows exist."""
    cursor.execute(
        """
        SELECT MAX(agg_trade_id::BIGINT)
        FROM staging.agg_trades
        WHERE symbol = %s
          AND agg_trade_id IS NOT NULL
        """,
        (symbol,),
    )
    row = cursor.fetchone()
    return row[0] if row and row[0] is not None else None


def to_str_or_none(val):
    """Convert non-None values to str; preserve None as SQL NULL."""
    return None if val is None else str(val)


def ingest_binance_data():
    batch_id = str(uuid.uuid4())
    now_dt = datetime.now(timezone.utc)
    ingested_at = now_dt.replace(tzinfo=None)
    now_ms = int(now_dt.timestamp() * 1000)

    conn = get_connection()
    cursor = conn.cursor()

    success_count = 0
    failed_symbols = []
    total_kline_rows = 0
    total_trade_rows = 0

    try:
        logger.info(f"Starting ingestion batch {batch_id} at {ingested_at.isoformat()}...")

        for symbol in SYMBOLS:
            logger.info(f"Processing {symbol}...")
            try:
                # 1. Ingest 24hr Ticker
                path_24hr = f"/api/v3/ticker/24hr?symbol={symbol}"
                res = fetch_json(path_24hr)
                source_24hr = f"{active_base_url}{path_24hr}"

                cursor.execute(
                    """
                    INSERT INTO staging.ticker_24hr (
                        symbol, price_change, price_change_percent, weighted_avg_price,
                        prev_close_price, last_price, last_qty, bid_price, bid_qty,
                        ask_price, ask_qty, open_price, high_price, low_price,
                        volume, quote_volume, open_time, close_time, first_id,
                        last_id, trade_count, ingested_at, batch_id, source_endpoint
                    ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                    """,
                    (
                        to_str_or_none(res.get("symbol")),
                        to_str_or_none(res.get("priceChange")),
                        to_str_or_none(res.get("priceChangePercent")),
                        to_str_or_none(res.get("weightedAvgPrice")),
                        to_str_or_none(res.get("prevClosePrice")),
                        to_str_or_none(res.get("lastPrice")),
                        to_str_or_none(res.get("lastQty")),
                        to_str_or_none(res.get("bidPrice")),
                        to_str_or_none(res.get("bidQty")),
                        to_str_or_none(res.get("askPrice")),
                        to_str_or_none(res.get("askQty")),
                        to_str_or_none(res.get("openPrice")),
                        to_str_or_none(res.get("highPrice")),
                        to_str_or_none(res.get("lowPrice")),
                        to_str_or_none(res.get("volume")),
                        to_str_or_none(res.get("quoteVolume")),
                        to_str_or_none(res.get("openTime")),
                        to_str_or_none(res.get("closeTime")),
                        to_str_or_none(res.get("firstId")),
                        to_str_or_none(res.get("lastId")),
                        to_str_or_none(res.get("count")),
                        ingested_at,
                        batch_id,
                        source_24hr,
                    ),
                )
                logger.info(f"[{symbol}] Ticker 24hr ingested (1 row).")

                # 2. Ingest 1-Minute Klines — 24h (2x1000) backfill on first run, incremental after
                last_open_time = get_last_open_time(cursor, symbol)
                collected_raw_klines = []

                if last_open_time is not None:
                    start_time = last_open_time + 60000
                    path_klines = (
                        f"/api/v3/klines?symbol={symbol}&interval=1m"
                        f"&startTime={start_time}&limit=1000"
                    )
                    raw_klines = fetch_json(path_klines)
                    source_klines = f"{active_base_url}{path_klines}"
                    collected_raw_klines = raw_klines or []
                else:
                    BACKFILL_PAGES = 2
                    cursor_start = now_ms - (24 * 60 * 60 * 1000)
                    source_klines = ""

                    for _ in range(BACKFILL_PAGES):
                        if cursor_start >= now_ms:
                            break
                        path_klines = (
                            f"/api/v3/klines?symbol={symbol}&interval=1m"
                            f"&startTime={cursor_start}&limit=1000"
                        )
                        raw_klines = fetch_json(path_klines)
                        source_klines = f"{active_base_url}{path_klines}"
                        if not raw_klines:
                            break

                        collected_raw_klines.extend(raw_klines)
                        if len(raw_klines) < 1000:
                            break

                        cursor_start = int(raw_klines[-1][0]) + 60000
                        time.sleep(0.2)

                seen_open_times = set()
                klines = []
                for k in collected_raw_klines:
                    open_ms = int(k[0])
                    close_ms = int(k[6])
                    if close_ms < now_ms and open_ms not in seen_open_times:
                        seen_open_times.add(open_ms)
                        klines.append(k)

                if klines:
                    kline_rows = [
                        (
                            to_str_or_none(symbol),
                            to_str_or_none(k[0]),
                            to_str_or_none(k[1]),
                            to_str_or_none(k[2]),
                            to_str_or_none(k[3]),
                            to_str_or_none(k[4]),
                            to_str_or_none(k[5]),
                            to_str_or_none(k[6]),
                            to_str_or_none(k[7]),
                            to_str_or_none(k[8]),
                            to_str_or_none(k[9]),
                            to_str_or_none(k[10]),
                            ingested_at,
                            batch_id,
                            source_klines,
                        )
                        for k in klines
                    ]
                    execute_values(
                        cursor,
                        """
                        INSERT INTO staging.klines_1m (
                            symbol, open_time, open, high, low, close, volume,
                            close_time, quote_volume, trades, taker_buy_base_vol,
                            taker_buy_quote_vol, ingested_at, batch_id, source_endpoint
                        ) VALUES %s
                        """,
                        kline_rows,
                    )
                total_kline_rows += len(klines)
                logger.info(f"[{symbol}] Klines 1m ingested ({len(klines)} closed rows).")

                # 3. Ingest Aggregate Trades — incremental with 60m skip-ahead & page cap
                MAX_TRADE_PAGES = 10
                last_trade_id = get_last_trade_id(cursor, symbol)
                from_id = last_trade_id + 1 if last_trade_id is not None else None
                symbol_trades_fetched = 0
                pages_fetched = 0

                while True:
                    if pages_fetched >= MAX_TRADE_PAGES:
                        logger.info(
                            f"[{symbol}] Reached page cap ({MAX_TRADE_PAGES} pages) for aggTrades; "
                            f"will continue on next run."
                        )
                        break

                    if from_id is not None:
                        path_trades = (
                            f"/api/v3/aggTrades?symbol={symbol}"
                            f"&fromId={from_id}&limit=1000"
                        )
                    else:
                        path_trades = (
                            f"/api/v3/aggTrades?symbol={symbol}&limit=1000"
                        )

                    trades = fetch_json(path_trades)
                    if not trades:
                        break

                    # If continuing from a stored ID on the first page and the oldest trade
                    # on the page is > 60 min old, discard it and jump to latest trades.
                    if pages_fetched == 0 and from_id is not None:
                        first_trade_ms = int(trades[0]["T"])
                        gap_ms = now_ms - first_trade_ms
                        if gap_ms > TRADE_SKIP_THRESHOLD_MS:
                            gap_minutes = gap_ms / 60000.0
                            logger.warning(
                                f"[{symbol}] aggTrades lag is {gap_minutes:.1f} min (> 60 min); "
                                f"skipping ahead to latest trades."
                            )
                            from_id = None
                            path_trades = f"/api/v3/aggTrades?symbol={symbol}&limit=1000"
                            trades = fetch_json(path_trades)
                            if not trades:
                                break

                    source_trades = f"{active_base_url}{path_trades}"
                    trade_rows = [
                        (
                            to_str_or_none(symbol),
                            to_str_or_none(t.get("a")),
                            to_str_or_none(t.get("p")),
                            to_str_or_none(t.get("q")),
                            to_str_or_none(t.get("f")),
                            to_str_or_none(t.get("l")),
                            to_str_or_none(t.get("T")),
                            to_str_or_none(t.get("m")),
                            ingested_at,
                            batch_id,
                            source_trades,
                        )
                        for t in trades
                    ]
                    execute_values(
                        cursor,
                        """
                        INSERT INTO staging.agg_trades (
                            symbol, agg_trade_id, price, quantity, first_trade_id,
                            last_trade_id, trade_time, is_buyer_maker, ingested_at,
                            batch_id, source_endpoint
                        ) VALUES %s
                        """,
                        trade_rows,
                    )

                    pages_fetched += 1
                    symbol_trades_fetched += len(trades)

                    if len(trades) < 1000:
                        break

                    from_id = int(trades[-1]["a"]) + 1
                    time.sleep(0.2)

                total_trade_rows += symbol_trades_fetched
                logger.info(f"[{symbol}] Aggregate trades ingested ({symbol_trades_fetched} rows).")

                # 4. Ingest Book Ticker (Order Book Quote)
                path_book = f"/api/v3/ticker/bookTicker?symbol={symbol}"
                book = fetch_json(path_book)
                source_book = f"{active_base_url}{path_book}"

                cursor.execute(
                    """
                    INSERT INTO staging.book_ticker (
                        symbol, bid_price, bid_qty, ask_price, ask_qty,
                        ingested_at, batch_id, source_endpoint
                    ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                    """,
                    (
                        to_str_or_none(book.get("symbol")),
                        to_str_or_none(book.get("bidPrice")),
                        to_str_or_none(book.get("bidQty")),
                        to_str_or_none(book.get("askPrice")),
                        to_str_or_none(book.get("askQty")),
                        ingested_at,
                        batch_id,
                        source_book,
                    ),
                )
                logger.info(f"[{symbol}] Book ticker ingested (1 row).")

                # Commit per symbol so completed pairs aren't lost if a later symbol fails
                conn.commit()
                success_count += 1
                logger.info(f"[{symbol}] Committed all endpoints.")

                time.sleep(0.3)

            except Exception as sym_err:
                conn.rollback()
                failed_symbols.append(symbol)
                logger.exception(f"[{symbol}] Failed during ingestion (rolled back symbol): {sym_err}")

        logger.info(
            f"Batch {batch_id} finished: {success_count}/{len(SYMBOLS)} symbols succeeded | "
            f"total_klines={total_kline_rows}, total_agg_trades={total_trade_rows}."
        )
        if failed_symbols:
            logger.error(f"Failed symbols in batch {batch_id}: {', '.join(failed_symbols)}")
            sys.exit(1)
    except Exception as e:
        conn.rollback()
        logger.exception(f"Critical error during ingestion batch {batch_id}: {e}")
    finally:
        cursor.close()
        conn.close()
        session.close()


if __name__ == "__main__":
    ingest_binance_data()
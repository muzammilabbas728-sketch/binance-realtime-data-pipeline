-- DQ #1: Main table row counts (logged by pipeline_runner.py)
SELECT 'dim_symbol' AS table_name, COUNT(*) AS row_count FROM main.dim_symbol
UNION ALL SELECT 'fact_candle_1m', COUNT(*) FROM main.fact_candle_1m
UNION ALL SELECT 'fact_trade', COUNT(*) FROM main.fact_trade
UNION ALL SELECT 'fact_quote', COUNT(*) FROM main.fact_quote
UNION ALL SELECT 'fact_ticker_snapshot', COUNT(*) FROM main.fact_ticker_snapshot;

-- DQ #2: Empty staging tables check
SELECT stg_table, row_cnt
FROM (
    SELECT 'klines_1m' AS stg_table, COUNT(*) AS row_cnt FROM staging.klines_1m
    UNION ALL SELECT 'agg_trades', COUNT(*) FROM staging.agg_trades
    UNION ALL SELECT 'ticker_24hr', COUNT(*) FROM staging.ticker_24hr
    UNION ALL SELECT 'book_ticker', COUNT(*) FROM staging.book_ticker
) AS checks
WHERE row_cnt = 0;

-- DQ #3: Duplicate grain checks across main facts + ticker_24hr batch duplicates
SELECT check_name, dup_groups
FROM (
    SELECT 'fact_candle_1m' AS check_name, COUNT(*) AS dup_groups
    FROM (
        SELECT symbol_id, open_time
        FROM main.fact_candle_1m
        GROUP BY symbol_id, open_time
        HAVING COUNT(*) > 1
    ) d1
    UNION ALL
    SELECT 'fact_trade', COUNT(*)
    FROM (
        SELECT symbol_id, agg_trade_id
        FROM main.fact_trade
        GROUP BY symbol_id, agg_trade_id
        HAVING COUNT(*) > 1
    ) d2
    UNION ALL
    SELECT 'fact_quote', COUNT(*)
    FROM (
        SELECT symbol_id, quote_time
        FROM main.fact_quote
        GROUP BY symbol_id, quote_time
        HAVING COUNT(*) > 1
    ) d3
    UNION ALL
    SELECT 'fact_ticker_snapshot', COUNT(*)
    FROM (
        SELECT symbol_id, snapshot_time
        FROM main.fact_ticker_snapshot
        GROUP BY symbol_id, snapshot_time
        HAVING COUNT(*) > 1
    ) d4
    UNION ALL
    SELECT 'staging_ticker_24hr_batch_dups', COUNT(*)
    FROM (
        SELECT symbol, batch_id
        FROM staging.ticker_24hr
        WHERE batch_id IS NOT NULL
        GROUP BY symbol, batch_id
        HAVING COUNT(*) > 1
    ) d5
) AS dup_checks
WHERE dup_groups > 0;

-- DQ #4: Required key / price / quantity null checks
SELECT check_name, null_rows
FROM (
    SELECT 'fact_candle_1m_key_nulls' AS check_name, COUNT(*) AS null_rows
    FROM main.fact_candle_1m
    WHERE symbol_id IS NULL OR open_time IS NULL OR close IS NULL
    UNION ALL
    SELECT 'fact_trade_key_nulls', COUNT(*)
    FROM main.fact_trade
    WHERE symbol_id IS NULL OR agg_trade_id IS NULL OR trade_time IS NULL OR price IS NULL OR quantity IS NULL
    UNION ALL
    SELECT 'fact_quote_key_nulls', COUNT(*)
    FROM main.fact_quote
    WHERE symbol_id IS NULL OR quote_time IS NULL OR bid_price IS NULL OR ask_price IS NULL
    UNION ALL
    SELECT 'fact_ticker_snapshot_key_nulls', COUNT(*)
    FROM main.fact_ticker_snapshot
    WHERE symbol_id IS NULL OR snapshot_time IS NULL OR last_price IS NULL
) AS null_checks
WHERE null_rows > 0;

-- DQ #5: 15-minute UTC candle freshness check
SELECT
    MAX(open_time) AS newest_candle_utc,
    EXTRACT(EPOCH FROM ((NOW() AT TIME ZONE 'UTC') - MAX(open_time))) / 60.0 AS age_minutes
FROM main.fact_candle_1m
HAVING MAX(open_time) IS NULL
    OR EXTRACT(EPOCH FROM ((NOW() AT TIME ZONE 'UTC') - MAX(open_time))) / 60.0 > 15;
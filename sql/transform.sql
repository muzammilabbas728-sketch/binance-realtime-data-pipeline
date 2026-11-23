-- ============================================================================
-- Step 1: Populate main.dim_symbol
-- ============================================================================
INSERT INTO main.dim_symbol (symbol, base_asset, quote_asset)
SELECT DISTINCT
    TRIM(UPPER(s.symbol)) AS symbol,
    CASE
        WHEN TRIM(UPPER(s.symbol)) LIKE '%USDT'
            THEN LEFT(TRIM(UPPER(s.symbol)), LENGTH(TRIM(UPPER(s.symbol))) - 4)
        WHEN TRIM(UPPER(s.symbol)) LIKE '%BUSD'
            THEN LEFT(TRIM(UPPER(s.symbol)), LENGTH(TRIM(UPPER(s.symbol))) - 4)
        WHEN TRIM(UPPER(s.symbol)) LIKE '%FDUSD'
            THEN LEFT(TRIM(UPPER(s.symbol)), LENGTH(TRIM(UPPER(s.symbol))) - 5)
        WHEN TRIM(UPPER(s.symbol)) LIKE '%USDC'
            THEN LEFT(TRIM(UPPER(s.symbol)), LENGTH(TRIM(UPPER(s.symbol))) - 4)
        ELSE TRIM(UPPER(s.symbol))
    END AS base_asset,
    CASE
        WHEN TRIM(UPPER(s.symbol)) LIKE '%USDT' THEN 'USDT'
        WHEN TRIM(UPPER(s.symbol)) LIKE '%BUSD' THEN 'BUSD'
        WHEN TRIM(UPPER(s.symbol)) LIKE '%FDUSD' THEN 'FDUSD'
        WHEN TRIM(UPPER(s.symbol)) LIKE '%USDC' THEN 'USDC'
        ELSE 'USD'
    END AS quote_asset
FROM (
    SELECT symbol FROM staging.klines_1m
    UNION
    SELECT symbol FROM staging.agg_trades
    UNION
    SELECT symbol FROM staging.ticker_24hr
    UNION
    SELECT symbol FROM staging.book_ticker
) AS s
WHERE s.symbol IS NOT NULL
  AND TRIM(s.symbol) <> ''
ON CONFLICT (symbol) DO NOTHING;

-- ============================================================================
-- Step 2: Populate main.fact_candle_1m
-- ============================================================================
WITH cleaned_candles AS (
    SELECT
        d.symbol_id,
        (TO_TIMESTAMP(s.open_time::BIGINT / 1000.0) AT TIME ZONE 'UTC')::TIMESTAMP WITHOUT TIME ZONE AS open_time,
        (TO_TIMESTAMP(s.close_time::BIGINT / 1000.0) AT TIME ZONE 'UTC')::TIMESTAMP WITHOUT TIME ZONE AS close_time,
        s.open::DECIMAL(18,8) AS open,
        s.high::DECIMAL(18,8) AS high,
        s.low::DECIMAL(18,8) AS low,
        s.close::DECIMAL(18,8) AS close,
        s.volume::DECIMAL(24,8) AS volume,
        COALESCE(s.trades::INT, 0) AS trades,
        COALESCE(s.taker_buy_base_vol::DECIMAL(24,8), 0::DECIMAL(24,8)) AS taker_buy_base_vol,
        DATE_TRUNC('minute', (TO_TIMESTAMP(s.open_time::BIGINT / 1000.0) AT TIME ZONE 'UTC'))::TIMESTAMP WITHOUT TIME ZONE AS minute_bucket,
        s.batch_id,
        s.ingested_at
    FROM staging.klines_1m AS s
    JOIN main.dim_symbol AS d
        ON d.symbol = TRIM(UPPER(s.symbol))
    WHERE s.symbol IS NOT NULL
      AND s.open_time IS NOT NULL
      AND s.open::DECIMAL(18,8) > 0
      AND s.high::DECIMAL(18,8) > 0
      AND s.low::DECIMAL(18,8) > 0
      AND s.close::DECIMAL(18,8) > 0
      AND s.high::DECIMAL(18,8) >= s.low::DECIMAL(18,8)
      AND s.volume::DECIMAL(24,8) >= 0
      AND (TO_TIMESTAMP(s.close_time::BIGINT / 1000.0) AT TIME ZONE 'UTC')::TIMESTAMP WITHOUT TIME ZONE < (NOW() AT TIME ZONE 'UTC')::TIMESTAMP WITHOUT TIME ZONE
),
dedup_candles AS (
    SELECT DISTINCT ON (symbol_id, open_time)
        symbol_id,
        open_time,
        close_time,
        open,
        high,
        low,
        close,
        volume,
        trades,
        taker_buy_base_vol,
        minute_bucket,
        batch_id
    FROM cleaned_candles
    ORDER BY symbol_id, open_time, ingested_at DESC NULLS LAST
),
enriched_candles AS (
    SELECT
        symbol_id,
        open_time,
        close_time,
        open,
        high,
        low,
        close,
        volume,
        trades,
        taker_buy_base_vol,
        ((high + low + close) / 3.0)::DECIMAL(18,8) AS typical_price,
        ((close::DOUBLE PRECISION - LAG(close::DOUBLE PRECISION) OVER (PARTITION BY symbol_id ORDER BY open_time))
            / NULLIF(LAG(close::DOUBLE PRECISION) OVER (PARTITION BY symbol_id ORDER BY open_time), 0)) AS return_1m,
        LN(close::DOUBLE PRECISION / NULLIF(LAG(close::DOUBLE PRECISION) OVER (PARTITION BY symbol_id ORDER BY open_time), 0)) AS log_return_1m,
        minute_bucket,
        batch_id
    FROM dedup_candles
)
INSERT INTO main.fact_candle_1m (
    symbol_id,
    open_time,
    close_time,
    open,
    high,
    low,
    close,
    volume,
    trades,
    taker_buy_base_vol,
    typical_price,
    return_1m,
    log_return_1m,
    minute_bucket,
    batch_id
)
SELECT
    symbol_id,
    open_time,
    close_time,
    open,
    high,
    low,
    close,
    volume,
    trades,
    taker_buy_base_vol,
    typical_price,
    return_1m,
    log_return_1m,
    minute_bucket,
    batch_id
FROM enriched_candles
ON CONFLICT (symbol_id, open_time) DO NOTHING;


-- ============================================================================
-- Step 3: Populate main.fact_trade
-- ============================================================================
WITH cleaned_trades AS (
    SELECT
        d.symbol_id,
        s.agg_trade_id::BIGINT AS agg_trade_id,
        (TO_TIMESTAMP(s.trade_time::BIGINT / 1000.0) AT TIME ZONE 'UTC')::TIMESTAMP WITHOUT TIME ZONE AS trade_time,
        s.price::DECIMAL(18,8) AS price,
        s.quantity::DECIMAL(24,8) AS quantity,
       CASE
            WHEN LOWER(TRIM(COALESCE(s.is_buyer_maker::TEXT, ''))) IN ('true', 't', '1') THEN 'SELL'
            WHEN LOWER(TRIM(COALESCE(s.is_buyer_maker::TEXT, ''))) IN ('false', 'f', '0') THEN 'BUY'
            ELSE NULL
        END AS side,
        DATE_TRUNC('minute', (TO_TIMESTAMP(s.trade_time::BIGINT / 1000.0) AT TIME ZONE 'UTC'))::TIMESTAMP WITHOUT TIME ZONE AS minute_bucket,
        s.batch_id,
        s.ingested_at
    FROM staging.agg_trades AS s
    JOIN main.dim_symbol AS d
        ON d.symbol = TRIM(UPPER(s.symbol))
    WHERE s.symbol IS NOT NULL
      AND s.agg_trade_id IS NOT NULL
      AND s.trade_time IS NOT NULL
      AND s.price::DECIMAL(18,8) > 0
      AND s.quantity::DECIMAL(24,8) > 0
),
dedup_trades AS (
    SELECT DISTINCT ON (symbol_id, agg_trade_id)
        symbol_id,
        agg_trade_id,
        trade_time,
        price,
        quantity,
        side,
        minute_bucket,
        batch_id
    FROM cleaned_trades
    ORDER BY symbol_id, agg_trade_id, ingested_at DESC NULLS LAST
)
INSERT INTO main.fact_trade (
    symbol_id,
    agg_trade_id,
    trade_time,
    price,
    quantity,
    side,
    minute_bucket,
    batch_id
)
SELECT
    symbol_id,
    agg_trade_id,
    trade_time,
    price,
    quantity,
    side,
    minute_bucket,
    batch_id
FROM dedup_trades
ON CONFLICT (symbol_id, agg_trade_id) DO NOTHING;


-- ============================================================================
-- Step 4: Populate main.fact_quote
-- ============================================================================
WITH cleaned_quotes AS (
    SELECT
        d.symbol_id,
        s.ingested_at AS quote_time,
        s.bid_price::DECIMAL(18,8) AS bid_price,
        COALESCE(s.bid_qty::DECIMAL(24,8), 0::DECIMAL(24,8)) AS bid_qty,
        s.ask_price::DECIMAL(18,8) AS ask_price,
        COALESCE(s.ask_qty::DECIMAL(24,8), 0::DECIMAL(24,8)) AS ask_qty,
        s.batch_id
    FROM staging.book_ticker AS s
    JOIN main.dim_symbol AS d
        ON d.symbol = TRIM(UPPER(s.symbol))
    WHERE s.symbol IS NOT NULL
      AND s.ingested_at IS NOT NULL
      AND s.bid_price::DECIMAL(18,8) > 0
      AND s.ask_price::DECIMAL(18,8) > 0
      AND s.ask_price::DECIMAL(18,8) >= s.bid_price::DECIMAL(18,8)
      AND COALESCE(s.bid_qty::DECIMAL(24,8), 0::DECIMAL(24,8)) >= 0
      AND COALESCE(s.ask_qty::DECIMAL(24,8), 0::DECIMAL(24,8)) >= 0
),
dedup_quotes AS (
    SELECT DISTINCT ON (symbol_id, quote_time)
        symbol_id,
        quote_time,
        bid_price,
        bid_qty,
        ask_price,
        ask_qty,
        batch_id
    FROM cleaned_quotes
    ORDER BY symbol_id, quote_time, bid_price DESC, ask_price ASC
),
enriched_quotes AS (
    SELECT
        symbol_id,
        quote_time,
        bid_price,
        bid_qty,
        ask_price,
        ask_qty,
        ((bid_price + ask_price) / 2.0)::DECIMAL(18,8) AS mid_price,
        (ask_price - bid_price)::DECIMAL(18,8) AS spread,
        CASE
            WHEN ((bid_price::DOUBLE PRECISION + ask_price::DOUBLE PRECISION) / 2.0) > 0
                THEN (
                    (ask_price::DOUBLE PRECISION - bid_price::DOUBLE PRECISION)
                    / ((bid_price::DOUBLE PRECISION + ask_price::DOUBLE PRECISION) / 2.0)
                ) * 10000.0
            ELSE 0.0
        END AS spread_bps,
        batch_id
    FROM dedup_quotes
)
INSERT INTO main.fact_quote (
    symbol_id,
    quote_time,
    bid_price,
    bid_qty,
    ask_price,
    ask_qty,
    mid_price,
    spread,
    spread_bps,
    batch_id
)
SELECT
    symbol_id,
    quote_time,
    bid_price,
    bid_qty,
    ask_price,
    ask_qty,
    mid_price,
    spread,
    spread_bps,
    batch_id
FROM enriched_quotes
ON CONFLICT (symbol_id, quote_time) DO NOTHING;


-- ============================================================================
-- Step 5: Populate main.fact_ticker_snapshot
-- ============================================================================
WITH cleaned_ticker AS (
    SELECT
        d.symbol_id,
        (TO_TIMESTAMP(s.close_time::BIGINT / 1000.0) AT TIME ZONE 'UTC')::TIMESTAMP WITHOUT TIME ZONE AS snapshot_time,
        s.last_price::DECIMAL(18,8) AS last_price,
        s.open_price::DECIMAL(18,8) AS open_price,
        s.high_price::DECIMAL(18,8) AS high_price,
        s.low_price::DECIMAL(18,8) AS low_price,
        s.price_change_percent::DOUBLE PRECISION AS price_change_pct,
        COALESCE(s.volume::DECIMAL(24,8), 0::DECIMAL(24,8)) AS volume,
        s.batch_id,
        s.ingested_at
    FROM staging.ticker_24hr AS s
    JOIN main.dim_symbol AS d
        ON d.symbol = TRIM(UPPER(s.symbol))
    WHERE s.symbol IS NOT NULL
      AND s.close_time IS NOT NULL
      AND s.last_price::DECIMAL(18,8) > 0
      AND s.open_price::DECIMAL(18,8) > 0
      AND s.high_price::DECIMAL(18,8) > 0
      AND s.low_price::DECIMAL(18,8) > 0
      AND s.high_price::DECIMAL(18,8) >= s.low_price::DECIMAL(18,8)
      AND COALESCE(s.volume::DECIMAL(24,8), 0::DECIMAL(24,8)) >= 0
),
dedup_ticker AS (
    SELECT DISTINCT ON (symbol_id, snapshot_time)
        symbol_id,
        snapshot_time,
        last_price,
        open_price,
        high_price,
        low_price,
        price_change_pct,
        volume,
        batch_id
    FROM cleaned_ticker
    ORDER BY symbol_id, snapshot_time, ingested_at DESC NULLS LAST
)
INSERT INTO main.fact_ticker_snapshot (
    symbol_id,
    snapshot_time,
    last_price,
    open_price,
    high_price,
    low_price,
    price_change_pct,
    volume,
    batch_id
)
SELECT
    symbol_id,
    snapshot_time,
    last_price,
    open_price,
    high_price,
    low_price,
    price_change_pct,
    volume,
    batch_id
FROM dedup_ticker
ON CONFLICT (symbol_id, snapshot_time) DO NOTHING;


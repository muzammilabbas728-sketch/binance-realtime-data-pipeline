-- ============================================================================
-- refresh_reports.sql — Transactional Refreshes for main.rpt_q01 .. rpt_q10
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Report Q01: Rolling 5m & 60m VWAP and % Diff
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS main.rpt_q01 (
    symbol_id            INTEGER NOT NULL,
    symbol               VARCHAR(32) NOT NULL,
    candle_time          TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    last_price           DOUBLE PRECISION NOT NULL,
    vwap_5m              DOUBLE PRECISION,
    vwap_60m             DOUBLE PRECISION,
    pct_diff_vs_vwap_5m  DOUBLE PRECISION,
    pct_diff_vs_vwap_60m DOUBLE PRECISION,
    refreshed_at         TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

BEGIN;

DELETE FROM main.rpt_q01;

INSERT INTO main.rpt_q01 (
    symbol_id,
    symbol,
    candle_time,
    last_price,
    vwap_5m,
    vwap_60m,
    pct_diff_vs_vwap_5m,
    pct_diff_vs_vwap_60m,
    refreshed_at
)
WITH candle_calc AS (
    SELECT
        c.symbol_id,
        d.symbol,
        c.open_time AS candle_time,
        c.close AS last_price,
        SUM(c.typical_price * c.volume) OVER (
            PARTITION BY c.symbol_id
            ORDER BY c.open_time
            ROWS BETWEEN 4 PRECEDING AND CURRENT ROW
        ) / NULLIF(
            SUM(c.volume) OVER (
                PARTITION BY c.symbol_id
                ORDER BY c.open_time
                ROWS BETWEEN 4 PRECEDING AND CURRENT ROW
            ),
            0
        ) AS vwap_5m,
        SUM(c.typical_price * c.volume) OVER (
            PARTITION BY c.symbol_id
            ORDER BY c.open_time
            ROWS BETWEEN 59 PRECEDING AND CURRENT ROW
        ) / NULLIF(
            SUM(c.volume) OVER (
                PARTITION BY c.symbol_id
                ORDER BY c.open_time
                ROWS BETWEEN 59 PRECEDING AND CURRENT ROW
            ),
            0
        ) AS vwap_60m
    FROM main.fact_candle_1m AS c
    JOIN main.dim_symbol AS d
        ON d.symbol_id = c.symbol_id
)
SELECT
    symbol_id,
    symbol,
    candle_time,
    last_price,
    vwap_5m,
    vwap_60m,
    CASE
        WHEN vwap_5m IS NOT NULL AND vwap_5m > 0
            THEN ((last_price - vwap_5m) / vwap_5m) * 100.0
        ELSE NULL
    END AS pct_diff_vs_vwap_5m,
    CASE
        WHEN vwap_60m IS NOT NULL AND vwap_60m > 0
            THEN ((last_price - vwap_60m) / vwap_60m) * 100.0
        ELSE NULL
    END AS pct_diff_vs_vwap_60m,
    CURRENT_TIMESTAMP::TIMESTAMP WITHOUT TIME ZONE AS refreshed_at
FROM candle_calc;

COMMIT;


-- ----------------------------------------------------------------------------
-- Report Q02: Momentum Returns (15m, 1h, 24h) & 1h Rank Shift
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS main.rpt_q02 (
    symbol_id           INTEGER NOT NULL,
    symbol              VARCHAR(32) NOT NULL,
    candle_time         TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    close_price         DOUBLE PRECISION NOT NULL,
    pct_change_15m      DOUBLE PRECISION,
    pct_change_1h       DOUBLE PRECISION,
    pct_change_24h      DOUBLE PRECISION,
    rank_1h             INTEGER,
    prev_rank_1h        INTEGER,
    rank_change_vs_1h   INTEGER,
    refreshed_at        TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

BEGIN;

DELETE FROM main.rpt_q02;

INSERT INTO main.rpt_q02 (
    symbol_id,
    symbol,
    candle_time,
    close_price,
    pct_change_15m,
    pct_change_1h,
    pct_change_24h,
    rank_1h,
    prev_rank_1h,
    rank_change_vs_1h,
    refreshed_at
)
WITH returns_calc AS (
    SELECT
        c.symbol_id,
        d.symbol,
        c.open_time AS candle_time,
        c.close AS close_price,
        LAG(c.close, 15) OVER (PARTITION BY c.symbol_id ORDER BY c.open_time) AS close_15m_ago,
        LAG(c.close, 60) OVER (PARTITION BY c.symbol_id ORDER BY c.open_time) AS close_1h_ago,
        LAG(c.close, 1440) OVER (PARTITION BY c.symbol_id ORDER BY c.open_time) AS close_24h_ago
    FROM main.fact_candle_1m AS c
    JOIN main.dim_symbol AS d
        ON d.symbol_id = c.symbol_id
),
pct_calc AS (
    SELECT
        symbol_id,
        symbol,
        candle_time,
        close_price,
        CASE
            WHEN close_15m_ago IS NOT NULL AND close_15m_ago > 0
                THEN ((close_price - close_15m_ago) / close_15m_ago) * 100.0
            ELSE NULL
        END AS pct_change_15m,
        CASE
            WHEN close_1h_ago IS NOT NULL AND close_1h_ago > 0
                THEN ((close_price - close_1h_ago) / close_1h_ago) * 100.0
            ELSE NULL
        END AS pct_change_1h,
        CASE
            WHEN close_24h_ago IS NOT NULL AND close_24h_ago > 0
                THEN ((close_price - close_24h_ago) / close_24h_ago) * 100.0
            ELSE NULL
        END AS pct_change_24h
    FROM returns_calc
),
ranked_calc AS (
    SELECT
        symbol_id,
        symbol,
        candle_time,
        close_price,
        pct_change_15m,
        pct_change_1h,
        pct_change_24h,
        RANK() OVER (
            PARTITION BY candle_time
            ORDER BY pct_change_1h DESC NULLS LAST
        )::INTEGER AS rank_1h
    FROM pct_calc
)
SELECT
    symbol_id,
    symbol,
    candle_time,
    close_price,
    pct_change_15m,
    pct_change_1h,
    pct_change_24h,
    rank_1h,
    LAG(rank_1h, 60) OVER (PARTITION BY symbol_id ORDER BY candle_time)::INTEGER AS prev_rank_1h,
    CASE
        WHEN LAG(rank_1h, 60) OVER (PARTITION BY symbol_id ORDER BY candle_time) IS NOT NULL
            THEN (LAG(rank_1h, 60) OVER (PARTITION BY symbol_id ORDER BY candle_time) - rank_1h)::INTEGER
        ELSE NULL
    END AS rank_change_vs_1h,
    CURRENT_TIMESTAMP::TIMESTAMP WITHOUT TIME ZONE AS refreshed_at
FROM ranked_calc;

COMMIT;


-- ----------------------------------------------------------------------------
-- Report Q03: Rolling 30m Volatility Regimes (Last 6h)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS main.rpt_q03 (
    symbol_id              INTEGER NOT NULL,
    symbol                 VARCHAR(32) NOT NULL,
    regime                 VARCHAR(16) NOT NULL,
    minutes_in_regime      INTEGER NOT NULL,
    pct_time_in_regime     DOUBLE PRECISION,
    avg_rolling_vol_30m    DOUBLE PRECISION,
    latest_rolling_vol_30m DOUBLE PRECISION,
    p33_cutoff             DOUBLE PRECISION,
    p67_cutoff             DOUBLE PRECISION,
    window_start           TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    window_end             TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    refreshed_at           TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

BEGIN;

DELETE FROM main.rpt_q03;

INSERT INTO main.rpt_q03 (
    symbol_id,
    symbol,
    regime,
    minutes_in_regime,
    pct_time_in_regime,
    avg_rolling_vol_30m,
    latest_rolling_vol_30m,
    p33_cutoff,
    p67_cutoff,
    window_start,
    window_end,
    refreshed_at
)
WITH max_ts AS (
    SELECT MAX(open_time) AS latest_time
    FROM main.fact_candle_1m
),
rolling_vol AS (
    SELECT
        c.symbol_id,
        d.symbol,
        c.open_time AS candle_time,
        STDDEV(c.log_return_1m) OVER (
            PARTITION BY c.symbol_id
            ORDER BY c.open_time
            ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
        ) AS rolling_vol_30m,
        m.latest_time
    FROM main.fact_candle_1m AS c
    JOIN main.dim_symbol AS d
        ON d.symbol_id = c.symbol_id
    CROSS JOIN max_ts AS m
    WHERE c.open_time >= m.latest_time - INTERVAL '6 hours'
),
cutoffs AS (
    SELECT
        symbol_id,
        PERCENTILE_CONT(0.33) WITHIN GROUP (ORDER BY rolling_vol_30m) AS p33_cutoff,
        PERCENTILE_CONT(0.67) WITHIN GROUP (ORDER BY rolling_vol_30m) AS p67_cutoff
    FROM rolling_vol
    WHERE rolling_vol_30m IS NOT NULL
    GROUP BY symbol_id
),
classified AS (
    SELECT
        r.symbol_id,
        r.symbol,
        r.candle_time,
        r.rolling_vol_30m,
        r.latest_time,
        ct.p33_cutoff,
        ct.p67_cutoff,
        CASE
            WHEN r.rolling_vol_30m <= ct.p33_cutoff THEN 'Low'
            WHEN r.rolling_vol_30m <= ct.p67_cutoff THEN 'Medium'
            ELSE 'High'
        END AS regime
    FROM rolling_vol AS r
    JOIN cutoffs AS ct
        ON ct.symbol_id = r.symbol_id
    WHERE r.rolling_vol_30m IS NOT NULL
),
latest_vol_per_symbol AS (
    SELECT DISTINCT ON (symbol_id)
        symbol_id,
        rolling_vol_30m AS latest_rolling_vol_30m
    FROM classified
    ORDER BY symbol_id, candle_time DESC
),
regime_counts AS (
    SELECT
        cl.symbol_id,
        cl.symbol,
        cl.regime,
        COUNT(*)::INTEGER AS minutes_in_regime,
        AVG(cl.rolling_vol_30m) AS avg_rolling_vol_30m,
        lv.latest_rolling_vol_30m,
        MIN(cl.p33_cutoff) AS p33_cutoff,
        MIN(cl.p67_cutoff) AS p67_cutoff,
        MIN(cl.latest_time) - INTERVAL '6 hours' AS window_start,
        MIN(cl.latest_time) AS window_end
    FROM classified AS cl
    JOIN latest_vol_per_symbol AS lv
        ON lv.symbol_id = cl.symbol_id
    GROUP BY
        cl.symbol_id,
        cl.symbol,
        cl.regime,
        lv.latest_rolling_vol_30m
)
SELECT
    symbol_id,
    symbol,
    regime,
    minutes_in_regime,
    (minutes_in_regime::DOUBLE PRECISION / NULLIF(SUM(minutes_in_regime) OVER (PARTITION BY symbol_id), 0)) * 100.0 AS pct_time_in_regime,
    avg_rolling_vol_30m,
    latest_rolling_vol_30m,
    p33_cutoff,
    p67_cutoff,
    window_start::TIMESTAMP WITHOUT TIME ZONE,
    window_end::TIMESTAMP WITHOUT TIME ZONE,
    CURRENT_TIMESTAMP::TIMESTAMP WITHOUT TIME ZONE AS refreshed_at
FROM regime_counts;

COMMIT;


-- ----------------------------------------------------------------------------
-- Report Q04: SMA 5 / SMA 20 Crossovers (Last 24h)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS main.rpt_q04 (
    symbol_id            INTEGER NOT NULL,
    symbol               VARCHAR(32) NOT NULL,
    crossover_time       TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    close_price          DOUBLE PRECISION NOT NULL,
    sma_5                DOUBLE PRECISION NOT NULL,
    sma_20               DOUBLE PRECISION NOT NULL,
    prev_sma_5           DOUBLE PRECISION NOT NULL,
    prev_sma_20          DOUBLE PRECISION NOT NULL,
    crossover_type       VARCHAR(16) NOT NULL,
    bullish_count_24h    INTEGER NOT NULL,
    bearish_count_24h    INTEGER NOT NULL,
    total_crossovers_24h INTEGER NOT NULL,
    refreshed_at         TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

BEGIN;

DELETE FROM main.rpt_q04;

INSERT INTO main.rpt_q04 (
    symbol_id,
    symbol,
    crossover_time,
    close_price,
    sma_5,
    sma_20,
    prev_sma_5,
    prev_sma_20,
    crossover_type,
    bullish_count_24h,
    bearish_count_24h,
    total_crossovers_24h,
    refreshed_at
)
WITH max_ts AS (
    SELECT MAX(open_time) AS latest_time
    FROM main.fact_candle_1m
),
smas AS (
    SELECT
        c.symbol_id,
        d.symbol,
        c.open_time AS candle_time,
        c.close AS close_price,
        AVG(c.close) OVER (
            PARTITION BY c.symbol_id
            ORDER BY c.open_time
            ROWS BETWEEN 4 PRECEDING AND CURRENT ROW
        ) AS sma_5,
        AVG(c.close) OVER (
            PARTITION BY c.symbol_id
            ORDER BY c.open_time
            ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
        ) AS sma_20,
        m.latest_time
    FROM main.fact_candle_1m AS c
    JOIN main.dim_symbol AS d
        ON d.symbol_id = c.symbol_id
    CROSS JOIN max_ts AS m
),
with_prev AS (
    SELECT
        symbol_id,
        symbol,
        candle_time,
        close_price,
        sma_5,
        sma_20,
        LAG(sma_5) OVER (PARTITION BY symbol_id ORDER BY candle_time) AS prev_sma_5,
        LAG(sma_20) OVER (PARTITION BY symbol_id ORDER BY candle_time) AS prev_sma_20,
        latest_time
    FROM smas
),
events_24h AS (
    SELECT
        symbol_id,
        symbol,
        candle_time AS crossover_time,
        close_price,
        sma_5,
        sma_20,
        prev_sma_5,
        prev_sma_20,
        CASE
            WHEN prev_sma_5 <= prev_sma_20 AND sma_5 > sma_20 THEN 'BULLISH'
            WHEN prev_sma_5 >= prev_sma_20 AND sma_5 < sma_20 THEN 'BEARISH'
            ELSE NULL
        END AS crossover_type
    FROM with_prev
    WHERE candle_time >= latest_time - INTERVAL '24 hours'
      AND sma_5 IS NOT NULL
      AND sma_20 IS NOT NULL
      AND prev_sma_5 IS NOT NULL
      AND prev_sma_20 IS NOT NULL
),
filtered_events AS (
    SELECT *
    FROM events_24h
    WHERE crossover_type IS NOT NULL
)
SELECT
    symbol_id,
    symbol,
    crossover_time,
    close_price,
    sma_5,
    sma_20,
    prev_sma_5,
    prev_sma_20,
    crossover_type,
    COUNT(*) FILTER (WHERE crossover_type = 'BULLISH') OVER (PARTITION BY symbol_id)::INTEGER AS bullish_count_24h,
    COUNT(*) FILTER (WHERE crossover_type = 'BEARISH') OVER (PARTITION BY symbol_id)::INTEGER AS bearish_count_24h,
    COUNT(*) OVER (PARTITION BY symbol_id)::INTEGER AS total_crossovers_24h,
    CURRENT_TIMESTAMP::TIMESTAMP WITHOUT TIME ZONE AS refreshed_at
FROM filtered_events;

COMMIT;


-- ----------------------------------------------------------------------------
-- Report Q05: Volume Spikes (z-score > 3) & Next 5m Move
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS main.rpt_q05 (
    symbol_id               INTEGER NOT NULL,
    symbol                  VARCHAR(32) NOT NULL,
    spike_time              TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    close_price             DOUBLE PRECISION NOT NULL,
    volume                  DOUBLE PRECISION NOT NULL,
    mean_volume_60m         DOUBLE PRECISION,
    stddev_volume_60m       DOUBLE PRECISION,
    volume_z_score          DOUBLE PRECISION,
    is_volume_spike         BOOLEAN NOT NULL,
    price_5m_ahead          DOUBLE PRECISION,
    pct_move_next_5m        DOUBLE PRECISION,
    refreshed_at            TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

BEGIN;

DELETE FROM main.rpt_q05;

INSERT INTO main.rpt_q05 (
    symbol_id,
    symbol,
    spike_time,
    close_price,
    volume,
    mean_volume_60m,
    stddev_volume_60m,
    volume_z_score,
    is_volume_spike,
    price_5m_ahead,
    pct_move_next_5m,
    refreshed_at
)
WITH vol_stats AS (
    SELECT
        c.symbol_id,
        d.symbol,
        c.open_time AS candle_time,
        c.close AS close_price,
        c.volume,
        AVG(c.volume) OVER (
            PARTITION BY c.symbol_id
            ORDER BY c.open_time
            ROWS BETWEEN 60 PRECEDING AND 1 PRECEDING
        ) AS mean_volume_60m,
        STDDEV(c.volume) OVER (
            PARTITION BY c.symbol_id
            ORDER BY c.open_time
            ROWS BETWEEN 60 PRECEDING AND 1 PRECEDING
        ) AS stddev_volume_60m,
        LEAD(c.close, 5) OVER (
            PARTITION BY c.symbol_id
            ORDER BY c.open_time
        ) AS price_5m_ahead
    FROM main.fact_candle_1m AS c
    JOIN main.dim_symbol AS d
        ON d.symbol_id = c.symbol_id
),
z_scored AS (
    SELECT
        symbol_id,
        symbol,
        candle_time AS spike_time,
        close_price,
        volume,
        mean_volume_60m,
        stddev_volume_60m,
        CASE
            WHEN stddev_volume_60m IS NOT NULL AND stddev_volume_60m > 0
                THEN (volume - mean_volume_60m) / stddev_volume_60m
            ELSE NULL
        END AS volume_z_score,
        price_5m_ahead
    FROM vol_stats
)
SELECT
    symbol_id,
    symbol,
    spike_time,
    close_price,
    volume,
    mean_volume_60m,
    stddev_volume_60m,
    volume_z_score,
    COALESCE(volume_z_score > 3.0, FALSE) AS is_volume_spike,
    price_5m_ahead,
    CASE
        WHEN price_5m_ahead IS NOT NULL AND close_price > 0
            THEN ((price_5m_ahead - close_price) / close_price) * 100.0
        ELSE NULL
    END AS pct_move_next_5m,
    CURRENT_TIMESTAMP::TIMESTAMP WITHOUT TIME ZONE AS refreshed_at
FROM z_scored
WHERE volume_z_score > 3.0
ORDER BY spike_time DESC, symbol;

COMMIT;


-- ----------------------------------------------------------------------------
-- Report Q06: Taker Buy/Sell Volume Delta & Divergence (Last 2h)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS main.rpt_q06 (
    symbol_id               INTEGER NOT NULL,
    symbol                  VARCHAR(32) NOT NULL,
    minute_bucket           TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    taker_buy_volume        DOUBLE PRECISION NOT NULL,
    taker_sell_volume       DOUBLE PRECISION NOT NULL,
    net_volume_delta        DOUBLE PRECISION NOT NULL,
    cumulative_delta_2h     DOUBLE PRECISION NOT NULL,
    minute_close_price      DOUBLE PRECISION,
    prev_cumulative_delta   DOUBLE PRECISION,
    prev_close_price        DOUBLE PRECISION,
    divergence_signal       VARCHAR(24) NOT NULL,
    refreshed_at            TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

BEGIN;

DELETE FROM main.rpt_q06;

INSERT INTO main.rpt_q06 (
    symbol_id,
    symbol,
    minute_bucket,
    taker_buy_volume,
    taker_sell_volume,
    net_volume_delta,
    cumulative_delta_2h,
    minute_close_price,
    prev_cumulative_delta,
    prev_close_price,
    divergence_signal,
    refreshed_at
)
WITH max_ts AS (
    SELECT MAX(trade_time) AS latest_trade_time
    FROM main.fact_trade
),
minute_flow AS (
    SELECT
        t.symbol_id,
        d.symbol,
        DATE_TRUNC('minute', t.trade_time)::TIMESTAMP WITHOUT TIME ZONE AS minute_bucket,
        COALESCE(SUM(t.quantity) FILTER (WHERE t.side = 'BUY'), 0.0) AS taker_buy_volume,
        COALESCE(SUM(t.quantity) FILTER (WHERE t.side = 'SELL'), 0.0) AS taker_sell_volume,
        COALESCE(SUM(t.quantity) FILTER (WHERE t.side = 'BUY'), 0.0)
            - COALESCE(SUM(t.quantity) FILTER (WHERE t.side = 'SELL'), 0.0) AS net_volume_delta,
        m.latest_trade_time
    FROM main.fact_trade AS t
    JOIN main.dim_symbol AS d
        ON d.symbol_id = t.symbol_id
    CROSS JOIN max_ts AS m
    WHERE t.trade_time >= m.latest_trade_time - INTERVAL '2 hours'
    GROUP BY
        t.symbol_id,
        d.symbol,
        DATE_TRUNC('minute', t.trade_time),
        m.latest_trade_time
),
minute_prices AS (
    SELECT
        symbol_id,
        minute_bucket::TIMESTAMP WITHOUT TIME ZONE AS minute_bucket,
        close AS minute_close_price
    FROM main.fact_candle_1m
),
with_cum_delta AS (
    SELECT
        mf.symbol_id,
        mf.symbol,
        mf.minute_bucket,
        mf.taker_buy_volume,
        mf.taker_sell_volume,
        mf.net_volume_delta,
        SUM(mf.net_volume_delta) OVER (
            PARTITION BY mf.symbol_id
            ORDER BY mf.minute_bucket
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_delta_2h,
        mp.minute_close_price
    FROM minute_flow AS mf
    LEFT JOIN minute_prices AS mp
        ON mp.symbol_id = mf.symbol_id
       AND mp.minute_bucket = mf.minute_bucket
),
with_lags AS (
    SELECT
        symbol_id,
        symbol,
        minute_bucket,
        taker_buy_volume,
        taker_sell_volume,
        net_volume_delta,
        cumulative_delta_2h,
        minute_close_price,
        LAG(cumulative_delta_2h) OVER (
            PARTITION BY symbol_id
            ORDER BY minute_bucket
        ) AS prev_cumulative_delta,
        LAG(minute_close_price) OVER (
            PARTITION BY symbol_id
            ORDER BY minute_bucket
        ) AS prev_close_price
    FROM with_cum_delta
)
SELECT
    symbol_id,
    symbol,
    minute_bucket,
    taker_buy_volume,
    taker_sell_volume,
    net_volume_delta,
    cumulative_delta_2h,
    minute_close_price,
    prev_cumulative_delta,
    prev_close_price,
    CASE
        WHEN prev_cumulative_delta IS NOT NULL
         AND prev_close_price IS NOT NULL
         AND cumulative_delta_2h > prev_cumulative_delta
         AND minute_close_price < prev_close_price
            THEN 'BULLISH_DIVERGENCE'
        WHEN prev_cumulative_delta IS NOT NULL
         AND prev_close_price IS NOT NULL
         AND cumulative_delta_2h < prev_cumulative_delta
         AND minute_close_price > prev_close_price
            THEN 'BEARISH_DIVERGENCE'
        ELSE 'NO_DIVERGENCE'
    END AS divergence_signal,
    CURRENT_TIMESTAMP::TIMESTAMP WITHOUT TIME ZONE AS refreshed_at
FROM with_lags
ORDER BY minute_bucket DESC, symbol;

COMMIT;


-- ----------------------------------------------------------------------------
-- Report Q07: 6h Correlation with BTCUSDT & Shift vs Previous 6h
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS main.rpt_q07 (
    symbol_id               INTEGER NOT NULL,
    symbol                  VARCHAR(32) NOT NULL,
    corr_with_btc_6h        DOUBLE PRECISION,
    prev_corr_with_btc_6h   DOUBLE PRECISION,
    corr_change_vs_prev_6h  DOUBLE PRECISION,
    sample_minutes_6h       INTEGER NOT NULL,
    window_start_6h         TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    window_end_6h           TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    refreshed_at            TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

BEGIN;

DELETE FROM main.rpt_q07;

INSERT INTO main.rpt_q07 (
    symbol_id,
    symbol,
    corr_with_btc_6h,
    prev_corr_with_btc_6h,
    corr_change_vs_prev_6h,
    sample_minutes_6h,
    window_start_6h,
    window_end_6h,
    refreshed_at
)
WITH max_ts AS (
    SELECT MAX(open_time) AS latest_time
    FROM main.fact_candle_1m
),
btc_returns AS (
    SELECT
        c.open_time AS candle_time,
        c.return_1m AS btc_return_1m,
        m.latest_time
    FROM main.fact_candle_1m AS c
    JOIN main.dim_symbol AS d
        ON d.symbol_id = c.symbol_id
    CROSS JOIN max_ts AS m
    WHERE d.symbol = 'BTCUSDT'
      AND c.open_time >= m.latest_time - INTERVAL '12 hours'
),
paired_returns AS (
    SELECT
        c.symbol_id,
        d.symbol,
        c.open_time AS candle_time,
        c.return_1m AS symbol_return_1m,
        b.btc_return_1m,
        b.latest_time
    FROM main.fact_candle_1m AS c
    JOIN main.dim_symbol AS d
        ON d.symbol_id = c.symbol_id
    JOIN btc_returns AS b
        ON b.candle_time = c.open_time
    WHERE d.symbol <> 'BTCUSDT'
),
current_6h AS (
    SELECT
        symbol_id,
        symbol,
        CORR(symbol_return_1m, btc_return_1m) AS corr_with_btc_6h,
        COUNT(*)::INTEGER AS sample_minutes_6h,
        MIN(latest_time) - INTERVAL '6 hours' AS window_start_6h,
        MIN(latest_time) AS window_end_6h
    FROM paired_returns
    WHERE candle_time > latest_time - INTERVAL '6 hours'
      AND candle_time <= latest_time
    GROUP BY symbol_id, symbol
),
previous_6h AS (
    SELECT
        symbol_id,
        CORR(symbol_return_1m, btc_return_1m) AS prev_corr_with_btc_6h
    FROM paired_returns
    WHERE candle_time > latest_time - INTERVAL '12 hours'
      AND candle_time <= latest_time - INTERVAL '6 hours'
    GROUP BY symbol_id
)
SELECT
    cur.symbol_id,
    cur.symbol,
    cur.corr_with_btc_6h,
    prv.prev_corr_with_btc_6h,
    CASE
        WHEN cur.corr_with_btc_6h IS NOT NULL AND prv.prev_corr_with_btc_6h IS NOT NULL
            THEN cur.corr_with_btc_6h - prv.prev_corr_with_btc_6h
        ELSE NULL
    END AS corr_change_vs_prev_6h,
    cur.sample_minutes_6h,
    cur.window_start_6h::TIMESTAMP WITHOUT TIME ZONE,
    cur.window_end_6h::TIMESTAMP WITHOUT TIME ZONE,
    CURRENT_TIMESTAMP::TIMESTAMP WITHOUT TIME ZONE AS refreshed_at
FROM current_6h AS cur
LEFT JOIN previous_6h AS prv
    ON prv.symbol_id = cur.symbol_id
ORDER BY cur.corr_with_btc_6h DESC NULLS LAST;

COMMIT;


-- ----------------------------------------------------------------------------
-- Report Q08: Liquidity Rank & Spread Spikes (Last 1h)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS main.rpt_q08 (
    symbol_id                 INTEGER NOT NULL,
    symbol                    VARCHAR(32) NOT NULL,
    liquidity_rank            INTEGER NOT NULL,
    avg_spread_bps_1h         DOUBLE PRECISION,
    p95_spread_bps_1h         DOUBLE PRECISION,
    spike_threshold_bps       DOUBLE PRECISION,
    pct_time_above_2x_avg     DOUBLE PRECISION,
    quote_count_1h            INTEGER NOT NULL,
    window_start_1h           TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    window_end_1h             TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    refreshed_at              TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

BEGIN;

DELETE FROM main.rpt_q08;

INSERT INTO main.rpt_q08 (
    symbol_id,
    symbol,
    liquidity_rank,
    avg_spread_bps_1h,
    p95_spread_bps_1h,
    spike_threshold_bps,
    pct_time_above_2x_avg,
    quote_count_1h,
    window_start_1h,
    window_end_1h,
    refreshed_at
)
WITH max_ts AS (
    SELECT MAX(quote_time) AS latest_quote_time
    FROM main.fact_quote
),
quotes_1h AS (
    SELECT
        q.symbol_id,
        d.symbol,
        q.quote_time,
        q.spread_bps,
        m.latest_quote_time
    FROM main.fact_quote AS q
    JOIN main.dim_symbol AS d
        ON d.symbol_id = q.symbol_id
    CROSS JOIN max_ts AS m
    WHERE q.quote_time >= m.latest_quote_time - INTERVAL '1 hour'
      AND q.spread_bps IS NOT NULL
),
symbol_stats AS (
    SELECT
        symbol_id,
        symbol,
        AVG(spread_bps) AS avg_spread_bps_1h,
        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY spread_bps) AS p95_spread_bps_1h,
        2.0 * AVG(spread_bps) AS spike_threshold_bps,
        COUNT(*)::INTEGER AS quote_count_1h,
        MIN(latest_quote_time) - INTERVAL '1 hour' AS window_start_1h,
        MIN(latest_quote_time) AS window_end_1h
    FROM quotes_1h
    GROUP BY symbol_id, symbol
),
with_exceedance AS (
    SELECT
        q.symbol_id,
        q.symbol,
        s.avg_spread_bps_1h,
        s.p95_spread_bps_1h,
        s.spike_threshold_bps,
        (COUNT(*) FILTER (WHERE q.spread_bps > s.spike_threshold_bps)::DOUBLE PRECISION
            / NULLIF(s.quote_count_1h, 0)) * 100.0 AS pct_time_above_2x_avg,
        s.quote_count_1h,
        s.window_start_1h,
        s.window_end_1h
    FROM quotes_1h AS q
    JOIN symbol_stats AS s
        ON s.symbol_id = q.symbol_id
    GROUP BY
        q.symbol_id,
        q.symbol,
        s.avg_spread_bps_1h,
        s.p95_spread_bps_1h,
        s.spike_threshold_bps,
        s.quote_count_1h,
        s.window_start_1h,
        s.window_end_1h
)
SELECT
    symbol_id,
    symbol,
    RANK() OVER (ORDER BY avg_spread_bps_1h ASC NULLS LAST)::INTEGER AS liquidity_rank,
    avg_spread_bps_1h,
    p95_spread_bps_1h,
    spike_threshold_bps,
    pct_time_above_2x_avg,
    quote_count_1h,
    window_start_1h::TIMESTAMP WITHOUT TIME ZONE,
    window_end_1h::TIMESTAMP WITHOUT TIME ZONE,
    CURRENT_TIMESTAMP::TIMESTAMP WITHOUT TIME ZONE AS refreshed_at
FROM with_exceedance
ORDER BY liquidity_rank ASC, symbol;

COMMIT;


-- ----------------------------------------------------------------------------
-- Report Q09: Rolling 24h Drawdown & Max Drawdown Point
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS main.rpt_q09 (
    symbol_id                   INTEGER NOT NULL,
    symbol                      VARCHAR(32) NOT NULL,
    candle_time                 TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    close_price                 DOUBLE PRECISION NOT NULL,
    running_peak_price_24h      DOUBLE PRECISION NOT NULL,
    drawdown_pct                DOUBLE PRECISION NOT NULL,
    max_drawdown_pct_24h        DOUBLE PRECISION NOT NULL,
    max_drawdown_time_24h       TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    is_max_drawdown_point       BOOLEAN NOT NULL,
    window_start_24h            TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    window_end_24h              TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    refreshed_at                TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

BEGIN;

DELETE FROM main.rpt_q09;

INSERT INTO main.rpt_q09 (
    symbol_id,
    symbol,
    candle_time,
    close_price,
    running_peak_price_24h,
    drawdown_pct,
    max_drawdown_pct_24h,
    max_drawdown_time_24h,
    is_max_drawdown_point,
    window_start_24h,
    window_end_24h,
    refreshed_at
)
WITH max_ts AS (
    SELECT MAX(open_time) AS latest_time
    FROM main.fact_candle_1m
),
candles_24h AS (
    SELECT
        c.symbol_id,
        d.symbol,
        c.open_time AS candle_time,
        c.high,
        c.low,
        c.close AS close_price,
        m.latest_time
    FROM main.fact_candle_1m AS c
    JOIN main.dim_symbol AS d
        ON d.symbol_id = c.symbol_id
    CROSS JOIN max_ts AS m
    WHERE c.open_time >= m.latest_time - INTERVAL '24 hours'
),
with_peak_dd AS (
    SELECT
        symbol_id,
        symbol,
        candle_time,
        close_price,
        MAX(high) OVER (
            PARTITION BY symbol_id
            ORDER BY candle_time
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS running_peak_price_24h,
        CASE
            WHEN MAX(high) OVER (
                PARTITION BY symbol_id
                ORDER BY candle_time
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) > 0
                THEN ((low - MAX(high) OVER (
                    PARTITION BY symbol_id
                    ORDER BY candle_time
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                )) / MAX(high) OVER (
                    PARTITION BY symbol_id
                    ORDER BY candle_time
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                )) * 100.0
            ELSE 0.0
        END AS drawdown_pct,
        latest_time
    FROM candles_24h
),
with_max_dd AS (
    SELECT
        symbol_id,
        symbol,
        candle_time,
        close_price,
        running_peak_price_24h,
        drawdown_pct,
        MIN(drawdown_pct) OVER (PARTITION BY symbol_id) AS max_drawdown_pct_24h,
        ROW_NUMBER() OVER (
            PARTITION BY symbol_id
            ORDER BY drawdown_pct ASC, candle_time ASC
        ) AS dd_rank,
        latest_time
    FROM with_peak_dd
),
max_dd_time AS (
    SELECT
        symbol_id,
        candle_time AS max_drawdown_time_24h
    FROM with_max_dd
    WHERE dd_rank = 1
)
SELECT
    w.symbol_id,
    w.symbol,
    w.candle_time,
    w.close_price,
    w.running_peak_price_24h,
    w.drawdown_pct,
    w.max_drawdown_pct_24h,
    mdt.max_drawdown_time_24h,
    (w.dd_rank = 1) AS is_max_drawdown_point,
    (w.latest_time - INTERVAL '24 hours')::TIMESTAMP WITHOUT TIME ZONE AS window_start_24h,
    w.latest_time::TIMESTAMP WITHOUT TIME ZONE AS window_end_24h,
    CURRENT_TIMESTAMP::TIMESTAMP WITHOUT TIME ZONE AS refreshed_at
FROM with_max_dd AS w
JOIN max_dd_time AS mdt
    ON mdt.symbol_id = w.symbol_id
ORDER BY w.symbol, w.candle_time;

COMMIT;


-- ----------------------------------------------------------------------------
-- Report Q10: Pipeline Health, Freshness & Completeness
-- ----------------------------------------------------------------------------
BEGIN;

DELETE FROM main.rpt_q10;

INSERT INTO main.rpt_q10 (
    symbol_id,
    symbol,
    source_table,
    latest_data_timestamp,
    minutes_since_last_update,
    missing_candles_24h,
    duplicate_rows_in_staging,
    staging_rows_total,
    main_rows_total,
    latest_batch_id,
    latest_batch_rows,
    health_status,
    refreshed_at
)
WITH ref_clock AS (
    SELECT GREATEST(
        COALESCE((SELECT MAX(open_time) FROM main.fact_candle_1m), TIMESTAMP '1970-01-01 00:00:00'),
        COALESCE((SELECT MAX(trade_time) FROM main.fact_trade), TIMESTAMP '1970-01-01 00:00:00'),
        COALESCE((SELECT MAX(snapshot_time) FROM main.fact_ticker_snapshot), TIMESTAMP '1970-01-01 00:00:00'),
        COALESCE((SELECT MAX(quote_time) FROM main.fact_quote), TIMESTAMP '1970-01-01 00:00:00')
    ) AS anchor_time
),
candle_bounds AS (
    SELECT
        d.symbol_id,
        d.symbol,
        MIN(c.open_time) AS min_open_time,
        MAX(c.open_time) AS max_open_time,
        COUNT(c.open_time)::INTEGER AS main_rows
    FROM main.dim_symbol AS d
    LEFT JOIN main.fact_candle_1m AS c
        ON c.symbol_id = d.symbol_id
    GROUP BY d.symbol_id, d.symbol
),
expected_minutes_24h AS (
    SELECT
        cb.symbol_id,
        cb.symbol,
        DATE_TRUNC('minute', gs)::TIMESTAMP WITHOUT TIME ZONE AS expected_minute
    FROM candle_bounds AS cb
    CROSS JOIN ref_clock AS rc
    CROSS JOIN LATERAL GENERATE_SERIES(
        DATE_TRUNC('minute', GREATEST(cb.min_open_time, rc.anchor_time - INTERVAL '24 hours')),
        DATE_TRUNC('minute', cb.max_open_time),
        INTERVAL '1 minute'
    ) AS gs
    WHERE cb.max_open_time IS NOT NULL
),
missing_candles AS (
    SELECT
        em.symbol_id,
        COUNT(*)::INTEGER AS missing_candles_24h
    FROM expected_minutes_24h AS em
    LEFT JOIN main.fact_candle_1m AS c
        ON c.symbol_id = em.symbol_id
       AND DATE_TRUNC('minute', c.open_time) = em.expected_minute
    WHERE c.open_time IS NULL
    GROUP BY em.symbol_id
),
stg_klines_stats AS (
    SELECT
        d.symbol_id,
        COUNT(s.*)::INTEGER AS stg_rows,
        GREATEST(
            COUNT(s.*)::INTEGER - COUNT(DISTINCT (s.symbol, s.open_time::BIGINT)),
            0
        )::INTEGER AS dup_rows,
        (ARRAY_AGG(s.batch_id ORDER BY s.ingested_at DESC NULLS LAST))[1] AS latest_batch_id
    FROM main.dim_symbol AS d
    LEFT JOIN staging.klines_1m AS s
        ON s.symbol = d.symbol
    GROUP BY d.symbol_id
),
stg_klines_batch_rows AS (
    SELECT
        d.symbol_id,
        COUNT(s.*)::INTEGER AS latest_batch_rows
    FROM main.dim_symbol AS d
    JOIN stg_klines_stats AS st
        ON st.symbol_id = d.symbol_id
    LEFT JOIN staging.klines_1m AS s
        ON s.symbol = d.symbol
       AND s.batch_id IS NOT DISTINCT FROM st.latest_batch_id
    GROUP BY d.symbol_id
),
stg_trades_stats AS (
    SELECT
        d.symbol_id,
        COUNT(s.*)::INTEGER AS stg_rows,
        GREATEST(
            COUNT(s.*)::INTEGER - COUNT(DISTINCT (s.symbol, s.agg_trade_id::BIGINT)),
            0
        )::INTEGER AS dup_rows,
        (ARRAY_AGG(s.batch_id ORDER BY s.ingested_at DESC NULLS LAST))[1] AS latest_batch_id
    FROM main.dim_symbol AS d
    LEFT JOIN staging.agg_trades AS s
        ON s.symbol = d.symbol
    GROUP BY d.symbol_id
),
stg_trades_batch_rows AS (
    SELECT
        d.symbol_id,
        COUNT(s.*)::INTEGER AS latest_batch_rows
    FROM main.dim_symbol AS d
    JOIN stg_trades_stats AS st
        ON st.symbol_id = d.symbol_id
    LEFT JOIN staging.agg_trades AS s
        ON s.symbol = d.symbol
       AND s.batch_id IS NOT DISTINCT FROM st.latest_batch_id
    GROUP BY d.symbol_id
),
stg_ticker_stats AS (
    SELECT
        d.symbol_id,
        COUNT(s.*)::INTEGER AS stg_rows,
        GREATEST(
            COUNT(s.*)::INTEGER - COUNT(DISTINCT (s.symbol, COALESCE(TO_TIMESTAMP(s.close_time::BIGINT / 1000.0), s.ingested_at)::TIMESTAMP WITHOUT TIME ZONE)),
            0
        )::INTEGER AS dup_rows,
        (ARRAY_AGG(s.batch_id ORDER BY s.ingested_at DESC NULLS LAST))[1] AS latest_batch_id
    FROM main.dim_symbol AS d
    LEFT JOIN staging.ticker_24hr AS s
        ON s.symbol = d.symbol
    GROUP BY d.symbol_id
),
stg_ticker_batch_rows AS (
    SELECT
        d.symbol_id,
        COUNT(s.*)::INTEGER AS latest_batch_rows
    FROM main.dim_symbol AS d
    JOIN stg_ticker_stats AS st
        ON st.symbol_id = d.symbol_id
    LEFT JOIN staging.ticker_24hr AS s
        ON s.symbol = d.symbol
       AND s.batch_id IS NOT DISTINCT FROM st.latest_batch_id
    GROUP BY d.symbol_id
),
stg_quote_stats AS (
    SELECT
        d.symbol_id,
        COUNT(s.*)::INTEGER AS stg_rows,
        GREATEST(
            COUNT(s.*)::INTEGER - COUNT(DISTINCT (s.symbol, s.ingested_at::TIMESTAMP WITHOUT TIME ZONE)),
            0
        )::INTEGER AS dup_rows,
        (ARRAY_AGG(s.batch_id ORDER BY s.ingested_at DESC NULLS LAST))[1] AS latest_batch_id
    FROM main.dim_symbol AS d
    LEFT JOIN staging.book_ticker AS s
        ON s.symbol = d.symbol
    GROUP BY d.symbol_id
),
stg_quote_batch_rows AS (
    SELECT
        d.symbol_id,
        COUNT(s.*)::INTEGER AS latest_batch_rows
    FROM main.dim_symbol AS d
    JOIN stg_quote_stats AS st
        ON st.symbol_id = d.symbol_id
    LEFT JOIN staging.book_ticker AS s
        ON s.symbol = d.symbol
       AND s.batch_id IS NOT DISTINCT FROM st.latest_batch_id
    GROUP BY d.symbol_id
),
main_trade_stats AS (
    SELECT
        symbol_id,
        MAX(trade_time) AS max_ts,
        COUNT(*)::INTEGER AS main_rows
    FROM main.fact_trade
    GROUP BY symbol_id
),
main_ticker_stats AS (
    SELECT
        symbol_id,
        MAX(snapshot_time) AS max_ts,
        COUNT(*)::INTEGER AS main_rows
    FROM main.fact_ticker_snapshot
    GROUP BY symbol_id
),
main_quote_stats AS (
    SELECT
        symbol_id,
        MAX(quote_time) AS max_ts,
        COUNT(*)::INTEGER AS main_rows
    FROM main.fact_quote
    GROUP BY symbol_id
),
unioned AS (
    SELECT
        d.symbol_id,
        d.symbol,
        'fact_candle_1m'::VARCHAR(64) AS source_table,
        cb.max_open_time AS latest_data_timestamp,
        EXTRACT(EPOCH FROM (rc.anchor_time - cb.max_open_time)) / 60.0 AS minutes_since_last_update,
        COALESCE(mc.missing_candles_24h, 0)::INTEGER AS missing_candles_24h,
        COALESCE(sk.dup_rows, 0)::INTEGER AS duplicate_rows_in_staging,
        COALESCE(sk.stg_rows, 0)::INTEGER AS staging_rows_total,
        COALESCE(cb.main_rows, 0)::INTEGER AS main_rows_total,
        sk.latest_batch_id,
        COALESCE(skb.latest_batch_rows, 0)::INTEGER AS latest_batch_rows
    FROM main.dim_symbol AS d
    CROSS JOIN ref_clock AS rc
    LEFT JOIN candle_bounds AS cb ON cb.symbol_id = d.symbol_id
    LEFT JOIN missing_candles AS mc ON mc.symbol_id = d.symbol_id
    LEFT JOIN stg_klines_stats AS sk ON sk.symbol_id = d.symbol_id
    LEFT JOIN stg_klines_batch_rows AS skb ON skb.symbol_id = d.symbol_id

    UNION ALL

    SELECT
        d.symbol_id,
        d.symbol,
        'fact_trade'::VARCHAR(64) AS source_table,
        mt.max_ts AS latest_data_timestamp,
        EXTRACT(EPOCH FROM (rc.anchor_time - mt.max_ts)) / 60.0 AS minutes_since_last_update,
        0::INTEGER AS missing_candles_24h,
        COALESCE(st.dup_rows, 0)::INTEGER AS duplicate_rows_in_staging,
        COALESCE(st.stg_rows, 0)::INTEGER AS staging_rows_total,
        COALESCE(mt.main_rows, 0)::INTEGER AS main_rows_total,
        st.latest_batch_id,
        COALESCE(stb.latest_batch_rows, 0)::INTEGER AS latest_batch_rows
    FROM main.dim_symbol AS d
    CROSS JOIN ref_clock AS rc
    LEFT JOIN main_trade_stats AS mt ON mt.symbol_id = d.symbol_id
    LEFT JOIN stg_trades_stats AS st ON st.symbol_id = d.symbol_id
    LEFT JOIN stg_trades_batch_rows AS stb ON stb.symbol_id = d.symbol_id

    UNION ALL

    SELECT
        d.symbol_id,
        d.symbol,
        'fact_ticker_snapshot'::VARCHAR(64) AS source_table,
        mk.max_ts AS latest_data_timestamp,
        EXTRACT(EPOCH FROM (rc.anchor_time - mk.max_ts)) / 60.0 AS minutes_since_last_update,
        0::INTEGER AS missing_candles_24h,
        COALESCE(sr.dup_rows, 0)::INTEGER AS duplicate_rows_in_staging,
        COALESCE(sr.stg_rows, 0)::INTEGER AS staging_rows_total,
        COALESCE(mk.main_rows, 0)::INTEGER AS main_rows_total,
        sr.latest_batch_id,
        COALESCE(srb.latest_batch_rows, 0)::INTEGER AS latest_batch_rows
    FROM main.dim_symbol AS d
    CROSS JOIN ref_clock AS rc
    LEFT JOIN main_ticker_stats AS mk ON mk.symbol_id = d.symbol_id
    LEFT JOIN stg_ticker_stats AS sr ON sr.symbol_id = d.symbol_id
    LEFT JOIN stg_ticker_batch_rows AS srb ON srb.symbol_id = d.symbol_id

    UNION ALL

    SELECT
        d.symbol_id,
        d.symbol,
        'fact_quote'::VARCHAR(64) AS source_table,
        mq.max_ts AS latest_data_timestamp,
        EXTRACT(EPOCH FROM (rc.anchor_time - mq.max_ts)) / 60.0 AS minutes_since_last_update,
        0::INTEGER AS missing_candles_24h,
        COALESCE(sq.dup_rows, 0)::INTEGER AS duplicate_rows_in_staging,
        COALESCE(sq.stg_rows, 0)::INTEGER AS staging_rows_total,
        COALESCE(mq.main_rows, 0)::INTEGER AS main_rows_total,
        sq.latest_batch_id,
        COALESCE(sqb.latest_batch_rows, 0)::INTEGER AS latest_batch_rows
    FROM main.dim_symbol AS d
    CROSS JOIN ref_clock AS rc
    LEFT JOIN main_quote_stats AS mq ON mq.symbol_id = d.symbol_id
    LEFT JOIN stg_quote_stats AS sq ON sq.symbol_id = d.symbol_id
    LEFT JOIN stg_quote_batch_rows AS sqb ON sqb.symbol_id = d.symbol_id
)
SELECT
    symbol_id,
    symbol,
    source_table,
    latest_data_timestamp,
    minutes_since_last_update,
    missing_candles_24h,
    duplicate_rows_in_staging,
    staging_rows_total,
    main_rows_total,
    latest_batch_id,
    latest_batch_rows,
    CASE
        WHEN latest_data_timestamp IS NULL OR minutes_since_last_update > 15 THEN 'STALE'
        WHEN missing_candles_24h > 0 OR minutes_since_last_update > 5 THEN 'DEGRADED'
        ELSE 'HEALTHY'
    END::VARCHAR(16) AS health_status,
    CURRENT_TIMESTAMP::TIMESTAMP WITHOUT TIME ZONE AS refreshed_at
FROM unioned
ORDER BY symbol, source_table;

COMMIT;



SELECT table_name,
       (xpath('/row/cnt/text()', query_to_xml(format('SELECT count(*) AS cnt FROM main.%I', table_name), false, true, '')))[1]::text::int AS row_count
FROM information_schema.tables
WHERE table_schema = 'main'
  AND table_name LIKE 'rpt_q%'
ORDER BY table_name;

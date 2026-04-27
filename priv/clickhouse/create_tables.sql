-- Kerf telemetry events table for ClickHouse
-- Run against your ClickHouse instance:
--   clickhouse-client --multiquery < priv/clickhouse/create_tables.sql

CREATE DATABASE IF NOT EXISTS kerf_dev;

USE kerf_dev;

CREATE TABLE IF NOT EXISTS kerf_events (
    timestamp            DateTime64(3),
    event_type           LowCardinality(String),
    group_id             String,
    session_id           String,
    latency_ms           UInt32,
    model                LowCardinality(String),
    input_tokens         UInt32,
    output_tokens        UInt32,
    response_type        LowCardinality(String),
    tool_name            LowCardinality(String),
    security_result      LowCardinality(String),
    input_data           String,
    output_data          String,
    error_type           LowCardinality(String),
    error_message        String,
    channel              LowCardinality(String),
    memory_delta_bytes   Int64,
    process_memory_bytes UInt64,
    metadata             String
) ENGINE = MergeTree()
ORDER BY (event_type, group_id, timestamp)
TTL timestamp + INTERVAL 90 DAY;

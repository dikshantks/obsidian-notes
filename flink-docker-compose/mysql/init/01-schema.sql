-- ---------------------------------------------------------------------------
-- MySQL bootstrap for the CDC demo.
--
-- Files in /docker-entrypoint-initdb.d/ are executed once, in alphabetical
-- order, the first time the data directory is initialized (i.e. on a fresh
-- volume). If you change this file, run `docker compose down -v` to wipe the
-- volume so it re-runs.
-- ---------------------------------------------------------------------------

-- Source database that Flink CDC will capture.
CREATE DATABASE IF NOT EXISTS inventory;

USE inventory;

-- The table our Python generator continuously inserts into, and that Flink
-- streams into Iceberg. A primary key is required for CDC upsert semantics.
CREATE TABLE IF NOT EXISTS orders (
    order_id     BIGINT       NOT NULL AUTO_INCREMENT,
    customer     VARCHAR(128) NOT NULL,
    product      VARCHAR(128) NOT NULL,
    quantity     INT          NOT NULL,
    price        DECIMAL(10,2) NOT NULL,
    order_status VARCHAR(32)  NOT NULL DEFAULT 'NEW',
    -- DATETIME (not TIMESTAMP) so Flink CDC maps it to TIMESTAMP(0) rather than
    -- TIMESTAMP_LTZ, matching the column type declared in the Flink SQL job.
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (order_id)
);

-- A couple of seed rows so a query works even before the generator warms up.
INSERT INTO orders (customer, product, quantity, price) VALUES
    ('alice',   'widget', 3, 9.99),
    ('bob',     'gadget', 1, 19.95);

-- ---------------------------------------------------------------------------
-- Dedicated user for Flink CDC.
--
-- Debezium (used under the hood by the MySQL CDC connector) needs to read the
-- binlog and take an initial consistent snapshot, which requires these
-- replication + global-read privileges. mysql_native_password keeps the JDBC
-- handshake simple on MySQL 8.0.
-- ---------------------------------------------------------------------------
CREATE USER IF NOT EXISTS 'flinkcdc'@'%' IDENTIFIED WITH mysql_native_password BY 'flinkcdc';

-- SELECT              : read table data for the initial snapshot
-- RELOAD              : FLUSH TABLES WITH READ LOCK during snapshot
-- SHOW DATABASES      : enumerate databases
-- REPLICATION SLAVE   : read binlog events
-- REPLICATION CLIENT  : SHOW MASTER/BINARY LOG STATUS
GRANT SELECT, RELOAD, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT
    ON *.* TO 'flinkcdc'@'%';

FLUSH PRIVILEGES;

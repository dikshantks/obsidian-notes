-- ===========================================================================
-- Flink SQL job: stream MySQL changes into an Iceberg table cataloged in Nessie.
--
-- Submitted automatically at startup by scripts/submit-flink-job.sh via
-- `sql-client.sh -f`. The final INSERT launches a detached streaming job on the
-- Flink cluster; the SQL client then exits.
-- ===========================================================================

-- --- Execution settings ----------------------------------------------------
-- CRITICAL: the Iceberg sink only commits files to the table on a successful
-- checkpoint. Without checkpointing, data is buffered forever and Trino sees an
-- empty table. 10s gives a snappy demo; raise it for fewer, larger commits.
SET 'execution.checkpointing.interval' = '10s';
SET 'execution.checkpointing.min-pause' = '5s';

-- Keep the streaming job running even if MySQL briefly hiccups.
SET 'restart-strategy' = 'fixed-delay';
SET 'restart-strategy.fixed-delay.attempts' = '2147483647';
SET 'restart-strategy.fixed-delay.delay' = '10s';

-- --- Iceberg catalog backed by Project Nessie (native NessieCatalog) --------
-- We use Nessie's NATIVE catalog client here rather than the Iceberg REST
-- endpoint: Nessie's REST createTable currently NPEs on any schema with
-- identifier fields (i.e. a PRIMARY KEY, which CDC upsert requires). The native
-- client writes Iceberg metadata to MinIO itself and stores only a pointer in
-- Nessie, avoiding that server-side bug. Trino reads the very same tables via
-- Nessie's REST endpoint (its read path works fine).
--   * uri points at the Nessie core API (v2), not the /iceberg/ REST endpoint
--   * ref is the Nessie branch to commit to
--   * io-impl forces S3FileIO (the AWS bundle) so s3:// paths resolve to MinIO
CREATE CATALOG iceberg WITH (
    'type'                 = 'iceberg',
    'catalog-impl'         = 'org.apache.iceberg.nessie.NessieCatalog',
    'io-impl'              = 'org.apache.iceberg.aws.s3.S3FileIO',
    'uri'                  = 'http://nessie:19120/api/v2',
    'ref'                  = 'main',
    'warehouse'            = 's3://warehouse/',
    's3.endpoint'          = 'http://minio:9000',
    's3.path-style-access' = 'true',
    's3.access-key-id'     = 'minioadmin',
    's3.secret-access-key' = 'minioadmin',
    'client.region'        = 'us-east-1'
);

CREATE DATABASE IF NOT EXISTS iceberg.db;

-- --- Source: MySQL CDC ------------------------------------------------------
-- Lives in the default (in-memory) catalog, so we switch back to it to define
-- the source. 'server-id' is a RANGE unique to this Flink source (distinct from
-- the MySQL server's own server-id) — a range enables parallel snapshot reads.
CREATE TABLE default_catalog.default_database.mysql_orders (
    order_id     BIGINT NOT NULL,
    customer     STRING,
    product      STRING,
    quantity     INT,
    price        DECIMAL(10, 2),
    order_status STRING,
    created_at   TIMESTAMP(0),
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'connector'                     = 'mysql-cdc',
    'hostname'                      = 'mysql',
    'port'                          = '3306',
    'username'                      = 'flinkcdc',
    'password'                      = 'flinkcdc',
    'database-name'                 = 'inventory',
    'table-name'                    = 'orders',
    'server-id'                     = '5400-5404',
    'scan.incremental.snapshot.enabled' = 'true',
    'scan.startup.mode'             = 'initial'
);

-- --- Sink: Iceberg table (format v2 for CDC upserts) ------------------------
-- format-version=2 + a primary key + upsert lets the sink apply the CDC
-- changelog (inserts/updates/deletes) rather than only appending.
CREATE TABLE IF NOT EXISTS iceberg.db.orders (
    order_id     BIGINT NOT NULL,
    customer     STRING,
    product      STRING,
    quantity     INT,
    price        DECIMAL(10, 2),
    order_status STRING,
    created_at   TIMESTAMP(0),
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'format-version'       = '2',
    'write.upsert.enabled' = 'true'
);

-- --- The streaming job ------------------------------------------------------
INSERT INTO iceberg.db.orders
SELECT order_id, customer, product, quantity, price, order_status, created_at
FROM default_catalog.default_database.mysql_orders;

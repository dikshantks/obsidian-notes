# MySQL → Flink CDC Pipeline → Iceberg (Nessie) → Trino — one-command demo

A fully automated local lakehouse pipeline using **Flink CDC 3.x Pipeline** framework.
`docker compose up` stands up everything, a generator continuously writes orders to MySQL,
Flink streams those changes into an Apache Iceberg table cataloged by **Project Nessie**
with data in **MinIO**, and you query the live data from **Trino**. Schema evolution is
automatic — `ALTER TABLE` in MySQL propagates to Iceberg without a restart. No Hive Metastore.

```
   ┌─────────┐   MySQL CDC   ┌──────────────┐  Iceberg sink   ┌──────────────┐
   │  MySQL  │ ────binlog───▶│ Apache Flink │ ───────────────▶│ Nessie       │
   │ (orders)│               │ (2.2 + CDC   │ (native catalog)│ (Iceberg cat)│
   └────▲────┘               │  3.x Pipeline)                 └──────┬───────┘
        │ 1 write/sec (I/U/D)                              metadata + │ data files
   ┌────┴─────┐                                                       ▼
   │ generator│                                            ┌──────────────────┐
   │ (python) │                                            │  MinIO (S3)      │
   └──────────┘                                            │  warehouse/      │
                                                           └──────────┬───────┘
                                                     queries          │
                                                  ┌─────────────────┐ │
                                                  │ Trino (REST cat)│─┘
                                                  └─────────────────┘
```

## Quick start

```bash
docker compose up -d --build      # build Flink image + start everything

docker compose ps                 # wait until services are healthy
                                  # flink-cdc-pipeline-submitter exits 0 once job submitted

# Query the continuously-arriving data from Trino:
docker compose exec trino trino --execute \
  "SELECT count(*) AS n, max(order_id) AS max_id FROM iceberg.db.orders"

# Run it again a few seconds later — the counts keep rising as new orders arrive.
```

Tear down (add `-v` to also wipe the MySQL + MinIO volumes):

```bash
docker compose down -v
```

## What happens on `up`

1. **MySQL** starts with binary logging enabled (ROW mode, FULL row image), and a
   `flinkcdc` replication user is created with `REPLICATION SLAVE, REPLICATION CLIENT`.
   `inventory.orders` table is initialized.
2. **MinIO** starts; `minio-init` creates the `warehouse` bucket and configures it.
3. **Nessie** (0.108.1) starts and exposes both its native Catalog API (`/api/v2`, used
   by Flink for writes) and an Iceberg REST endpoint (`/iceberg/`, used by Trino for reads).
   Both point at `s3://warehouse/` on MinIO.
4. **Flink** JobManager + TaskManager start from a custom image with all connector JARs
   baked in: Iceberg runtime, Flink CDC 3.x Pipeline framework, MySQL CDC, AWS SDK, and
   Nessie client libraries.
5. **generator** begins issuing a random write every second into MySQL — a
   weighted mix of INSERT / UPDATE / DELETE (default 6:3:1) so all three CDC
   paths (upsert and delete) are exercised while the table grows net-positive.
6. **flink-cdc-pipeline-submitter** waits for Flink cluster health + MySQL + Nessie,
   then submits `flink/pipeline/mysql-to-iceberg.yaml` via the CDC Pipeline framework
   and exits. The streaming job (with schema evolution enabled) keeps running on the cluster.
7. **Trino** starts with an Iceberg catalog pointing to Nessie's REST endpoint + MinIO.

## Endpoints

| Service      | URL                              | Credentials              |
|--------------|----------------------------------|--------------------------|
| Flink UI     | http://localhost:8081            | —                        |
| Trino        | http://localhost:8080            | user `trino` (no auth)   |
| MinIO console| http://localhost:9001            | `minioadmin`/`minioadmin`|
| Nessie API   | http://localhost:19120/api/v2/config | —                   |
| MySQL        | localhost:3306                   | `root`/`rootpw`          |

## Version matrix

The stack now runs on **Flink 2.2** with the **Flink CDC 3.x Pipeline framework**. The
Iceberg Flink runtime (1.11.0) includes a 2.1 module that is forward-compatible with
Flink 2.2 — there is no 2.2-specific variant in Iceberg 1.11.0. All components are
mutually compatible on this version.

| Component | Version |
|-----------|---------|
| **Flink** | 2.2.1-java21 |
| **Iceberg** | 1.11.0 (Flink runtime: 2.1) |
| **Flink CDC Pipeline** | 3.6.0-2.2 |
| **MySQL CDC Connector** | 3.6.0-2.2 |
| **MySQL Driver** | 8.4.0 |
| **MySQL** | 8.0 |
| **Nessie** | 0.108.1 |
| **Trino** | 482 |

All Docker images are multi-arch (`amd64` + `arm64`); JARs are architecture-neutral.
Edit `.env` to bump any versions — rebuild with `docker compose build --no-cache jobmanager`.

## Project layout

```
.
├── docker-compose.yml              # all services, health checks, dependencies, volumes
├── .env                            # versions + credentials (single source of truth)
├── mysql/
│   ├── conf.d/my.cnf               # binlog: server-id, log-bin, ROW, FULL row image
│   └── init/01-schema.sql          # inventory db, orders table, flinkcdc user
├── flink/
│   ├── Dockerfile                  # Flink 2.2 + all connector + Nessie client JARs
│   ├── pipeline/mysql-to-iceberg.yaml  # CDC Pipeline YAML: source, sink, schema evolution
│   └── scripts/submit-cdc-pipeline.sh  # submitter: waits for cluster, submits pipeline
├── trino/
│   └── catalog/iceberg.properties  # Iceberg REST catalog → Nessie + MinIO
├── generator/
│   ├── Dockerfile
│   ├── requirements.txt
│   └── generate.py                 # 1 random write/sec: weighted INSERT/UPDATE/DELETE
└── README.md
```

## Design notes

- **Flink CDC 3.x Pipeline framework** (`flink-cdc.sh`) submits YAML pipeline definitions
  instead of hand-written Flink jobs, providing unified CDC source/sink connectors and
  automatic schema evolution. The pipeline detects `ALTER TABLE` in MySQL and propagates
  columns/types to Iceberg without restart.
  
- **Flink writes via Nessie native catalog; Trino reads via Nessie REST catalog.**
  Both point at the same Nessie repository + MinIO bucket. Why the split? Nessie 0.108's
  Iceberg REST `createTable` throws `NullPointerException` on schemas with identifier
  fields (i.e., any table with a `PRIMARY KEY`, which CDC upsert requires). The native
  `NessieCatalog` client writes Iceberg metadata client-side, sidestepping that code path.
  Trino's REST *read* path is unaffected, so Trino queries the same tables.
  
- **All JARs baked into the Flink image** (not volume-mounted) — nothing to download by
  hand, and the build fails loudly if a JAR URL is broken. The native Nessie catalog
  requires extra JARs (`iceberg-nessie`, `nessie-client`, `nessie-model`,
  `microprofile-openapi-api`, unshaded Jackson, Hadoop) not bundled in `iceberg-flink-runtime`.
  
- **Checkpointing is mandatory.** The Iceberg sink commits data only at checkpoint
  boundaries. Pipeline YAML sets a 30s interval; without it, Trino sees empty tables forever.
  
- **Classloader isolation:** `classloader.resolve-order=parent-first` (set in Flink config)
  ensures all CDC/connector classes load from the app classloader on both JobManager and
  TaskManager, avoiding `IllegalAccessError` from a split between user-uploaded JARs and
  `/opt/flink/lib/` system JARs.
  
- **Nessie config via `-D` system properties** (in `JAVA_OPTS_APPEND`) rather than env vars,
  avoiding fragile Quarkus key-name mangling for hyphenated/nested settings.
  
- **Generator issues real CRUD, not just inserts.** `generate.py` tracks live
  `order_id`s (seeded from existing rows on startup) and picks INSERT / UPDATE /
  DELETE by weight (`WEIGHT_INSERT` / `WEIGHT_UPDATE` / `WEIGHT_DELETE`, default
  6:3:1, tunable in `docker-compose.yml`). This exercises the CDC upsert and
  delete paths into Iceberg — set `WEIGHT_DELETE=0` for insert/update only.

## Troubleshooting

**Trino shows 0 rows even though the generator is inserting.**
The Iceberg sink only commits at checkpoint boundaries. Wait one interval (~30s) after
the job starts, then query again. Confirm the job is `RUNNING` at http://localhost:8081
and that checkpoints are completing (Flink UI → select the job → Checkpoints tab).

**`flink-cdc-pipeline-submitter` repeatedly restarts or fails to submit.**
Check `docker compose logs flink-cdc-pipeline-submitter`. The submitter waits for:
1. Flink JobManager REST API healthy
2. At least one TaskManager registered with available slots
3. MySQL healthy
4. Nessie healthy

If the TaskManager isn't registering, check `docker compose logs taskmanager` — it must
reach the JobManager at `jobmanager:6123` (Flink RPC address).

**Flink job fails with MySQL CDC permission or binlog errors.**
Ensure binlog settings took effect:
```bash
docker compose exec mysql mysql -uroot -prootpw -e "SHOW VARIABLES LIKE 'binlog_format'"
```
Should show `ROW`. If you edited `mysql/` after first boot, run `docker compose down -v`
— init scripts and my.cnf only apply to a **fresh** data volume. The `flinkcdc` user
(created in `01-schema.sql`) needs `REPLICATION SLAVE, REPLICATION CLIENT` grants.

**`Access Denied` / `NoSuchBucket` / S3 connection errors.**
Check `docker compose logs minio-init` — the `warehouse` bucket must exist. MinIO requires
**path-style** access (configured for Nessie, Flink, and Trino). All three use
`minioadmin`/`minioadmin` and endpoint `http://minio:9000` on the compose network.

**Nessie REST API errors / Trino can't query.**
`docker compose ps` should show `nessie` healthy. Verify Nessie config:
```bash
curl http://localhost:19120/api/v2/config
```
Check the warehouse name in the response matches `warehouse` (Trino's catalog setting).

**`NullPointerException` when Flink creates a table (why native catalog is used).**
Nessie 0.108's REST `createTable` NPEs on schemas with identifier fields (`PRIMARY KEY`).
The CDC Pipeline uses the **native** `NessieCatalog`, which writes metadata client-side
and sidesteps this bug. To reproduce: use REST catalog with a `PRIMARY KEY` table — it fails.
Native catalog succeeds on the same schema. When Nessie fixes this, both can share REST.

**Connector JAR or version incompatibility.**
All connectors must be compatible with the Flink minor version (see version matrix).
If you bump one version in `.env`, bump the full set and rebuild:
```bash
docker compose build --no-cache jobmanager
```

**Schema evolution not happening after `ALTER TABLE` in MySQL.**
The pipeline YAML must have `schema.change.behavior: evolve` (it does by default).
Check `docker compose logs flink-cdc-pipeline-submitter` for submission errors and
the Flink UI for job status. Schema changes are detected and applied automatically
during the next CDC read cycle.

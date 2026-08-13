#!/usr/bin/env python3
"""Continuously mutate orders in MySQL so the CDC pipeline visibly moves.

Every INSERT, UPDATE and DELETE here becomes a binlog event, which Flink CDC
captures and streams into the Iceberg `orders` table (upserts and deletes are
applied via the table's primary key). Connection settings and the operation mix
come from environment variables (see docker-compose.yml) so nothing is hard-coded.
"""
import os
import random
import sys
import time

import pymysql

# --- Configuration from the environment (with sensible local defaults). -------
HOST = os.getenv("MYSQL_HOST", "mysql")
PORT = int(os.getenv("MYSQL_PORT", "3306"))
USER = os.getenv("MYSQL_USER", "root")
PASSWORD = os.getenv("MYSQL_PASSWORD", "rootpw")
DATABASE = os.getenv("MYSQL_DATABASE", "inventory")
INTERVAL = float(os.getenv("GENERATE_INTERVAL_SECONDS", "1.0"))

# Relative frequency of each operation. INSERT is weighted highest so the table
# keeps growing; UPDATE and DELETE exercise the CDC upsert/delete paths. Tune via
# env vars, e.g. WEIGHT_DELETE=0 to never delete.
WEIGHT_INSERT = float(os.getenv("WEIGHT_INSERT", "6"))
WEIGHT_UPDATE = float(os.getenv("WEIGHT_UPDATE", "3"))
WEIGHT_DELETE = float(os.getenv("WEIGHT_DELETE", "1"))

CUSTOMERS = ["alice", "bob", "carol", "dave", "erin", "frank", "grace", "heidi"]
PRODUCTS = ["widget", "gadget", "gizmo", "doohickey", "sprocket", "cog"]
STATUSES = ["NEW", "PAID", "SHIPPED", "DELIVERED", "CANCELLED"]
# REGIONS = ["US-EAST", "US-WEST", "US-CENTRAL", "EU-WEST", "EU-CENTRAL", "APAC", "LATAM"]


def connect_with_retry():
    """MySQL may still be initializing when this container starts; keep retrying."""
    while True:
        try:
            conn = pymysql.connect(
                host=HOST,
                port=PORT,
                user=USER,
                password=PASSWORD,
                database=DATABASE,
                autocommit=True,
            )
            print(f"[generator] connected to {USER}@{HOST}:{PORT}/{DATABASE}", flush=True)
            return conn
        except pymysql.err.OperationalError as exc:
            print(f"[generator] MySQL not ready ({exc}); retrying in 2s...", flush=True)
            time.sleep(2)


def load_live_ids(conn):
    """Seed the set of known order_ids so UPDATE/DELETE can target existing rows
    (including the schema's seed rows) from the very first tick."""
    with conn.cursor() as cur:
        cur.execute("SELECT order_id FROM orders")
        return [row[0] for row in cur.fetchall()]


def do_insert(cur, live_ids):
    """Insert a brand-new random order and remember its id."""
    cur.execute(
        "INSERT INTO orders (customer, product, quantity, price, order_status) "
#       "INSERT INTO orders (customer, product, quantity, price, order_status, regions) "
#       "VALUES (%s, %s, %s, %s, %s, %s)",
        "VALUES (%s, %s, %s, %s, %s)",
        (
            random.choice(CUSTOMERS),
            random.choice(PRODUCTS),
            random.randint(1, 10),
            round(random.uniform(1.0, 500.0), 2),
            random.choice(STATUSES),
            # random.choice(REGIONS),
        ),
    )
    live_ids.append(cur.lastrowid)
    return f"INSERT order_id={cur.lastrowid}"


def do_update(cur, live_ids):
    """Update a random existing order (mutable fields only, never the PK)."""
    order_id = random.choice(live_ids)
    cur.execute(
        "UPDATE orders SET order_status = %s, quantity = %s, price = %s WHERE order_id = %s",
        (
            random.choice(STATUSES),
            random.randint(1, 10),
            round(random.uniform(1.0, 500.0), 2),
            order_id,
        ),
    )
    return f"UPDATE order_id={order_id}"


def do_delete(cur, live_ids):
    """Delete a random existing order and forget its id."""
    order_id = random.choice(live_ids)
    cur.execute("DELETE FROM orders WHERE order_id = %s", (order_id,))
    live_ids.remove(order_id)
    return f"DELETE order_id={order_id}"


def main():
    conn = connect_with_retry()
    live_ids = load_live_ids(conn)
    print(f"[generator] {len(live_ids)} existing order(s) loaded", flush=True)

    counts = {"INSERT": 0, "UPDATE": 0, "DELETE": 0}
    while True:
        # Choose an operation by weight. UPDATE/DELETE need at least one live row;
        # when the table is empty we can only INSERT.
        if live_ids:
            op = random.choices(
                ("INSERT", "UPDATE", "DELETE"),
                weights=(WEIGHT_INSERT, WEIGHT_UPDATE, WEIGHT_DELETE),
            )[0]
        else:
            op = "INSERT"

        try:
            with conn.cursor() as cur:
                if op == "INSERT":
                    detail = do_insert(cur, live_ids)
                elif op == "UPDATE":
                    detail = do_update(cur, live_ids)
                else:
                    detail = do_delete(cur, live_ids)
            counts[op] += 1
            total = sum(counts.values())
            if total % 10 == 0:
                print(
                    f"[generator] {total} ops "
                    f"(insert={counts['INSERT']} update={counts['UPDATE']} "
                    f"delete={counts['DELETE']}); {len(live_ids)} live rows "
                    f"[last: {detail}]",
                    flush=True,
                )
        except pymysql.err.MySQLError as exc:
            # Lost connection (e.g. MySQL restart) — reconnect, reload ids, continue.
            print(f"[generator] {op} failed ({exc}); reconnecting...", flush=True)
            conn = connect_with_retry()
            live_ids = load_live_ids(conn)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)

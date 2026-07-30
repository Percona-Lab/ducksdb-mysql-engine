#!/usr/bin/env bash
# Reproducer for the multi-engine two-phase-commit data-loss bug (fixed in
# v0.2.3). No replication needed: a single server, one transaction that writes to
# BOTH a DuckDB table and an InnoDB table. Two participating engines force real
# 2PC (prepare + commit) - the exact path a replication applier takes, because it
# bundles each data change with an update to the InnoDB replication-position
# tables (mysql.slave_worker_info / relay_log_info).
#
# On a BUGGY build the DuckDB half of the transaction was silently dropped while
# InnoDB and the binlog committed (so InnoDB->DuckDB replication lost every
# write); on a fixed build both halves persist.
#
# Runs entirely in Docker - nothing is installed on the host.
#   scripts/repro-2pc-dataloss.sh
#       -> checks the published :latest image (should PASS on v0.2.3+)
#   IMAGE=perconalab/ducksdb-mysql-engine:9.7-duckdb-v0.2.2 scripts/repro-2pc-dataloss.sh
#       -> point at a pre-fix image to see the bug reproduce (FAIL)
#
# Exit status: 0 = engine correct, 1 = data loss reproduced, 2 = setup error.
set -uo pipefail

IMAGE=${IMAGE:-perconalab/ducksdb-mysql-engine:latest}
C=ducksdb-2pc-repro-$$

cleanup(){ docker rm -f "$C" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

echo "image: $IMAGE"
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "pulling $IMAGE ..."
  docker pull "$IMAGE" >/dev/null || { echo "ERROR: cannot pull $IMAGE"; exit 2; }
}

# A binlog-enabled server: with the binlog as a transaction participant, a
# transaction touching a second engine takes the full 2PC path.
docker run -d --name "$C" "$IMAGE" mysqld \
  --server-id=1 --log-bin=binlog --gtid-mode=ON --enforce-gtid-consistency=ON \
  >/dev/null || { echo "ERROR: cannot start server"; exit 2; }

for _ in $(seq 1 90); do
  docker exec "$C" mysql -uroot -N -B -e "SELECT 1" >/dev/null 2>&1 && break
  sleep 2
done
docker exec "$C" mysql -uroot -N -B -e "SELECT 1" >/dev/null 2>&1 || {
  echo "ERROR: server never became ready"; docker logs --tail 20 "$C"; exit 2; }

Q(){ docker exec "$C" mysql -uroot "$@"; }
cnt(){ docker exec "$C" mysql -uroot -N -B d -e "SELECT COUNT(*) FROM $1" 2>/dev/null | tail -1; }

Q -e "CREATE DATABASE d;
      CREATE TABLE d.duck (id INT PRIMARY KEY, v INT) ENGINE=DuckDB;
      CREATE TABLE d.inno (id INT PRIMARY KEY, v INT) ENGINE=InnoDB;" \
  || { echo "ERROR: schema setup failed"; exit 2; }

rc=0

echo
echo "-- control: DuckDB-only transaction (single engine, 1PC optimization) --"
Q -e "BEGIN; INSERT INTO d.duck VALUES (1,10),(2,20),(3,30); COMMIT;"
c=$(cnt duck)
printf '   DuckDB-only rows: %s/3  %s\n' "${c:-0}" "$([ "${c:-0}" = 3 ] && echo OK || echo FAIL)"
[ "${c:-0}" = 3 ] || rc=1

echo
echo "-- reproducer: DuckDB + InnoDB in ONE transaction (forces full 2PC) --"
Q -e "TRUNCATE d.duck;"
Q -e "BEGIN;
      INSERT INTO d.duck VALUES (4,40),(5,50),(6,60);
      INSERT INTO d.inno VALUES (4,40),(5,50),(6,60);
      COMMIT;"
dc=$(cnt duck); ic=$(cnt inno)
printf '   DuckDB rows: %s/3   InnoDB rows: %s/3\n' "${dc:-0}" "${ic:-0}"

echo
if [ "${dc:-0}" = 3 ] && [ "${ic:-0}" = 3 ]; then
  echo "RESULT: PASS - both engines committed; the 2PC data-loss bug is NOT present."
else
  echo "RESULT: FAIL - mixed-engine 2PC dropped DuckDB rows (${dc:-0}/3 committed)."
  echo "        This is the data-loss bug fixed in v0.2.3 - upgrade the image."
  rc=1
fi
exit "$rc"

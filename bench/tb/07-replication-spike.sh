#!/usr/bin/env bash
# EXPERIMENTAL: InnoDB source -> ENGINE=DuckDB replica.
# Row-based replication is engine-agnostic and this engine implements the row
# APIs and transactions, but there are no replication tests in the tree and
# table_flags() requires a PK for UPDATE/DELETE. Small-scale functional probe
# only; prints a PASS/FAIL verdict.
#   bash 07-replication-spike.sh
#   ROWS=1000000 bash 07-replication-spike.sh

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/config.sh"; . "$HERE/lib.sh"
resolve_sizing
ensure_images

ROWS=${ROWS:-100000}
NET=tb-rpl-net; M=tb-rpl-master; R=tb-rpl-replica
RES="$RESULTS_DIR/replication-spike.txt"
REPL_USER=repl; REPL_PASS='replpass1!'
SPIKE_MEM=${SPIKE_MEM:-8g}; SPIKE_CPUS=${SPIKE_CPUS:-4}

cleanup(){ docker rm -f "$M" "$R" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
docker network create "$NET" >/dev/null 2>&1 || true

pass=0; fail=0
ok(){   printf '  [PASS] %s\n' "$*"; pass=$((pass+1)); }
no(){   printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }

MQ(){ docker exec "$M" mysql -uroot "$@"; }
RQ(){ docker exec "$R" mysql -uroot "$@"; }
wait_up(){ local c=$1 i=0
  until docker exec "$c" mysql -uroot -N -B -e "SELECT 1" 2>/dev/null | grep -q '^1$'; do
    i=$((i+1)); [ "$i" -gt 150 ] && { docker logs --tail 30 "$c" >&2; die "$c never became ready"; }; sleep 2
  done; }

{
echo "================================================================="
echo " Replication spike: InnoDB master -> ENGINE=DuckDB replica"
echo " $(date -u +%FT%TZ)   rows=$ROWS   image=$ENGINE_IMAGE"
echo "================================================================="

# ---- 1. master (InnoDB, ROW binlog, GTID) -----------------------------------
echo; echo "[1/7] starting master (InnoDB, binlog_format=ROW, GTID)"
docker run -d --name "$M" --network "$NET" --cpus "$SPIKE_CPUS" --memory "$SPIKE_MEM" \
  "$ENGINE_IMAGE" mysqld \
  --server-id=1 --log-bin=binlog --binlog-format=ROW \
  --gtid-mode=ON --enforce-gtid-consistency=ON \
  --local-infile=1 >/dev/null || die "cannot start master"
wait_up "$M"; echo "  master up"

# ---- 2. replica -------------------------------------------------------------
echo; echo "[2/7] starting replica"
docker run -d --name "$R" --network "$NET" --cpus "$SPIKE_CPUS" --memory "$SPIKE_MEM" \
  -e DUCKSDB_MEMORY_LIMIT=4GB -e DUCKSDB_TEMP_DIR=/var/lib/mysql \
  "$ENGINE_IMAGE" mysqld \
  --server-id=2 --log-bin=binlog --binlog-format=ROW \
  --gtid-mode=ON --enforce-gtid-consistency=ON \
  --read-only=0 >/dev/null || die "cannot start replica"
wait_up "$R"; echo "  replica up"

# ---- 3. schema --------------------------------------------------------------
# PK is REQUIRED on the replica for UPDATE/DELETE row events (see header).
echo; echo "[3/7] creating schema: InnoDB on master, DuckDB on replica"
DDL="id BIGINT NOT NULL, region INT, amount DECIMAL(12,2), note VARCHAR(64), PRIMARY KEY (id)"
MQ -e "CREATE DATABASE IF NOT EXISTS rpl;"
MQ rpl -e "DROP TABLE IF EXISTS t1; CREATE TABLE t1 ($DDL) ENGINE=InnoDB;" \
  && echo "  master  t1 ENGINE=InnoDB" || die "master DDL failed"
RQ -e "CREATE DATABASE IF NOT EXISTS rpl;"
if RQ rpl -e "DROP TABLE IF EXISTS t1; CREATE TABLE t1 ($DDL) ENGINE=DuckDB;" 2>/tmp/rpl-ddl.err; then
  echo "  replica t1 ENGINE=DuckDB"
else
  echo "  replica DDL FAILED:"; sed 's/^/    /' /tmp/rpl-ddl.err
  die "cannot create ENGINE=DuckDB table on the replica - spike stops here"
fi

# ---- 4. wire replication ----------------------------------------------------
echo; echo "[4/7] wiring replication"
MQ -e "CREATE USER IF NOT EXISTS '$REPL_USER'@'%' IDENTIFIED BY '$REPL_PASS';
       GRANT REPLICATION SLAVE ON *.* TO '$REPL_USER'@'%'; FLUSH PRIVILEGES;" \
  || die "cannot create replication user"
# GET_SOURCE_PUBLIC_KEY=1 is needed for caching_sha2_password over a plaintext link.
RQ -e "STOP REPLICA;" >/dev/null 2>&1 || true
RQ -e "CHANGE REPLICATION SOURCE TO
         SOURCE_HOST='$M', SOURCE_PORT=3306,
         SOURCE_USER='$REPL_USER', SOURCE_PASSWORD='$REPL_PASS',
         SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1;" \
  || die "CHANGE REPLICATION SOURCE failed"
RQ -e "START REPLICA;" || die "START REPLICA failed"
sleep 5

repl_status(){ RQ -e "SHOW REPLICA STATUS\G" 2>/dev/null; }
io=$(repl_status | awk -F': *' '/Replica_IO_Running/{print $2; exit}')
sql=$(repl_status | awk -F': *' '/Replica_SQL_Running:/{print $2; exit}')
echo "  Replica_IO_Running=$io  Replica_SQL_Running=$sql"
if [ "$io" = "Yes" ] && [ "$sql" = "Yes" ]; then ok "replication threads running"
else
  no "replication threads not running"
  repl_status | grep -E 'Last_IO_Error|Last_SQL_Error|Last_Error' | sed 's/^/    /'
fi

# ---- 5. INSERT --------------------------------------------------------------
echo; echo "[5/7] INSERT replication"
MQ rpl -e "INSERT INTO t1 VALUES (1,10,100.00,'a'),(2,20,200.00,'b'),(3,30,300.00,'c');"
sleep 5
got=$(RQ -N -B rpl -e "SELECT COUNT(*) FROM t1" 2>/dev/null | tail -1)
[ "${got:-0}" = 3 ] && ok "3 inserted rows arrived on the DuckDB replica" || no "expected 3 rows on replica, got '${got:-none}'"

# ---- 6. UPDATE / DELETE (the PK-dependent paths) ----------------------------
echo; echo "[6/7] UPDATE / DELETE replication (needs PK on replica)"
MQ rpl -e "UPDATE t1 SET amount=999.99 WHERE id=2;"
sleep 4
val=$(RQ -N -B rpl -e "SELECT amount FROM t1 WHERE id=2" 2>/dev/null | tail -1)
case "$val" in 999.99*) ok "UPDATE replicated (id=2 -> $val)";; *) no "UPDATE not replicated (id=2 = '${val:-none}')";; esac

MQ rpl -e "DELETE FROM t1 WHERE id=3;"
sleep 4
got=$(RQ -N -B rpl -e "SELECT COUNT(*) FROM t1" 2>/dev/null | tail -1)
[ "${got:-0}" = 2 ] && ok "DELETE replicated (2 rows remain)" || no "DELETE not replicated (count='${got:-none}')"

err=$(repl_status | awk -F': *' '/Last_SQL_Error:/{print $2; exit}')
[ -n "${err// /}" ] && { echo "  Last_SQL_Error: $err"; no "replica SQL thread reported an error"; }

# ---- 7. apply throughput ----------------------------------------------------
echo; echo "[7/7] apply throughput: $ROWS rows inserted on the master"
MQ rpl -e "CREATE TABLE IF NOT EXISTS t2 (id BIGINT NOT NULL, v INT, PRIMARY KEY (id)) ENGINE=InnoDB;"
RQ rpl -e "CREATE TABLE IF NOT EXISTS t2 (id BIGINT NOT NULL, v INT, PRIMARY KEY (id)) ENGINE=DuckDB;" >/dev/null 2>&1
t0=$(date +%s)
MQ rpl -e "INSERT INTO t2 (id,v) WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<$ROWS) SELECT n, n%1000 FROM s;" \
  2>/tmp/rpl-bulk.err || { echo "  bulk insert on master failed:"; sed 's/^/    /' /tmp/rpl-bulk.err; }
t1=$(date +%s)
echo "  master insert of $ROWS rows: $((t1-t0))s"

# wait for the replica to catch up
target=$ROWS; i=0; got=0
while [ "$i" -lt 180 ]; do
  got=$(RQ -N -B rpl -e "SELECT COUNT(*) FROM t2" 2>/dev/null | tail -1); got=${got:-0}
  [ "$got" -ge "$target" ] && break
  i=$((i+1)); sleep 2
done
t2=$(date +%s)
lag=$((t2-t1))
if [ "$got" -ge "$target" ]; then
  ok "replica applied all $ROWS rows"
  awk -v r="$ROWS" -v s="$lag" 'BEGIN{ if(s<=0) s=1; printf "  apply throughput: ~%.0f rows/s (caught up %ds after the master finished)\n", r/s, s }'
else
  no "replica applied only $got/$ROWS rows within $((i*2))s"
  repl_status | grep -E 'Seconds_Behind_Source|Last_SQL_Error' | sed 's/^/    /'
fi

echo
echo "================================================================="
echo " VERDICT: PASS=$pass  FAIL=$fail"
if [ "$fail" -eq 0 ]; then
  echo " InnoDB master -> ENGINE=DuckDB replica WORKS for insert/update/delete."
  echo " Caveats before relying on it:"
  echo "   * replica tables need a PRIMARY KEY (UPDATE/DELETE row events)."
  echo "   * apply is row-at-a-time; it will not keep up with a bulk-load master."
  echo "   * this is a functional spike, not a durability or failover test."
else
  echo " Replication into the DuckDB engine did NOT fully work - see failures above."
  echo " Most informative next step: docker logs $R  and  SHOW REPLICA STATUS\\G"
fi
echo "================================================================="
} 2>&1 | tee "$RES"

log "written: $RES"

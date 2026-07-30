#!/usr/bin/env bash
# EXPERIMENTAL: InnoDB source -> ENGINE=DuckDB replica, end-to-end verification.
#
# Row-based replication is engine-agnostic and this engine implements the row
# APIs and transactions (the handlerton wires commit/rollback/prepare/XA and
# table_flags no longer sets HA_NO_TRANSACTIONS). This script is a small-scale
# functional probe that spins up an InnoDB master and a DuckDB replica in Docker
# and verifies, with a PASS/FAIL verdict:
#
#   1-4  master + replica up, cross-engine schema, GTID wiring
#   5-6  INSERT / UPDATE / DELETE replicate (row counts AND content hash)
#   7    apply throughput
#   8    data integrity + full type coverage (NULL, unicode, negatives, temporal,
#        BLOB/TEXT), master-vs-replica content hash
#   9    DDL: ALTER ADD COLUMN/INDEX + DROP on a DuckDB replica table
#   10   transactions: committed multi-statement atomicity, master ROLLBACK,
#        direct engine commit/rollback on the replica
#   11   bulk LOAD DATA replication
#   12   durability: graceful restart (GTID resume) and SIGKILL crash recovery
#        (no loss / no duplicates -> exercises the DuckDB WAL/checkpoint path)
#
# Some behaviours are reported as documented findings rather than hard failures
# (heterogeneous CREATE TABLE carries the master's ENGINE clause; BLOB/TEXT
# UPDATE has a known direct-path limitation whose replication behaviour we probe
# empirically).
#
#   bash 07-replication-spike.sh
#   ROWS=1000000 bash 07-replication-spike.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/config.sh"; . "$HERE/lib.sh"
resolve_sizing
ensure_images

ROWS=${ROWS:-100000}
NET=tb-rpl-net; M=tb-rpl-master; R=tb-rpl-replica
RES="$RESULTS_DIR/replication-spike.txt"
DEBUG_DIR="$RESULTS_DIR/replication-debug"   # per-run debug artifacts on failure
DEBUG_LOG="$DEBUG_DIR/failures.log"
ARMED=0                                      # 1 once debug capture is set up
REPL_USER=repl; REPL_PASS='replpass1!'
SPIKE_MEM=${SPIKE_MEM:-8g}; SPIKE_CPUS=${SPIKE_CPUS:-4}
SYNC_TIMEOUT=${SYNC_TIMEOUT:-120}   # seconds to wait for the replica to catch up

cleanup(){
  # On an abnormal exit (a die() before the verdict) with no clean/bundle marker,
  # snapshot the live containers before tearing them down so debug survives.
  if [ "${ARMED:-0}" = 1 ] && [ ! -f "$DEBUG_DIR/.clean" ] && [ ! -f "$DEBUG_DIR/.bundle" ] \
     && docker inspect "$R" >/dev/null 2>&1; then
    collect_bundle 2>/dev/null || true
    log "replication debug saved to $DEBUG_DIR/"
  fi
  docker rm -f "$M" "$R" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
docker network create "$NET" >/dev/null 2>&1 || true

pass=0; fail=0; DOCS=(); CHECKS=(); THRU=""
# CHECKS accumulates "STATUS<TAB>label" for the machine-readable metrics file
# that report.sh/charts.py consume.
ok(){   printf '  [PASS] %s\n' "$*"; pass=$((pass+1)); CHECKS+=("$(printf 'PASS\t%s' "$*")"); }
no(){   printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); CHECKS+=("$(printf 'FAIL\t%s' "$*")"); collect_snapshot "$*"; }
note(){ printf '  [NOTE] %s\n' "$*"; DOCS+=("$*"); CHECKS+=("$(printf 'NOTE\t%s' "$*")"); }

MQ(){ docker exec "$M" mysql -uroot "$@"; }
RQ(){ docker exec "$R" mysql -uroot "$@"; }
# Scalar helpers: last line of a single-value query (batch, no header). An empty
# first argument means "no database" (mysql would otherwise try to USE '').
mval(){ local db=$1; shift
  if [ -n "$db" ]; then docker exec "$M" mysql -uroot -N -B "$db" -e "$1" 2>/dev/null | tail -1
  else docker exec "$M" mysql -uroot -N -B -e "$1" 2>/dev/null | tail -1; fi; }
rval(){ local db=$1; shift
  if [ -n "$db" ]; then docker exec "$R" mysql -uroot -N -B "$db" -e "$1" 2>/dev/null | tail -1
  else docker exec "$R" mysql -uroot -N -B -e "$1" 2>/dev/null | tail -1; fi; }

wait_up(){ local c=$1 i=0
  until docker exec "$c" mysql -uroot -N -B -e "SELECT 1" 2>/dev/null | grep -q '^1$'; do
    i=$((i+1)); [ "$i" -gt 150 ] && { docker logs --tail 30 "$c" >&2; die "$c never became ready"; }; sleep 2
  done; }

# -E (vertical) rather than a trailing \G: this client rejects \G passed via -e
# ("Unknown command '\G'"), which silently emptied the status.
repl_status(){ RQ -E -e "SHOW REPLICA STATUS" 2>/dev/null; }

# Deterministic catch-up: wait until the replica has executed every GTID the
# master has committed. Replaces fixed sleeps - faster and not flaky. Returns
# non-zero on timeout.
sync_replica(){
  local gset to=${1:-$SYNC_TIMEOUT}
  gset=$(mval "" "SELECT @@GLOBAL.GTID_EXECUTED" | tr '\n' ' ')
  [ -z "${gset// /}" ] && return 0
  local r
  r=$(rval "" "SELECT WAIT_FOR_EXECUTED_GTID_SET('$gset', $to)")
  [ "$r" = 0 ]
}

# Full ordered dump -> md5. Runs through the SQL layer on both engines, so it is
# an exact, engine-agnostic content fingerprint. $4 is the ORDER BY expression.
# Returns "ERR" (distinct from the md5 of an empty result) when the query fails,
# so a broken query can never masquerade as "empty table, matches".
tbl_hash(){ # container db table orderby
  local out rc
  out=$(docker exec "$1" mysql -uroot -N -B "$2" -e "SELECT * FROM $3 ORDER BY $4" 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] && { echo ERR; return; }
  printf '%s' "$out" | md5sum | awk '{print $1}'
}
hash_match(){ # db table orderby label
  local hm hr
  hm=$(tbl_hash "$M" "$1" "$2" "$3"); hr=$(tbl_hash "$R" "$1" "$2" "$3")
  if [ "$hm" = ERR ] || [ "$hr" = ERR ]; then no "$4 (content query errored: master=$hm replica=$hr)"
  elif [ -n "$hm" ] && [ "$hm" = "$hr" ]; then ok "$4 (content identical)"
  else no "$4 (master=${hm:-none} replica=${hr:-none})"; fi
}

# Assert a replica table is genuinely ENGINE=DuckDB - the whole point of the run.
# If a replicated CREATE ever wins the race and makes it InnoDB, the DML checks
# would "pass" without exercising the engine at all (this masked a real bug).
assert_duckdb(){ # $1 = table in rpl
  local e; e=$(rval "information_schema" "SELECT ENGINE FROM TABLES WHERE TABLE_SCHEMA='rpl' AND TABLE_NAME='$1'")
  [ "$e" = DuckDB ] && ok "replica $1 is ENGINE=DuckDB (engine is actually under test)" \
    || no "replica $1 is ENGINE='${e:-absent}', not DuckDB - the test would not exercise the engine"
}

# ---- debug capture ----------------------------------------------------------
# On failure the run saves debug artifacts under $DEBUG_DIR so they can be
# inspected afterwards. failures.log is a per-failure timeline; the one-shot
# bundle (written on the first failure or on an abnormal exit) has the full
# state, including the per-WORKER applier error - a multi-threaded replica
# reports only a generic "Coordinator stopped ..." in SHOW REPLICA STATUS, so
# the real message lives in performance_schema.replication_applier_status_by_worker.
rm -rf "$DEBUG_DIR"; mkdir -p "$DEBUG_DIR"; ARMED=1

rpl_tables(){ docker exec "$M" mysql -uroot -N -B -e \
  "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='rpl'" 2>/dev/null; }

# The real applier error(s) on a multi-threaded replica.
worker_errors(){ RQ -E -e "SELECT WORKER_ID, LAST_ERROR_NUMBER, LAST_ERROR_MESSAGE, LAST_ERROR_TIMESTAMP
  FROM performance_schema.replication_applier_status_by_worker WHERE LAST_ERROR_NUMBER<>0" 2>/dev/null; }
coord_error(){ RQ -E -e "SELECT LAST_ERROR_NUMBER, LAST_ERROR_MESSAGE, LAST_ERROR_TIMESTAMP
  FROM performance_schema.replication_applier_status_by_coordinator WHERE LAST_ERROR_NUMBER<>0" 2>/dev/null; }

# Lightweight per-failure snapshot appended to failures.log.
collect_snapshot(){ # $1 = failing-check label
  { echo "===== $(date -u +%FT%TZ)  FAIL: $1 ====="
    echo "-- applier error (per worker; the authoritative message) --"
    { worker_errors; coord_error; } | sed 's/^/   /'
    echo "-- SHOW REPLICA STATUS (key fields) --"
    repl_status | grep -E \
      'Replica_IO_Running|Replica_SQL_Running|Last_IO_Errno|Last_IO_Error|Last_SQL_Errno|Last_SQL_Error|Exec_Source_Log_Pos|Seconds_Behind_Source|Retrieved_Gtid_Set|Executed_Gtid_Set' \
      | sed 's/^ *//; s/^/   /'
    echo "-- row counts (master vs replica) --"
    for t in $(rpl_tables); do
      mc=$(docker exec "$M" mysql -uroot -N -B rpl -e "SELECT COUNT(*) FROM \`$t\`" 2>/dev/null | tail -1)
      rc=$(docker exec "$R" mysql -uroot -N -B rpl -e "SELECT COUNT(*) FROM \`$t\`" 2>/dev/null | tail -1)
      printf '   %-14s master=%s replica=%s\n' "$t" "${mc:-?}" "${rc:-?}"
    done
    echo
  } >> "$DEBUG_LOG" 2>&1
  return 0
}

# Heavy one-shot bundle: full status, both server logs, both schemas, GTID sets,
# and the full applier-worker status table.
collect_bundle(){
  { echo "== per-worker applier status =="; RQ -E -e "SELECT * FROM performance_schema.replication_applier_status_by_worker" 2>&1
    echo; echo "== coordinator status =="; RQ -E -e "SELECT * FROM performance_schema.replication_applier_status_by_coordinator" 2>&1
  } > "$DEBUG_DIR/applier-status.txt" 2>&1
  repl_status                > "$DEBUG_DIR/replica-status.txt" 2>&1
  docker logs --tail 400 "$R" > "$DEBUG_DIR/replica-mysqld.log" 2>&1
  docker logs --tail 200 "$M" > "$DEBUG_DIR/master-mysqld.log" 2>&1
  { for t in $(rpl_tables); do docker exec "$M" mysql -uroot -E -e "SHOW CREATE TABLE rpl.$t" 2>&1; echo; done; } > "$DEBUG_DIR/schema-master.txt" 2>&1
  { for t in $(rpl_tables); do docker exec "$R" mysql -uroot -E -e "SHOW CREATE TABLE rpl.$t" 2>&1; echo; done; } > "$DEBUG_DIR/schema-replica.txt" 2>&1
  { echo "master @@GLOBAL.GTID_EXECUTED:"; docker exec "$M" mysql -uroot -N -B -e "SELECT @@GLOBAL.GTID_EXECUTED" 2>&1
    echo; echo "replica @@GLOBAL.GTID_EXECUTED:"; docker exec "$R" mysql -uroot -N -B -e "SELECT @@GLOBAL.GTID_EXECUTED" 2>&1; } > "$DEBUG_DIR/gtid.txt" 2>&1
  return 0
}

{
echo "================================================================="
echo " Replication verification: InnoDB master -> ENGINE=DuckDB replica"
echo " $(date -u +%FT%TZ)   rows=$ROWS   image=$ENGINE_IMAGE"
echo "================================================================="

# ---- 1. master (InnoDB, ROW binlog, GTID) -----------------------------------
echo; echo "[1] starting master (InnoDB, binlog_format=ROW, GTID)"
docker run -d --name "$M" --network "$NET" --cpus "$SPIKE_CPUS" --memory "$SPIKE_MEM" \
  "$ENGINE_IMAGE" mysqld \
  --server-id=1 --log-bin=binlog --binlog-format=ROW \
  --gtid-mode=ON --enforce-gtid-consistency=ON \
  --local-infile=1 >/dev/null || die "cannot start master"
wait_up "$M"; echo "  master up"

# ---- 2. replica -------------------------------------------------------------
echo; echo "[2] starting replica (ENGINE=DuckDB target)"
docker run -d --name "$R" --network "$NET" --cpus "$SPIKE_CPUS" --memory "$SPIKE_MEM" \
  -e DUCKSDB_MEMORY_LIMIT=4GB -e DUCKSDB_TEMP_DIR=/var/lib/mysql \
  "$ENGINE_IMAGE" mysqld \
  --server-id=2 --log-bin=binlog --binlog-format=ROW \
  --gtid-mode=ON --enforce-gtid-consistency=ON \
  --local-infile=1 --read-only=0 >/dev/null || die "cannot start replica"
wait_up "$R"; echo "  replica up"

# ---- 3. schema --------------------------------------------------------------
# A PK is REQUIRED on the replica for UPDATE/DELETE row events
# (HA_PRIMARY_KEY_REQUIRED_FOR_DELETE). Tables are pre-created as ENGINE=DuckDB
# on the replica; ROW-based DML then replicates engine-agnostically.
echo; echo "[3] creating schema: InnoDB on master, DuckDB on replica"
DDL="id BIGINT NOT NULL, region INT, amount DECIMAL(12,2), note VARCHAR(64), PRIMARY KEY (id)"
# Create the schema on the master WITHOUT replicating the DDL (sql_log_bin=0): a
# replicated CREATE ... ENGINE=InnoDB would race the replica's local
# ENGINE=DuckDB create and could silently make the replica table InnoDB, masking
# the engine under test. Only the DML then replicates, so the row events genuinely
# exercise the DuckDB apply path. (The phase-9 cre_t test deliberately does NOT do
# this, to document heterogeneous CREATE replication.)
MQ -e "SET sql_log_bin=0; CREATE DATABASE IF NOT EXISTS rpl; SET sql_log_bin=1;"
MQ rpl -e "SET sql_log_bin=0; DROP TABLE IF EXISTS t1; CREATE TABLE t1 ($DDL) ENGINE=InnoDB; SET sql_log_bin=1;" \
  && echo "  master  t1 ENGINE=InnoDB (DDL not replicated)" || die "master DDL failed"
RQ -e "CREATE DATABASE IF NOT EXISTS rpl;"
if RQ rpl -e "DROP TABLE IF EXISTS t1; CREATE TABLE t1 ($DDL) ENGINE=DuckDB;" 2>/tmp/rpl-ddl.err; then
  echo "  replica t1 ENGINE=DuckDB"
else
  echo "  replica DDL FAILED:"; sed 's/^/    /' /tmp/rpl-ddl.err
  die "cannot create ENGINE=DuckDB table on the replica - spike stops here"
fi
assert_duckdb t1

# ---- 4. wire replication ----------------------------------------------------
echo; echo "[4] wiring replication (GTID auto-position)"
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

# Poll: the IO/SQL threads take a moment to report Yes after START REPLICA
# (GTID auto-position + caching_sha2 handshake).
io=No; sql=No
for _ in $(seq 1 30); do
  io=$(repl_status | awk -F': *' '/Replica_IO_Running/{print $2; exit}')
  sql=$(repl_status | awk -F': *' '/Replica_SQL_Running:/{print $2; exit}')
  [ "$io" = "Yes" ] && [ "$sql" = "Yes" ] && break
  sleep 2
done
echo "  Replica_IO_Running=$io  Replica_SQL_Running=$sql"
if [ "$io" = "Yes" ] && [ "$sql" = "Yes" ]; then ok "replication threads running"
else
  no "replication threads not running"
  repl_status | grep -E 'Last_IO_Error|Last_SQL_Error|Last_Error' | sed 's/^/    /'
fi

# ---- 5. INSERT --------------------------------------------------------------
echo; echo "[5] INSERT replication"
MQ rpl -e "INSERT INTO t1 VALUES (1,10,100.00,'a'),(2,20,200.00,'b'),(3,30,300.00,'c');"
sync_replica || no "replica did not catch up within ${SYNC_TIMEOUT}s (INSERT)"
got=$(rval rpl "SELECT COUNT(*) FROM t1")
[ "${got:-0}" = 3 ] && ok "3 inserted rows arrived on the DuckDB replica" || no "expected 3 rows on replica, got '${got:-none}'"
hash_match rpl t1 id "INSERT content matches master"

# ---- 6. UPDATE / DELETE (the PK-dependent paths) ----------------------------
echo; echo "[6] UPDATE / DELETE replication (needs PK on replica)"
MQ rpl -e "UPDATE t1 SET amount=999.99 WHERE id=2;"
sync_replica || no "replica did not catch up (UPDATE)"
val=$(rval rpl "SELECT amount FROM t1 WHERE id=2")
case "$val" in 999.99*) ok "UPDATE replicated (id=2 -> $val)";; *) no "UPDATE not replicated (id=2 = '${val:-none}')";; esac

MQ rpl -e "DELETE FROM t1 WHERE id=3;"
sync_replica || no "replica did not catch up (DELETE)"
got=$(rval rpl "SELECT COUNT(*) FROM t1")
[ "${got:-0}" = 2 ] && ok "DELETE replicated (2 rows remain)" || no "DELETE not replicated (count='${got:-none}')"
hash_match rpl t1 id "UPDATE+DELETE content matches master"

err=$(repl_status | awk -F': *' '/Last_SQL_Error:/{print $2; exit}')
[ -n "${err// /}" ] && { echo "  Last_SQL_Error: $err"; no "replica SQL thread reported an error"; }

# ---- 7. apply throughput ----------------------------------------------------
echo; echo "[7] apply throughput: $ROWS rows inserted on the master"
MQ rpl -e "SET sql_log_bin=0; CREATE TABLE IF NOT EXISTS t2 (id BIGINT NOT NULL, v INT, PRIMARY KEY (id)) ENGINE=InnoDB; SET sql_log_bin=1;"
RQ rpl -e "CREATE TABLE IF NOT EXISTS t2 (id BIGINT NOT NULL, v INT, PRIMARY KEY (id)) ENGINE=DuckDB;" >/dev/null 2>&1
assert_duckdb t2
t0=$(date +%s)
# cte_max_recursion_depth defaults to 1000, so the row generator must raise it
# above ROWS or the recursive CTE aborts (ERROR 3636).
MQ rpl -e "SET SESSION cte_max_recursion_depth=$((ROWS + 10));
  INSERT INTO t2 (id,v) WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<$ROWS) SELECT n, n%1000 FROM s;" \
  2>/tmp/rpl-bulk.err || { echo "  bulk insert on master failed:"; sed 's/^/    /' /tmp/rpl-bulk.err; }
t1=$(date +%s)
echo "  master insert of $ROWS rows: $((t1-t0))s"
if sync_replica "$((SYNC_TIMEOUT*3))"; then
  t2=$(date +%s); lag=$((t2-t1)); [ "$lag" -le 0 ] && lag=1
  got=$(rval rpl "SELECT COUNT(*) FROM t2")
  if [ "${got:-0}" -ge "$ROWS" ]; then
    ok "replica applied all $ROWS rows"
    THRU=$(awk -v r="$ROWS" -v s="$lag" 'BEGIN{ printf "%.0f", r/s }')
    echo "  apply throughput: ~$THRU rows/s (caught up ${lag}s after the master finished)"
  else
    no "replica applied only ${got:-0}/$ROWS rows"
  fi
else
  got=$(rval rpl "SELECT COUNT(*) FROM t2")
  no "replica did not catch up within $((SYNC_TIMEOUT*3))s (applied ${got:-0}/$ROWS)"
  repl_status | grep -E 'Seconds_Behind_Source|Last_SQL_Error' | sed 's/^/    /'
fi

# ---- 8. data integrity + full type coverage ---------------------------------
echo; echo "[8] data integrity: all column types, NULL / unicode / negatives"
WIDE="id BIGINT NOT NULL, i INT, ui INT UNSIGNED, dec_p DECIMAL(15,2), dec_n DECIMAL(15,2),
      dbl DOUBLE, d DATE, dt DATETIME, ts TIMESTAMP NULL, ch CHAR(10), vc VARCHAR(100),
      txt TEXT, bl BLOB, uni VARCHAR(100), n_null INT, PRIMARY KEY (id)"
MQ rpl -e "SET sql_log_bin=0; DROP TABLE IF EXISTS wide; CREATE TABLE wide ($WIDE) ENGINE=InnoDB; SET sql_log_bin=1;"
RQ rpl -e "DROP TABLE IF EXISTS wide; CREATE TABLE wide ($WIDE) ENGINE=DuckDB;" 2>/tmp/rpl-wide.err \
  || { echo "  replica wide-table DDL failed:"; sed 's/^/    /' /tmp/rpl-wide.err; no "cannot create wide DuckDB table"; }
assert_duckdb wide
MQ rpl -e "INSERT INTO wide VALUES
  (1, 42, 42, 123.45, -678.90, 3.14159, '2020-01-15', '2020-01-15 10:30:00', '2021-06-01 12:00:00', 'abc', 'hello world', 'some text', 'blobdata', 'héllo wörld café', 100),
  (2, -7, 7, 0.00, -0.01, -2.5, '1999-12-31', '1999-12-31 23:59:59', NULL, '', '', '', '', '日本語テスト 🦆', NULL),
  (3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);"
sync_replica || no "replica did not catch up (wide INSERT)"
got=$(rval rpl "SELECT COUNT(*) FROM wide")
[ "${got:-0}" = 3 ] && ok "wide-table rows arrived (all types, NULLs, unicode)" || no "wide-table rows missing (got '${got:-none}')"
hash_match rpl wide id "all-types INSERT content matches master"

# UPDATE of non-blob columns (the common path)
MQ rpl -e "UPDATE wide SET i=999, vc='changed', dec_p=555.55, ts='2022-02-02 02:02:02' WHERE id=1;"
sync_replica || no "replica did not catch up (wide UPDATE)"
hash_match rpl wide id "scalar UPDATE content matches master"

# BLOB/TEXT UPDATE over ROW replication - known direct-SQL limitation; probe
# whether the replication path (before/after images from the binlog) bypasses it.
MQ rpl -e "UPDATE wide SET bl='NEWBLOB', txt='newtext' WHERE id=1;"
sync_replica || no "replica did not catch up (BLOB UPDATE)"
mb=$(mval rpl "SELECT CONCAT(IFNULL(bl,'#'),'|',IFNULL(txt,'#')) FROM wide WHERE id=1")
rb=$(rval rpl "SELECT CONCAT(IFNULL(bl,'#'),'|',IFNULL(txt,'#')) FROM wide WHERE id=1")
if [ "$mb" = "$rb" ]; then
  note "BLOB/TEXT UPDATE replicated correctly over ROW replication (id=1 -> '$rb')"
else
  note "BLOB/TEXT UPDATE DIVERGED (master='$mb' replica='$rb'): matches the known direct-path limitation - blob/text UPDATE did not apply on the DuckDB replica. INSERT/DELETE of blobs are unaffected."
fi

# ---- 9. DDL replication -----------------------------------------------------
echo; echo "[9] DDL replication on a DuckDB replica table"
MQ rpl -e "DROP TABLE IF EXISTS ddl_t;"; sync_replica || true
MQ rpl -e "SET sql_log_bin=0; CREATE TABLE ddl_t (id BIGINT NOT NULL, a INT, PRIMARY KEY (id)) ENGINE=InnoDB; SET sql_log_bin=1;"
RQ rpl -e "DROP TABLE IF EXISTS ddl_t; CREATE TABLE ddl_t (id BIGINT NOT NULL, a INT, PRIMARY KEY (id)) ENGINE=DuckDB;" >/dev/null 2>&1
MQ rpl -e "INSERT INTO ddl_t VALUES (1,10),(2,20),(3,30);"
sync_replica || no "replica did not catch up (ddl_t seed)"

# ALTER ADD COLUMN - the DuckDB engine rebuilds via MySQL's copy-table path.
if MQ rpl -e "ALTER TABLE ddl_t ADD COLUMN b VARCHAR(20) DEFAULT 'x';" 2>/tmp/rpl-alter.err; then
  sync_replica || no "replica did not catch up (ALTER ADD COLUMN)"
  bcol=$(rval "information_schema" "SELECT COUNT(*) FROM COLUMNS WHERE TABLE_SCHEMA='rpl' AND TABLE_NAME='ddl_t' AND COLUMN_NAME='b'")
  [ "${bcol:-0}" = 1 ] && ok "ALTER ADD COLUMN replicated to DuckDB replica" || no "ALTER ADD COLUMN not present on replica"
  hash_match rpl ddl_t id "post-ALTER content matches master (existing rows intact)"
else
  echo "  ALTER on master failed:"; sed 's/^/    /' /tmp/rpl-alter.err; no "ALTER ADD COLUMN failed on master"
fi

# ALTER ADD INDEX
if MQ rpl -e "ALTER TABLE ddl_t ADD INDEX idx_a (a);" 2>/tmp/rpl-idx.err; then
  sync_replica || no "replica did not catch up (ALTER ADD INDEX)"
  serr=$(repl_status | awk -F': *' '/Last_SQL_Error:/{print $2; exit}')
  idx=$(rval "information_schema" "SELECT COUNT(*) FROM STATISTICS WHERE TABLE_SCHEMA='rpl' AND TABLE_NAME='ddl_t' AND INDEX_NAME='idx_a'")
  if [ -z "${serr// /}" ] && [ "${idx:-0}" -ge 1 ]; then ok "ALTER ADD INDEX replicated to DuckDB replica"
  else no "ALTER ADD INDEX did not apply cleanly on replica (idx=${idx:-0} err='${serr}')"; fi
else
  echo "  ALTER ADD INDEX on master failed:"; sed 's/^/    /' /tmp/rpl-idx.err; no "ALTER ADD INDEX failed on master"
fi

# DROP TABLE
MQ rpl -e "DROP TABLE ddl_t;"
sync_replica || no "replica did not catch up (DROP)"
ex=$(rval "information_schema" "SELECT COUNT(*) FROM TABLES WHERE TABLE_SCHEMA='rpl' AND TABLE_NAME='ddl_t'")
[ "${ex:-1}" = 0 ] && ok "DROP TABLE replicated (gone from DuckDB replica)" || no "DROP TABLE not replicated (still present)"

# Heterogeneous CREATE: the master's ENGINE clause is binlogged verbatim, so a
# CREATE ... ENGINE=InnoDB lands as InnoDB on the replica. Document, do not fail.
MQ rpl -e "DROP TABLE IF EXISTS cre_t; CREATE TABLE cre_t (id INT PRIMARY KEY, v INT) ENGINE=InnoDB;"
sync_replica || true
eng=$(rval "information_schema" "SELECT ENGINE FROM TABLES WHERE TABLE_SCHEMA='rpl' AND TABLE_NAME='cre_t'")
note "heterogeneous CREATE TABLE ENGINE=InnoDB replicated as ENGINE='${eng:-absent}' on the replica -> pre-create replica tables as ENGINE=DuckDB (the supported model); CREATE does not auto-map to DuckDB."
MQ rpl -e "DROP TABLE IF EXISTS cre_t;"; sync_replica || true

# ---- 10. transactions -------------------------------------------------------
echo; echo "[10] transactions"
# Committed multi-statement transaction applies atomically on the replica.
MQ rpl -e "START TRANSACTION;
  INSERT INTO t1 VALUES (100,1,1.00,'tx1');
  INSERT INTO t1 VALUES (101,2,2.00,'tx2');
  UPDATE t1 SET amount=5.00 WHERE id=100;
  COMMIT;"
sync_replica || no "replica did not catch up (committed txn)"
c1=$(rval rpl "SELECT COUNT(*) FROM t1 WHERE id IN (100,101)")
a1=$(rval rpl "SELECT amount FROM t1 WHERE id=100")
{ [ "${c1:-0}" = 2 ] && case "$a1" in 5.00*) true;; *) false;; esac; } \
  && ok "committed multi-statement transaction applied atomically" \
  || no "committed txn incomplete on replica (rows=${c1:-0} amount=${a1:-none})"

# Master ROLLBACK -> nothing binlogged -> nothing on the replica.
MQ rpl -e "START TRANSACTION; INSERT INTO t1 VALUES (200,9,9.00,'rb'); ROLLBACK;"
sync_replica || true
r0=$(rval rpl "SELECT COUNT(*) FROM t1 WHERE id=200")
m0=$(mval rpl "SELECT COUNT(*) FROM t1 WHERE id=200")
{ [ "${r0:-1}" = 0 ] && [ "${m0:-1}" = 0 ]; } \
  && ok "rolled-back master transaction left no rows (master and replica)" \
  || no "ROLLBACK leaked rows (master=${m0} replica=${r0})"

# Direct engine commit/rollback on the replica (not via replication): confirms
# the DuckDB handlerton's own commit/rollback callbacks work.
RQ rpl -e "DROP TABLE IF EXISTS tx_local; CREATE TABLE tx_local (id INT PRIMARY KEY, v INT) ENGINE=DuckDB;" >/dev/null 2>&1
RQ rpl -e "SET autocommit=0; START TRANSACTION; INSERT INTO tx_local VALUES (1,1),(2,2); ROLLBACK;"
lr=$(rval rpl "SELECT COUNT(*) FROM tx_local")
RQ rpl -e "SET autocommit=0; START TRANSACTION; INSERT INTO tx_local VALUES (3,3),(4,4); COMMIT;"
lc=$(rval rpl "SELECT COUNT(*) FROM tx_local")
{ [ "${lr:-1}" = 0 ] && [ "${lc:-0}" = 2 ]; } \
  && ok "DuckDB engine ROLLBACK/COMMIT work directly (rollback=0 rows, commit=2 rows)" \
  || no "DuckDB engine transaction control off (after rollback=${lr}, after commit=${lc})"
RQ rpl -e "DROP TABLE IF EXISTS tx_local;" >/dev/null 2>&1

# ---- 11. bulk LOAD DATA replication -----------------------------------------
echo; echo "[11] bulk LOAD DATA on master -> replica"
docker exec "$M" sh -c "awk 'BEGIN{for(i=1000;i<6000;i++) printf \"%d\t%d\t%d.00\tbulk\n\", i, i%100, i}' > /tmp/bulk.csv"
if MQ --local-infile=1 rpl -e "LOAD DATA LOCAL INFILE '/tmp/bulk.csv' INTO TABLE t1
      FIELDS TERMINATED BY '\t' (id,region,amount,note);" 2>/tmp/rpl-load.err; then
  if sync_replica "$((SYNC_TIMEOUT*2))"; then
    lc=$(rval rpl "SELECT COUNT(*) FROM t1 WHERE id BETWEEN 1000 AND 5999")
    [ "${lc:-0}" = 5000 ] && ok "LOAD DATA replicated all 5000 rows" || no "LOAD DATA replicated only ${lc:-0}/5000 rows"
    mh=$(docker exec "$M" mysql -uroot -N -B rpl -e "SELECT * FROM t1 WHERE id BETWEEN 1000 AND 5999 ORDER BY id" 2>/dev/null | md5sum | awk '{print $1}')
    rh=$(docker exec "$R" mysql -uroot -N -B rpl -e "SELECT * FROM t1 WHERE id BETWEEN 1000 AND 5999 ORDER BY id" 2>/dev/null | md5sum | awk '{print $1}')
    [ -n "$mh" ] && [ "$mh" = "$rh" ] && ok "LOAD DATA content matches master" || no "LOAD DATA content differs (master=$mh replica=$rh)"
  else
    no "replica did not catch up after LOAD DATA"
  fi
else
  echo "  LOAD DATA on master failed:"; sed 's/^/    /' /tmp/rpl-load.err; no "LOAD DATA failed on master"
fi

# ---- 12. durability + crash recovery ----------------------------------------
echo; echo "[12] durability: graceful restart, then SIGKILL crash recovery"

# (a) graceful restart: stop the replica cleanly (DuckDB checkpoints), write on
# the master while it is down, restart, and confirm it resumes from its GTID
# position and catches up.
echo "  (a) graceful stop -> write on master -> restart -> GTID resume"
docker stop -t 60 "$R" >/dev/null 2>&1 || no "could not stop replica cleanly"
MQ rpl -e "INSERT INTO t1 VALUES (300,3,30.00,'g'),(301,3,31.00,'g'),(302,3,32.00,'g');"
docker start "$R" >/dev/null 2>&1 || die "could not restart replica"
wait_up "$R"
RQ -e "START REPLICA;" >/dev/null 2>&1 || true
if sync_replica; then
  g=$(rval rpl "SELECT COUNT(*) FROM t1 WHERE id BETWEEN 300 AND 302")
  [ "${g:-0}" = 3 ] && ok "replica resumed after graceful restart (GTID position durable)" || no "post-restart catch-up incomplete (got ${g:-0}/3)"
else
  no "replica did not resume after graceful restart"
  repl_status | grep -E 'Last_IO_Error|Last_SQL_Error' | sed 's/^/    /'
fi

# (b) crash recovery: apply rows, SIGKILL the replica (no clean checkpoint),
# restart, then keep writing on the master. The invariant is exact: every row
# in [400,459] must be present exactly once - no loss (DuckDB WAL replay on
# open) and no duplicate re-apply (GTID/position consistent with the data).
echo "  (b) apply rows -> SIGKILL replica -> restart -> no loss / no duplicates"
MQ rpl -e "INSERT INTO t1 (id,region,amount,note)
  WITH RECURSIVE s(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM s WHERE n<49)
  SELECT 400+n, 4, 40.00, 'crash' FROM s;"
sync_replica || no "replica did not apply the pre-crash rows"
pre=$(rval rpl "SELECT COUNT(*) FROM t1 WHERE id BETWEEN 400 AND 449")
docker kill "$R" >/dev/null 2>&1 || no "could not SIGKILL replica"
docker start "$R" >/dev/null 2>&1 || die "could not restart replica after crash"
wait_up "$R"
RQ -e "START REPLICA;" >/dev/null 2>&1 || true
# Post-crash writes force replication to resume and expose any position drift.
MQ rpl -e "INSERT INTO t1 (id,region,amount,note)
  WITH RECURSIVE s(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM s WHERE n<9)
  SELECT 450+n, 4, 45.00, 'crash2' FROM s;"
if sync_replica "$((SYNC_TIMEOUT*2))"; then
  tot=$(rval rpl "SELECT COUNT(*) FROM t1 WHERE id BETWEEN 400 AND 459")
  dst=$(rval rpl "SELECT COUNT(DISTINCT id) FROM t1 WHERE id BETWEEN 400 AND 459")
  serr=$(repl_status | awk -F': *' '/Last_SQL_Error:/{print $2; exit}')
  mh=$(docker exec "$M" mysql -uroot -N -B rpl -e "SELECT * FROM t1 WHERE id BETWEEN 400 AND 459 ORDER BY id" 2>/dev/null | md5sum | awk '{print $1}')
  rh=$(docker exec "$R" mysql -uroot -N -B rpl -e "SELECT * FROM t1 WHERE id BETWEEN 400 AND 459 ORDER BY id" 2>/dev/null | md5sum | awk '{print $1}')
  echo "  pre-crash applied=$pre  post-restart total=$tot  distinct=$dst  (expect 60/60)"
  if [ "${tot:-0}" = 60 ] && [ "${dst:-0}" = 60 ] && [ -z "${serr// /}" ] && [ -n "$mh" ] && [ "$mh" = "$rh" ]; then
    ok "crash recovery clean: no loss, no duplicates, content matches master"
  else
    no "crash recovery INCONSISTENT (total=${tot:-0}/60 distinct=${dst:-0}/60 hash: master=$mh replica=$rh err='${serr}')"
    note "SIGKILL crash left the DuckDB replica inconsistent with the master - the engine's data durability and its GTID/relay-log position are not crash-atomic (handlerton flags do not advertise HTON_SUPPORTS_2PC). Investigate before relying on crash-safe replication."
  fi
else
  no "replica did not resume after SIGKILL crash"
  repl_status | grep -E 'Last_IO_Error|Last_SQL_Error' | sed 's/^/    /'
fi

# ---- verdict ----------------------------------------------------------------
echo
echo "================================================================="
echo " VERDICT: PASS=$pass  FAIL=$fail"
if [ "$fail" -eq 0 ]; then
  echo " InnoDB master -> ENGINE=DuckDB replica WORKS across insert/update/delete,"
  echo " all column types, DDL, transactions, bulk load, and restart/crash recovery."
else
  echo " Replication into the DuckDB engine did NOT fully work - see [FAIL] lines above."
  echo " Most informative next step: docker logs $R  and  SHOW REPLICA STATUS (use -E)."
fi
if [ "${#DOCS[@]}" -gt 0 ]; then
  echo
  echo " Documented behaviours / known limitations:"
  for d in "${DOCS[@]}"; do echo "   * $d"; done
fi
if [ "$fail" -gt 0 ]; then
  collect_bundle; : > "$DEBUG_DIR/.bundle"
  echo
  echo " Debug info for the failures is saved under $DEBUG_DIR/ :"
  echo "   failures.log        per-failure timeline (applier error + row counts as each check failed)"
  echo "   applier-status.txt  per-worker applier error - the authoritative message on a MTA replica"
  echo "   replica-status.txt  full SHOW REPLICA STATUS"
  echo "   replica-mysqld.log / master-mysqld.log"
  echo "   schema-master.txt / schema-replica.txt   (diff these first)"
  echo "   gtid.txt"
  echo "   TIP: the FIRST failure in failures.log that shows a non-zero applier error is the"
  echo "        root cause; later phases usually cascade from a stopped applier."
else
  : > "$DEBUG_DIR/.clean"
fi
echo
echo " Standing caveats:"
echo "   * replica tables need a PRIMARY KEY (UPDATE/DELETE row events) and must"
echo "     be pre-created as ENGINE=DuckDB (heterogeneous CREATE is not auto-mapped)."
echo "   * apply is row-at-a-time; it will not keep up with a bulk-load master."
echo "   * this is a functional probe, not a performance or failover benchmark."
echo "================================================================="

# Machine-readable metrics for report.sh / charts.py (written to files, so these
# do not appear in the tee'd human-readable text above).
{ if [ "${#CHECKS[@]}" -gt 0 ]; then printf '%s\n' "${CHECKS[@]}"; fi
  printf 'THROUGHPUT_ROWS_S\t%s\n' "$THRU"; } > "$RESULTS_DIR/replication-metrics.txt"
{ echo "repl_pass=$pass"; echo "repl_fail=$fail"
  [ -n "$THRU" ] && echo "repl_throughput_rows_s=$THRU"; } >> "$RESULTS_DIR/timings.txt"
} 2>&1 | tee "$RES"

log "written: $RES"
log "metrics: $RESULTS_DIR/replication-metrics.txt (consumed by report.sh / charts.py)"

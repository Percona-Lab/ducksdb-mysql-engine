#!/usr/bin/env bash
# Shared helpers: image bootstrap, server lifecycle, load-format parsing.
# Sourced after config.sh. Only one engine server runs at a time.

ensure_images(){
  local tmpd

  if ! docker image inspect "$ENGINE_IMAGE" >/dev/null 2>&1; then
    log "pulling engine image $ENGINE_IMAGE ..."
    docker pull "$ENGINE_IMAGE" >/dev/null 2>&1 \
      || die "cannot pull $ENGINE_IMAGE - set ENGINE_IMAGE to an image this node can reach"
  fi

  if ! docker image inspect "$DUCKDB_IMAGE" >/dev/null 2>&1; then
    log "building $DUCKDB_IMAGE (native DuckDB CLI v$DUCKDB_CLI_VERSION) ..."
    tmpd=$(mktemp -d)
    cat > "$tmpd/Dockerfile" <<EOF
FROM ubuntu:24.04
ARG DUCKDB_VERSION=$DUCKDB_CLI_VERSION
RUN apt-get update \\
 && apt-get install -y --no-install-recommends ca-certificates curl unzip \\
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/duckdb.zip \\
      "https://github.com/duckdb/duckdb/releases/download/v\${DUCKDB_VERSION}/duckdb_cli-linux-amd64.zip" \\
 && unzip /tmp/duckdb.zip -d /usr/local/bin \\
 && rm /tmp/duckdb.zip \\
 && chmod +x /usr/local/bin/duckdb \\
 && duckdb -c "SELECT 'duckdb ' || version();"
ENTRYPOINT ["sleep", "infinity"]
EOF
    docker build -q -t "$DUCKDB_IMAGE" "$tmpd" >/dev/null || { rm -rf "$tmpd"; die "cannot build $DUCKDB_IMAGE"; }
    rm -rf "$tmpd"
  fi

  if ! docker image inspect "$GEN_IMAGE" >/dev/null 2>&1; then
    log "building $GEN_IMAGE (tpchgen-cli) ..."
    tmpd=$(mktemp -d)
    printf 'FROM python:3.12-slim\nRUN pip install --no-cache-dir tpchgen-cli\n' > "$tmpd/Dockerfile"
    docker build -q -t "$GEN_IMAGE" "$tmpd" >/dev/null || { rm -rf "$tmpd"; die "cannot build $GEN_IMAGE"; }
    rm -rf "$tmpd"
  fi
}

# Charts are rendered in a container too (no host installs). Separate from
# ensure_images because only the reporting step needs it.
ensure_report_image(){
  docker image inspect "$REPORT_IMAGE" >/dev/null 2>&1 && return 0
  log "building $REPORT_IMAGE (matplotlib) ..."
  local tmpd; tmpd=$(mktemp -d)
  printf 'FROM python:3.12-slim\nRUN pip install --no-cache-dir matplotlib\n' > "$tmpd/Dockerfile"
  docker build -q -t "$REPORT_IMAGE" "$tmpd" >/dev/null || { rm -rf "$tmpd"; die "cannot build $REPORT_IMAGE"; }
  rm -rf "$tmpd"
}

container_name(){ echo "tb-$1"; }              # $1 = duckdb|innodb
datadir_for(){ case "$1" in duckdb) echo "$DUCKDB_DATADIR";; innodb) echo "$INNODB_DATADIR";; *) die "unknown engine $1";; esac; }
sql_engine_for(){ case "$1" in duckdb) echo "DuckDB";; innodb) echo "InnoDB";; *) die "unknown engine $1";; esac; }

# Stop and remove every harness container. Called before starting any server so
# we never accidentally run two big engines at once.
# GRACEFUL shutdown matters here. `docker rm -f` SIGKILLs mysqld, which means the
# embedded DuckDB never checkpoints: the data stays in <schema>.duckdb.wal and the
# main file is left near-empty. That would (a) make the storage comparison wrong,
# (b) break NATIVE_MODE=attach, and (c) force a long WAL replay on next start.
# So: SIGTERM and wait for the checkpoint, which after a 1 TB load is not instant.
graceful_stop(){ # $1 = container name
  docker inspect "$1" >/dev/null 2>&1 || return 0
  docker stop -t "${SHUTDOWN_TIMEOUT:-600}" "$1" >/dev/null 2>&1 || true
  docker rm -f "$1" >/dev/null 2>&1 || true
}

stop_all_servers(){
  for e in duckdb innodb; do graceful_stop "$(container_name "$e")"; done
}

# server_start <engine> [extra mysqld args...]
server_start(){
  local eng="$1"; shift
  local name dd
  name=$(container_name "$eng"); dd=$(datadir_for "$eng")
  resolve_sizing
  stop_all_servers
  mkdir -p "$dd" "$TEMP_DIR" || die "cannot create datadir/temp"

  local -a env_args=() mysqld_args=()
  mysqld_args=( mysqld --local-infile=1 --secure-file-priv=/data
                --net-read-timeout=6000 --net-write-timeout=6000 )

  if [ "$eng" = duckdb ]; then
    # Cap the EMBEDDED DuckDB below the container limit so a heavy query spills
    # to disk instead of letting the kernel OOM-kill mysqld.
    env_args=( -e "DUCKSDB_MEMORY_LIMIT=$DUCK_MEM" -e "DUCKSDB_TEMP_DIR=/spill" )
    mysqld_args+=( --skip-log-bin --innodb-buffer-pool-size=2G )
  else
    # InnoDB load/query tuning. flush_log_at_trx_commit=2 and a large pool make
    # the bulk load survivable; they do not change query semantics.
    mysqld_args+=( --innodb-buffer-pool-size="$INNODB_POOL"
                   --innodb-flush-log-at-trx-commit=2
                   --innodb-doublewrite=0
                   --skip-log-bin )
  fi
  mysqld_args+=( "$@" )

  log "starting $eng server ($ENGINE_IMAGE)  cpus=$CPUS mem=$MEM"
  docker run -d --name "$name" \
    --cpus "$CPUS" --memory "$MEM" \
    --ulimit nofile=65536:65536 \
    "${env_args[@]}" \
    -v "$dd":/var/lib/mysql \
    -v "$DATA_DIR":/data:ro \
    -v "$TEMP_DIR":/spill \
    "$ENGINE_IMAGE" "${mysqld_args[@]}" >/dev/null || die "docker run failed for $eng"

  local i=0
  until docker exec "$name" mysql -uroot -N -B -e "SELECT 1" 2>/dev/null | grep -q '^1$'; do
    i=$((i+1))
    if [ "$i" -gt 300 ]; then
      log "server did not become ready; last log lines:"; docker logs --tail 40 "$name" >&2
      die "$eng server never became ready (5 min)"
    fi
    sleep 2
  done
  log "$eng server ready"
}

server_stop(){ graceful_stop "$(container_name "$1")"; }

# Q <engine> [mysql args...]  - run a client command inside the server container
Q(){ local eng="$1"; shift; docker exec "$(container_name "$eng")" mysql -uroot "$@"; }

minv(){ printf '%s\n' "$@" | sort -n | head -1; }
elapsed(){ awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", b-a}'; }

# Locate the ENGINE=DuckDB server's own database file for the tpch schema.
# The engine keeps one <schema>.duckdb per schema under the datadir. Used by
# NATIVE_MODE=attach so the native leg costs no extra disk.
find_engine_duckdb_file(){
  local db=${1:-tpch}
  find "$DUCKDB_DATADIR" -maxdepth 3 -name "$db.duckdb" 2>/dev/null | head -1
}

# Read the format manifest written by 01-generate.sh.
# PARSED, not sourced: a stray quote in the file (e.g. a literal QUOTE=") makes
# `.` abort mid-file and silently leave DELIM/HEADER empty - which produced a
# LOAD DATA with no delimiter and no IGNORE 1 LINES, so the header row was
# ingested as data. Defaults match what 01-generate.sh actually emits.
load_format(){
  local f="$DATA_DIR/.format" d h
  DELIM='|'; HEADER=1
  if [ -f "$f" ]; then
    d=$(grep -E '^DELIM=' "$f" 2>/dev/null | tail -1 | cut -d= -f2-)
    h=$(grep -E '^HEADER=' "$f" 2>/dev/null | tail -1 | cut -d= -f2-)
    [ -n "$d" ] && DELIM="$d"
    case "$h" in 0|1) HEADER="$h";; esac
  fi
  export DELIM HEADER
}

# The LOAD DATA field clause matching the generated files.
load_fields_clause(){
  load_format
  local c="FIELDS TERMINATED BY '$DELIM' OPTIONALLY ENCLOSED BY '\"' LINES TERMINATED BY '\n'"
  [ "$HEADER" = 1 ] && c="$c IGNORE 1 LINES"
  echo "$c"
}

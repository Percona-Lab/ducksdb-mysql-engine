# Self-contained distribution image: MySQL 9.7 with the in-tree DuckDB storage
# engine built in. Ships the mysqld we build ourselves, so the server and the
# engine are guaranteed ABI-compatible. No plugin to load — ENGINE=DuckDB is a
# MANDATORY built-in engine.
#
# The build context (the ./mysql install tree + this Dockerfile + entrypoint.sh)
# is produced by scripts/release-image.sh.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
# Only libssl3 is needed at runtime; ICU/abseil/protobuf and DuckDB are bundled
# (DuckDB is linked statically; the rest live in lib/private and load via rpath).
RUN apt-get update && apt-get install -y --no-install-recommends \
        libssl3 ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/*

COPY mysql /usr/local/mysql
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh && mkdir -p /var/lib/mysql

LABEL org.opencontainers.image.title="MySQL 9.7 + DuckDB storage engine" \
      org.opencontainers.image.description="MySQL 9.7 with a built-in ENGINE=DuckDB storage engine; analytical queries run automatically in DuckDB." \
      org.opencontainers.image.version="9.7-duckdb-v0.1.0"

ENV PATH=/usr/local/mysql/bin:$PATH
EXPOSE 3306
VOLUME /var/lib/mysql

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["mysqld"]

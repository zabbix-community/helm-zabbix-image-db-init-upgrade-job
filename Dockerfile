ARG MAJOR_VERSION
FROM zabbix/zabbix-server-pgsql:alpine-${MAJOR_VERSION}-latest
USER root
RUN apk add --no-cache kubectl
# debug output, only effective with the legacy monolithic entrypoint (6.4, 7.2); the modular one logs these itself
RUN sed '/^\s\+DB_EXISTS=/a\ \ \  echo "db_exists check returned \\\"${DB_EXISTS}\\\"... (server name: ${DB_SERVER_DBNAME})"' -i /usr/bin/docker-entrypoint.sh
RUN sed '/^\s\+ZBX_DB_VERSION=/a\ \ \      echo "zbx_db_version check returned \\\"${ZBX_DB_VERSION}\\\"... (server name: ${DB_SERVER_DBNAME})"' -i /usr/bin/docker-entrypoint.sh
COPY docker-entrypoint-run-replace.sh /tmp/docker-entrypoint-run-replace.sh
RUN awk '/^#################################################/ {print; exit} {print}' /usr/bin/docker-entrypoint.sh > /tmp/temp-script && \
    cat /tmp/docker-entrypoint-run-replace.sh >> /tmp/temp-script && \
    mv /tmp/temp-script /usr/bin/docker-entrypoint.sh && \
    rm /tmp/docker-entrypoint-run-replace.sh
RUN chmod 755 /usr/bin/docker-entrypoint.sh
# fail the build if the upstream entrypoint no longer provides the functions the job relies on
RUN bash -n /usr/bin/docker-entrypoint.sh && \
    defs="$(cat /usr/bin/docker-entrypoint.sh; cat /usr/lib/docker-entrypoint/*.sh 2>/dev/null || true)" && \
    for f in psql_query init_and_upgrade_db; do echo "$defs" | grep -q "^${f}()" || { echo "missing function: $f"; exit 1; }; done && \
    { { echo "$defs" | grep -q '^prepare_database()' && echo "$defs" | grep -q '^update_config()'; } || \
      { echo "$defs" | grep -q '^prepare_db()' && echo "$defs" | grep -q '^update_zbx_config()'; } || \
      { echo "missing prepare/update config functions"; exit 1; }; }
USER 1997

ARG MAJOR_VERSION
# override to build from an image without a major release in its tag, e.g. a digest-pinned alpine-trunk
ARG BASE_IMAGE=zabbix/zabbix-server-pgsql:alpine-${MAJOR_VERSION}-latest
FROM ${BASE_IMAGE}
ARG MAJOR_VERSION
USER root
# fail the build if the base image does not contain the expected major release of zabbix_server
RUN zabbix_server --version | sed -n '1p' | grep -q " ${MAJOR_VERSION}\." || \
    { echo "base image does not contain Zabbix ${MAJOR_VERSION}: $(zabbix_server --version | sed -n '1p')"; exit 1; }
RUN apk add --no-cache kubectl
# images with the compiled entrypoint (8.0 and newer) don't ship a shell entrypoint and psql anymore
COPY docker-entrypoint-compat-binary.sh /tmp/docker-entrypoint-compat-binary.sh
RUN if [ ! -f /usr/bin/docker-entrypoint.sh ]; then \
        apk add --no-cache postgresql-client && \
        cp /tmp/docker-entrypoint-compat-binary.sh /usr/bin/docker-entrypoint.sh; \
    fi && \
    rm /tmp/docker-entrypoint-compat-binary.sh
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
ENTRYPOINT ["/usr/bin/docker-entrypoint.sh"]
CMD ["/usr/sbin/zabbix_server", "--foreground", "-c", "/etc/zabbix/zabbix_server.conf"]

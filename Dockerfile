ARG MAJOR_VERSION
FROM zabbix/zabbix-server-pgsql:alpine-${MAJOR_VERSION}-latest
USER root
RUN apk add kubectl
RUN sed '/^\s\+DB_EXISTS=/a\ \ \  echo "db_exists check returned \\\"${DB_EXISTS}\\\"... (server name: ${DB_SERVER_DBNAME})"' -i /usr/bin/docker-entrypoint.sh
RUN sed '/^\s\+ZBX_DB_VERSION=/a\ \ \      echo "zbx_db_version check returned \\\"${ZBX_DB_VERSION}\\\"... (server name: ${DB_SERVER_DBNAME})"' -i /usr/bin/docker-entrypoint.sh
COPY docker-entrypoint-run-replace.sh /tmp/docker-entrypoint-run-replace.sh
RUN awk '/^#################################################/ {print; exit} {print}' /usr/bin/docker-entrypoint.sh > /tmp/temp-script && \
    cat /tmp/docker-entrypoint-run-replace.sh >> /tmp/temp-script && \
    mv /tmp/temp-script /usr/bin/docker-entrypoint.sh
RUN chmod 755 /usr/bin/docker-entrypoint.sh
USER 1997

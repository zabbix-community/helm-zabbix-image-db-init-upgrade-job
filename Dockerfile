# Image of the job that creates and upgrades the database schema of Zabbix Server, used by the Zabbix Helm chart
# when zabbixServer.zabbixServerHA.enabled=true. See README.md.
ARG MAJOR_VERSION
# Override to build from another image, e.g. a digest-pinned image or an image without a major release in its tag
ARG BASE_IMAGE=zabbix/zabbix-server-pgsql:alpine-${MAJOR_VERSION}-latest
FROM ${BASE_IMAGE}
ARG MAJOR_VERSION

LABEL org.opencontainers.image.title="zabbix-server-create-upgrade-db" \
      org.opencontainers.image.description="Creates and upgrades the database schema of Zabbix Server before the Zabbix Helm chart starts it in High Availability mode" \
      org.opencontainers.image.source="https://github.com/zabbix-community/helm-zabbix-image-db-init-upgrade-job" \
      org.opencontainers.image.licenses="Apache-2.0"

USER 0
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Fail the build if the base image does not contain the expected major release of zabbix_server.
# kubectl scales the Zabbix Server deployment down during upgrades. The versions of the packages come from the
# Alpine release of the base image, so they are not pinned
RUN zabbix_server --version | sed -n '1p' | grep -q " ${MAJOR_VERSION}\." || \
        { echo "base image does not contain Zabbix ${MAJOR_VERSION}: $(zabbix_server --version | sed -n '1p')"; exit 1; } && \
    apk add --no-cache kubectl

# Images with the compiled entrypoint (8.0 and newer) don't ship a shell entrypoint and psql anymore
COPY docker-entrypoint-compat-binary.sh /tmp/docker-entrypoint-compat-binary.sh
RUN if [ ! -f /usr/bin/docker-entrypoint.sh ]; then \
        apk add --no-cache postgresql-client && \
        cp /tmp/docker-entrypoint-compat-binary.sh /usr/bin/docker-entrypoint.sh; \
    fi && \
    rm /tmp/docker-entrypoint-compat-binary.sh

# Debug output, only effective with the legacy monolithic entrypoint (6.4, 7.2); the modular one logs these itself.
# Then keep only the functions of the upstream entrypoint (everything before the "####..." line) and append the
# job script
COPY docker-entrypoint-run-replace.sh /tmp/docker-entrypoint-run-replace.sh
# hadolint ignore=SC2016
RUN sed '/^\s\+DB_EXISTS=/a\ \ \  echo "db_exists check returned \\\"${DB_EXISTS}\\\"... (server name: ${DB_SERVER_DBNAME})"' -i /usr/bin/docker-entrypoint.sh && \
    sed '/^\s\+ZBX_DB_VERSION=/a\ \ \      echo "zbx_db_version check returned \\\"${ZBX_DB_VERSION}\\\"... (server name: ${DB_SERVER_DBNAME})"' -i /usr/bin/docker-entrypoint.sh && \
    awk '/^#################################################/ {print; exit} {print}' /usr/bin/docker-entrypoint.sh > /tmp/temp-script && \
    cat /tmp/docker-entrypoint-run-replace.sh >> /tmp/temp-script && \
    mv /tmp/temp-script /usr/bin/docker-entrypoint.sh && \
    rm /tmp/docker-entrypoint-run-replace.sh && \
    chmod 755 /usr/bin/docker-entrypoint.sh

# Fail the build if the upstream entrypoint no longer provides the functions the job relies on. Here-strings instead of
# "echo | grep -q": grep -q exits on the first match and, with pipefail, the SIGPIPE of echo (141) fails the check
# when $defs is bigger than the pipe buffer (modular entrypoint of 6.0 and 7.0)
RUN bash -n /usr/bin/docker-entrypoint.sh && \
    defs="$(cat /usr/bin/docker-entrypoint.sh; cat /usr/lib/docker-entrypoint/*.sh 2>/dev/null || true)" && \
    for f in psql_query init_and_upgrade_db; do grep -q "^${f}()" <<< "$defs" || { echo "missing function: $f"; exit 1; }; done && \
    { { grep -q '^prepare_database()' <<< "$defs" && grep -q '^update_config()' <<< "$defs"; } || \
      { grep -q '^prepare_db()' <<< "$defs" && grep -q '^update_zbx_config()' <<< "$defs"; } || \
      { echo "missing prepare/update config functions"; exit 1; }; } && \
    kubectl version --client

# Same user of the zabbix/zabbix-server-pgsql image
USER 1997
ENTRYPOINT ["/usr/bin/docker-entrypoint.sh"]
CMD ["/usr/sbin/zabbix_server", "--foreground", "-c", "/etc/zabbix/zabbix_server.conf"]

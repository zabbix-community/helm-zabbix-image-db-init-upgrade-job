FROM zabbix/zabbix-server-pgsql:alpine-7.0.4
USER root
RUN apk add kubectl
COPY docker-entrypoint-run-replace.sh /tmp/docker-entrypoint-run-replace.sh
RUN awk '/^#################################################/ {print; exit} {print}' /usr/bin/docker-entrypoint.sh > /tmp/temp-script && \
    cat /tmp/docker-entrypoint-run-replace.sh >> /tmp/temp-script && \
    mv /tmp/temp-script /usr/bin/docker-entrypoint.sh
RUN chmod 755 /usr/bin/docker-entrypoint.sh
USER 1997

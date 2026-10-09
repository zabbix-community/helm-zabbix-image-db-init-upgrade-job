#!/usr/bin/env bash
# Used instead of the upstream shell entrypoint for images that ship the compiled /usr/bin/docker-entrypoint
# (Zabbix 8.0 and newer). Provides the functions init_and_upgrade_db relies on; database and schema creation is
# delegated to the upstream binary.

set -euo pipefail

file_env() {
    local var="$1"
    local file_var="${var}_FILE"

    if [ -n "${!var:-}" ] && [ -n "${!file_var:-}" ]; then
        echo "*** FATAL both ${var} and ${file_var} are set (but are exclusive)"
        exit 1
    fi
    if [ -n "${!file_var:-}" ]; then
        export "${var}=$(< "${!file_var}")"
        unset "${file_var}"
    fi
}

check_db_variables() {
    : "${DB_SERVER_HOST=postgres-server}"
    : "${DB_SERVER_PORT:=5432}"
    : "${DB_SERVER_SCHEMA=public}"

    file_env POSTGRES_USER
    file_env POSTGRES_PASSWORD

    DB_SERVER_ROOT_USER="${POSTGRES_USER:-postgres}"
    DB_SERVER_ZBX_USER="${POSTGRES_USER:-zabbix}"
    DB_SERVER_ZBX_PASS="${POSTGRES_PASSWORD:-zabbix}"
    DB_SERVER_DBNAME="${POSTGRES_DB:-zabbix}"

    psql_connect_args=(--port "${DB_SERVER_PORT}")
    if [ -n "${DB_SERVER_HOST}" ]; then
        psql_connect_args+=(--host "${DB_SERVER_HOST}")
    fi
}

set_pg_env() {
    export PGPASSWORD="${DB_SERVER_ZBX_PASS}"

    if [ "${POSTGRES_USE_IMPLICIT_SEARCH_PATH:-false}" = "false" ] && [ -n "${DB_SERVER_SCHEMA:-}" ]; then
        export PGOPTIONS="--search_path=${DB_SERVER_SCHEMA}"
    fi

    [ "${ZBX_DB_ENCRYPTION:-}" = "true" ] && export ZBX_DBTLSCONNECT=required

    if [ -n "${ZBX_DBTLSCONNECT:-}" ]; then
        local pg_sslmode="${ZBX_DBTLSCONNECT//_/-}"
        export PGSSLMODE="${pg_sslmode//required/require}"
        export PGSSLROOTCERT="${ZBX_DBTLSCAFILE:-}"
        export PGSSLCERT="${ZBX_DBTLSCERTFILE:-}"
        export PGSSLKEY="${ZBX_DBTLSKEYFILE:-}"
    fi
}

clear_pg_env() {
    unset PGPASSWORD PGOPTIONS PGSSLMODE PGSSLROOTCERT PGSSLCERT PGSSLKEY
}

psql_query() {
    local query="${1:-}"
    local db="${2:-}"
    local result=""

    set_pg_env
    result="$(psql --no-align --quiet --tuples-only \
        "${psql_connect_args[@]}" \
        --username "${DB_SERVER_ROOT_USER}" \
        --command "$query" \
        --dbname "$db")"
    clear_pg_env

    printf '%s\n' "$result"
}

prepare_database() {
    if [ -n "${ZBX_VAULTDBPATH:-}" ]; then
        echo "*** FATAL database credentials from vault (ZBX_VAULTDBPATH) are not supported by this job image"
        exit 1
    fi

    # waits for the database, creates database, schema and initial data if missing
    /usr/bin/docker-entrypoint init_db_only

    check_db_variables
}

update_config() {
    # the configuration files shipped with the image reference these variables
    export ZBX_DB_HOST="${DB_SERVER_HOST}"
    export ZBX_DB_PORT="${DB_SERVER_PORT}"
    export ZBX_DB_NAME="${DB_SERVER_DBNAME}"
    export ZBX_DB_SCHEMA="${DB_SERVER_SCHEMA}"
    export ZBX_DB_USER="${DB_SERVER_ZBX_USER}"
    export ZBX_DB_PASSWORD="${DB_SERVER_ZBX_PASS}"
}

#################################################

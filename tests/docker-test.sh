#!/usr/bin/env bash
# Tests the job image with Docker and a temporary PostgreSQL container, without Kubernetes.
# The behavior that depends on Kubernetes (scaling the Zabbix Server deployment down) is tested with the Helm chart in a
# kind cluster. See docs/local-tests.md.
#
# Usage: tests/docker-test.sh [scenario...]
# Scenarios: fresh-install rerun standalone-aged standalone-timeout auto-without-kubernetes upgrade
# Variables:
#   IMAGE               job image to test (default: zabbix-server-create-upgrade-db:8.0-local)
#   POSTGRES_IMAGE      PostgreSQL image (default: postgres:18)
#   UPGRADE_FROM_IMAGE  job image of an older Zabbix major version, used by the "upgrade" scenario to create the old
#                       schema (default: ghcr.io/zabbix-community/zabbix-server-create-upgrade-db:7.4-20261009150714)

set -euo pipefail

IMAGE="${IMAGE:-zabbix-server-create-upgrade-db:8.0-local}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:18}"
UPGRADE_FROM_IMAGE="${UPGRADE_FROM_IMAGE:-ghcr.io/zabbix-community/zabbix-server-create-upgrade-db:7.4-20261009150714}"
DEFAULT_SCENARIOS="fresh-install rerun standalone-aged standalone-timeout auto-without-kubernetes"

NAME="zbx-db-job-test-$$"
NETWORK="${NAME}"
DB_CONTAINER="${NAME}-postgres"
DB_PASSWORD="zabbix123"
failures=0

log() { echo "### $(date -u +%H:%M:%S) $*"; }

cleanup() {
    docker rm -f "${DB_CONTAINER}" >/dev/null 2>&1 || true
    docker network rm "${NETWORK}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

psql_exec() {
    docker exec -i "${DB_CONTAINER}" psql -U zabbix -d zabbix --no-align --quiet --tuples-only -c "$1"
}

start_db() {
    cleanup
    docker network create "${NETWORK}" >/dev/null
    docker run -d --name "${DB_CONTAINER}" --network "${NETWORK}" --network-alias postgres \
        -e POSTGRES_USER=zabbix -e POSTGRES_PASSWORD="${DB_PASSWORD}" -e POSTGRES_DB=zabbix \
        "${POSTGRES_IMAGE}" >/dev/null
    until docker exec "${DB_CONTAINER}" pg_isready -U zabbix -d zabbix >/dev/null 2>&1; do sleep 1; done
    # pg_isready is true during the init of the official image, before the restart of the server
    sleep 3
    until docker exec "${DB_CONTAINER}" pg_isready -U zabbix -d zabbix >/dev/null 2>&1; do sleep 1; done
}

# Runs the job like the Helm chart does. Extra "docker run" arguments are accepted before "--" and the image after it
run_job() {
    local image="${IMAGE}"
    local args=()
    while [[ $# -gt 0 ]]; do
        if [[ $1 == "--" ]]; then image="$2"; break; fi
        args+=("$1"); shift
    done
    docker run --rm --network "${NETWORK}" \
        -e DB_SERVER_HOST=postgres -e DB_SERVER_PORT=5432 \
        -e POSTGRES_USER=zabbix -e POSTGRES_PASSWORD="${DB_PASSWORD}" -e POSTGRES_DB=zabbix \
        -e ZBX_SERVER_DEPLOYMENT_NAME=zabbix-zabbix-server \
        ${args[@]+"${args[@]}"} \
        "${image}" init_and_upgrade_db
}

# Expected schema version: the one shipped with the tested image
image_schema_version() {
    docker run --rm --entrypoint sh "${IMAGE}" -c \
        'for f in /usr/share/doc/zabbix-server-postgresql/postgresql/create.sql.gz /usr/share/doc/zabbix-server-postgresql/create.sql.gz; do
            [ -f "$f" ] && { zcat "$f" | sed -nE "s/^INSERT INTO dbversion VALUES \(.1.,.([0-9]+).*/\1/p" | head -n 1; exit; }
         done'
}

insert_standalone_node() {
    # $1: lastaccess relative to now, in seconds
    psql_exec "INSERT INTO ha_node (ha_nodeid, name, address, port, lastaccess, status, ha_sessionid)
               VALUES ('cmtest0000000000000000001', '', '10.0.0.1', 10051, extract(epoch from now())::int + ($1), 3, '')" >/dev/null
}

pass() { log "PASS: $*"; }
fail() { log "FAIL: $*"; failures=$((failures + 1)); }

scenario_fresh-install() {
    start_db
    run_job -e HELM_HOOK_TYPE=install
    local expected found
    expected=$(image_schema_version)
    found=$(psql_exec "SELECT mandatory FROM dbversion")
    if [[ $found == "$expected" ]]; then pass "schema ${found} created"; else fail "schema version ${found}, expected ${expected}"; fi
}

scenario_rerun() {
    start_db
    run_job -e HELM_HOOK_TYPE=install >/dev/null
    local output
    output=$(run_job -e HELM_HOOK_TYPE=install)
    echo "${output}" | tail -n 3
    if grep -q "DB schema is up-to-date" <<<"${output}"; then
        pass "second run found the schema up to date"
    else
        fail "second run did not find the schema up to date"
    fi
}

scenario_standalone-aged() {
    # a standalone node seen 40 seconds ago: the job waits ~20 seconds until it is older than the failover delay
    start_db
    run_job -e HELM_HOOK_TYPE=install >/dev/null
    insert_standalone_node -40
    if run_job -e HELM_HOOK_TYPE=install -e JOB_WAIT_TIMEOUT=120; then
        pass "the job waited for the standalone node to age out"
    else
        fail "the job failed with an old standalone node"
    fi
}

scenario_standalone-timeout() {
    # a standalone node that keeps updating its row (simulated with a lastaccess in the future) and no deployment to
    # stop: the job must fail after JOB_WAIT_TIMEOUT, instead of waiting forever (issue #231)
    start_db
    run_job -e HELM_HOOK_TYPE=install >/dev/null
    insert_standalone_node 3600
    local output rc=0
    output=$(run_job -e HELM_HOOK_TYPE=install -e JOB_WAIT_TIMEOUT=15) || rc=$?
    echo "${output}" | tail -n 2
    if [[ $rc -ne 0 ]] && grep -q "timeout of 15s" <<<"${output}"; then
        pass "the job failed after JOB_WAIT_TIMEOUT (exit code ${rc})"
    else
        fail "the job did not fail with a timeout (exit code ${rc})"
    fi
}

scenario_auto-without-kubernetes() {
    # HELM_HOOK_TYPE=auto needs the Kubernetes API: without it, the job must fail with a clear message
    start_db
    local output rc=0
    output=$(run_job -e HELM_HOOK_TYPE=auto 2>&1) || rc=$?
    echo "${output}" | tail -n 1
    if [[ $rc -ne 0 ]] && grep -q "could not read the deployment" <<<"${output}"; then
        pass "the job failed with a clear message (exit code ${rc})"
    else
        fail "unexpected result (exit code ${rc})"
    fi
}

scenario_upgrade() {
    # creates the schema of an older major version with its published job image, then upgrades it with the tested image
    start_db
    run_job -e HELM_HOOK_TYPE=install -- "${UPGRADE_FROM_IMAGE}" >/dev/null
    local before after expected
    before=$(psql_exec "SELECT mandatory FROM dbversion")
    log "schema created by ${UPGRADE_FROM_IMAGE}: ${before}"
    run_job -e HELM_HOOK_TYPE=install
    after=$(psql_exec "SELECT mandatory FROM dbversion")
    expected=$(image_schema_version)
    if [[ $after == "$expected" && $after != "$before" ]]; then
        pass "schema upgraded from ${before} to ${after}"
    else
        fail "schema ${after} after the upgrade, expected ${expected}"
    fi
    local nodes
    nodes=$(psql_exec "SELECT COUNT(*) FROM ha_node WHERE name='' AND status=3")
    if [[ $nodes -eq 0 ]]; then pass "no standalone node left in ha_node"; else fail "${nodes} standalone nodes left in ha_node"; fi
}

scenarios=("$@")
[[ ${#scenarios[@]} -gt 0 ]] || read -r -a scenarios <<<"${DEFAULT_SCENARIOS}"
log "image: ${IMAGE}"
for scenario in "${scenarios[@]}"; do
    if ! declare -F "scenario_${scenario}" >/dev/null; then
        fail "unknown scenario ${scenario}"
        continue
    fi
    log "scenario ${scenario}"
    "scenario_${scenario}" || fail "scenario ${scenario} exited with an error"
done

if [[ $failures -gt 0 ]]; then
    log "${failures} failure(s)"
    exit 1
fi
log "all scenarios passed: ${scenarios[*]}"

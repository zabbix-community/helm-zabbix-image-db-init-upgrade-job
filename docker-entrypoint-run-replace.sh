
# The lines below are appended to the upstream entrypoint of the zabbix/zabbix-server-pgsql image by the Dockerfile.
# They reuse the upstream functions (prepare_database/prepare_db, update_config/update_zbx_config and psql_query)
# and the variables they set (DB_SERVER_*). See README.md for the decision flow of init_and_upgrade_db.

# Maximum time, in seconds, of each wait loop of this job. When it expires, the job fails instead of waiting forever
JOB_WAIT_TIMEOUT="${JOB_WAIT_TIMEOUT:-900}"
# Paths of the database schema shipped with the image: Zabbix 8.0 and newer use the first one
SCHEMA_FILES="/usr/share/doc/zabbix-server-postgresql/postgresql/create.sql.gz /usr/share/doc/zabbix-server-postgresql/create.sql.gz"

log() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
}

fatal() {
    log "*** FATAL $*"
    exit 1
}

# Decides whether this run must manage the Zabbix Server Deployment (scale it down) or not.
# HELM_HOOK_TYPE is set by the Helm chart:
# - install: there is no Zabbix Server Deployment, kubectl is never called
# - upgrade: there may be running Zabbix Server pods, they are scaled down when needed
# - auto (or empty/unknown): checks if the Deployment exists. This is the only reliable way under Argo CD and other
#   tools that render the chart with "helm template", where .Release.IsUpgrade is always false
detect_hook_type() {
    HELM_HOOK_TYPE="${HELM_HOOK_TYPE:-auto}"
    case "${HELM_HOOK_TYPE}" in
        install|upgrade)
            ;;
        *)
            ZBX_SERVER_DEPLOYMENT_NAME="${ZBX_SERVER_DEPLOYMENT_NAME:?ZBX_SERVER_DEPLOYMENT_NAME must be set when HELM_HOOK_TYPE=auto}"
            local found
            if ! found=$(kubectl get deployment "${ZBX_SERVER_DEPLOYMENT_NAME}" --ignore-not-found -o name 2>&1); then
                fatal "could not read the deployment ${ZBX_SERVER_DEPLOYMENT_NAME}, check the RBAC of the service account of the job: ${found}"
            fi
            if [[ -n $found ]]; then
                HELM_HOOK_TYPE=upgrade
                log "deployment ${ZBX_SERVER_DEPLOYMENT_NAME} exists, running as upgrade"
            else
                HELM_HOOK_TYPE=install
                log "deployment ${ZBX_SERVER_DEPLOYMENT_NAME} does not exist, running as install"
            fi
            ;;
    esac
}

# Label selector of the pods of the Zabbix Server Deployment. Read from the Deployment itself, so it always matches the
# labels set by the chart. ZBX_SERVER_POD_SELECTOR overrides it
server_pod_selector() {
    if [[ -n ${ZBX_SERVER_POD_SELECTOR:-} ]]; then
        echo "${ZBX_SERVER_POD_SELECTOR}"
        return
    fi
    local selector
    # shellcheck disable=SC2016 # go-template, not shell expansion
    selector=$(kubectl get deployment "${ZBX_SERVER_DEPLOYMENT_NAME}" \
        -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}') || return 1
    [[ -n $selector ]] || return 1
    echo "${selector%,}"
}

# Runs "$@" until it returns 0, at most JOB_WAIT_TIMEOUT seconds
wait_for() {
    local description="$1"
    shift
    local start
    start=$(date +%s)
    until "$@"; do
        if (( $(date +%s) - start >= JOB_WAIT_TIMEOUT )); then
            fatal "timeout of ${JOB_WAIT_TIMEOUT}s (JOB_WAIT_TIMEOUT) waiting for: ${description}"
        fi
        sleep 2
    done
}

# Number of Zabbix Server nodes that updated the ha_node table in the last $1 seconds, optionally filtered by $2
count_active_nodes() {
    local seconds="$1"
    local filter="${2:-}"
    psql_query "SELECT COUNT(*) FROM ${DB_SERVER_SCHEMA}.ha_node WHERE lastaccess >= extract(epoch from now()) - ${seconds} ${filter}" "${DB_SERVER_DBNAME}"
}

no_server_pods() {
    local pods
    pods=$(kubectl get pods -l "${pod_selector}" -o name) || return 1
    if [[ -n $pods ]]; then
        log "**** pods of the deployment ${ZBX_SERVER_DEPLOYMENT_NAME} still running: $(echo "${pods}" | wc -l)"
        return 1
    fi
}

no_active_nodes() {
    local active
    active=$(count_active_nodes 10 "${1:-}")
    if [[ $active -ne 0 ]]; then
        log "**** ${active} zabbix_server instances seen in the ha_node table within the last 10 seconds"
        return 1
    fi
}

no_active_standalone_nodes() {
    local active
    active=$(count_active_nodes 60 "AND status=3 AND name=''")
    if [[ $active -ne 0 ]]; then
        log "**** ${active} standalone (non-HA) zabbix_server instances seen in the ha_node table within the last 60 seconds"
        return 1
    fi
}

# Scales the Zabbix Server Deployment down to 0 replicas and waits until its pods are gone. The chart (Helm or Argo CD)
# restores the replicas when it applies the Deployment, after this job
scale_down_server() {
    if [[ $HELM_HOOK_TYPE != upgrade ]]; then
        log "** hook type is ${HELM_HOOK_TYPE}, there is no Zabbix Server deployment to scale down"
        return
    fi
    ZBX_SERVER_DEPLOYMENT_NAME="${ZBX_SERVER_DEPLOYMENT_NAME:?ZBX_SERVER_DEPLOYMENT_NAME must be set}"
    local replicas
    replicas=$(kubectl get deployment "${ZBX_SERVER_DEPLOYMENT_NAME}" -o jsonpath='{.spec.replicas}') \
        || fatal "could not read the deployment ${ZBX_SERVER_DEPLOYMENT_NAME}"
    pod_selector=$(server_pod_selector) || fatal "could not read the pod selector of the deployment ${ZBX_SERVER_DEPLOYMENT_NAME}"
    log "** scaling the deployment ${ZBX_SERVER_DEPLOYMENT_NAME} from ${replicas} to 0 replicas (pods: ${pod_selector})"
    kubectl scale deployment "${ZBX_SERVER_DEPLOYMENT_NAME}" --replicas=0 \
        || fatal "could not scale the deployment ${ZBX_SERVER_DEPLOYMENT_NAME}"
    wait_for "pods of the deployment ${ZBX_SERVER_DEPLOYMENT_NAME} to terminate" no_server_pods
}

# Version of the database schema expected by the zabbix_server binary of this image. Comparing the full mandatory
# version also covers pre-releases, whose schema version doesn't follow the release number (8.0.0rc2 uses 7050195)
image_schema_version() {
    local file
    for file in ${SCHEMA_FILES}; do
        if [[ -f $file ]]; then
            # "|| true": head closes the pipe early, which is an error with "set -o pipefail"
            zcat "$file" | sed -nE "s/^INSERT INTO dbversion VALUES \('1','([0-9]+)'.*/\1/p" | head -n 1 || true
            return
        fi
    done
}

# Starts zabbix_server, which upgrades the schema, and stops it as soon as it went past the upgrade. There is no
# controlled way in the zabbix_server binary (yet) to only upgrade the schema and exit:
# https://support.zabbix.com/browse/ZBXNEXT-9453
upgrade_schema() {
    local pipe="/tmp/zabbix_output_pipe"
    local schema_upgraded=false
    rm -f "$pipe"
    mkfifo "$pipe"
    /usr/sbin/zabbix_server --foreground -c /etc/zabbix/zabbix_server.conf > "$pipe" 2>&1 &
    local zabbix_pid=$!
    while IFS= read -r line; do
        echo "$line"
        if [[ $line == *"starting HA manager"* ]]; then
            log "found 'starting HA manager', stopping zabbix_server"
            schema_upgraded=true
            kill "$zabbix_pid" 2>/dev/null || true
            break
        fi
    done < "$pipe"
    wait "$zabbix_pid" 2>/dev/null || true
    rm -f "$pipe"

    if [[ $schema_upgraded != true ]]; then
        fatal "zabbix_server exited before reaching 'starting HA manager', the database upgrade did not complete"
    fi
}

# Removes the rows of standalone (non-HA) Zabbix Server nodes. Zabbix Server in HA mode refuses to start while a
# standalone node was seen within the failover delay (1 minute by default)
delete_standalone_nodes() {
    log "** deleting the rows of standalone zabbix_server nodes from the ha_node table"
    psql_query "DELETE FROM ${DB_SERVER_SCHEMA}.ha_node WHERE name='' AND status=3" "${DB_SERVER_DBNAME}" > /dev/null
}

init_and_upgrade_db() {
    detect_hook_type

    # at this point, the database schema exists (created or verified by prepare_database/prepare_db). The
    # zabbix_server binary of this image is the version that will run afterwards
    local db_version zbx_version db_version_cmp zbx_version_cmp
    db_version=$(psql_query "SELECT mandatory FROM ${DB_SERVER_SCHEMA}.dbversion" "${DB_SERVER_DBNAME}")
    [[ -n $db_version ]] || fatal "could not read the schema version from ${DB_SERVER_SCHEMA}.dbversion in database ${DB_SERVER_DBNAME}"
    log "DB version found: ${db_version} in database ${DB_SERVER_DBNAME} and user ${DB_SERVER_ROOT_USER} on host ${DB_SERVER_HOST}"

    zbx_version=$(image_schema_version)
    if [[ -n $zbx_version ]]; then
        db_version_cmp=${db_version}
        zbx_version_cmp=${zbx_version}
    else
        # fallback: compare major releases only
        log "schema file not found (${SCHEMA_FILES}), comparing major releases only"
        db_version_cmp=${db_version:0:4}
        zbx_version_cmp=$(/usr/sbin/zabbix_server --version | sed -nE '1s/.* ([0-9]+)\.([0-9]+)\..*/\10\20/p')
    fi
    log "db schema version: ${db_version_cmp}, schema version expected by zabbix_server: ${zbx_version_cmp}"

    if [[ $zbx_version_cmp -gt $db_version_cmp ]]; then
        log "** initializing the schema upgrade process"
        # it doesn't matter if we come from an HA enabled or a standalone setup: all the running Zabbix Server pods
        # are stopped and a standalone zabbix_server of this image upgrades the schema
        scale_down_server
        wait_for "no active zabbix_server instances in the ha_node table" no_active_nodes

        upgrade_schema

        # wait for the zabbix_server started above to leave the ha_node table
        wait_for "no active zabbix_server instances in the ha_node table" no_active_nodes "AND status IN (0, 3)"
        delete_standalone_nodes
        log "** schema upgraded, done"
        exit 0

    elif [[ $zbx_version_cmp -lt $db_version_cmp ]]; then
        fatal "database schema version ${db_version_cmp} is higher than zabbix server's ${zbx_version_cmp}, downgrade is not supported!"

    else
        log "*** DB schema is up-to-date, checking whether we come from a standalone (non-HA) setup"
        if no_active_standalone_nodes; then
            log "*** no active standalone zabbix_server found, done"
            exit 0
        fi
        # a running standalone Zabbix Server keeps its row up to date, so it must be stopped before Zabbix Server
        # starts in HA mode. This is the transition from zabbixServerHA.enabled=false to true
        if [[ $HELM_HOOK_TYPE == upgrade ]]; then
            scale_down_server
            wait_for "no active standalone zabbix_server instances in the ha_node table" no_active_nodes "AND status=3 AND name=''"
            delete_standalone_nodes
        else
            # there is no deployment to stop: wait for the rows to be older than the failover delay
            wait_for "no active standalone zabbix_server instances in the ha_node table" no_active_standalone_nodes
        fi
        log "*** done"
        exit 0
    fi
}

if [ "${1:-}" == "init_and_upgrade_db" ]; then
    log "sleeping 10 seconds..."
    sleep 10
    if declare -F prepare_database >/dev/null; then
        # modular entrypoint (/usr/lib/docker-entrypoint/*.sh, used by 6.0, 7.0 and 7.4 images) or the functions of
        # docker-entrypoint-compat-binary.sh (8.0 and newer images, which ship a compiled entrypoint)
        prepare_database
        update_config
    else
        # legacy monolithic entrypoint, used by 6.4 and 7.2 images
        prepare_db
        update_zbx_config
    fi
    init_and_upgrade_db
else
    exec "$@"
fi

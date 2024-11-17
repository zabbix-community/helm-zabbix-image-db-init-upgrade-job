
init_and_upgrade_db() {
    # get version of db schema and version of zabbix server within this image
    db_version=$(psql_query "SELECT mandatory FROM dbversion" "${DB_SERVER_DBNAME}")
    echo "DB version found: ${db_version} in database ${DB_SERVER_DBNAME} and user ${DB_SERVER_ROOT_USER} on host ${DB_SERVER_HOST}"
    db_version_major=${db_version:0:4}
    zbx_version_major=$(/usr/sbin/zabbix_server --version | head -n 1 | sed -E 's/.* ([0-9]+)\.([0-9]+)\..*/\10\20/')
    echo "db_version_major: ${db_version_major}, zbx_version_major: ${zbx_version_major}"

    # compare those and figure whether a major release upgrade is necessary
    if [ ${zbx_version_major} -gt ${db_version_major} ]; then

        # scale down existing Zabbix deployment
	deployment_replicas=$(kubectl get deploy ${ZBX_SERVER_DEPLOYMENT_NAME} -o jsonpath='{.spec.replicas}')
	echo "** scaling zabbix server deployment with name ${ZBX_SERVER_DEPLOYMENT_NAME} from ${deployment_replicas} to 0 replicas"
        kubectl scale deploy ${ZBX_SERVER_DEPLOYMENT_NAME} --replicas=0

        # wait for no active zabbix_servers speaking with the db anymore
        WAIT_TIMEOUT=1
        while true :
        do
            active_servers=$(psql_query "SELECT COUNT(*) FROM ha_node WHERE lastaccess >= extract(epoch from now()) - 10" "${DB_SERVER_DBNAME}")
            if [ ${active_servers} -eq 0 ]; then
                break
            fi
            echo "**** ${active_servers} active zabbix_server instances seen within less than 10 seconds... waiting"
            sleep $WAIT_TIMEOUT
        done

        # now we start the zabbix_server binary with the configuration created above, and we halt it as soon as
        # it went over the part when it upgrades the database schema
        PIPE="/tmp/zabbix_output_pipe"
        mkfifo "$PIPE"
        /usr/sbin/zabbix_server --foreground -c /etc/zabbix/zabbix_server.conf > "$PIPE" 2>&1 &
        ZABBIX_PID=$!
        while IFS= read -r line < "$PIPE"; do
            echo "$line"

            # Check if the line contains the string "starting HA manager"
            if [[ "$line" == *"starting HA manager"* ]]; then
                echo "Found 'starting HA manager' - killing process"
                kill "$ZABBIX_PID"
                break
            fi
        done

        # Clean up by removing the named pipe
        rm "$PIPE"

	# scale up the deployment again
	echo "** scaling up zabbix server deployment with name ${ZBX_SERVER_DEPLOYMENT_NAME} to ${deployment_replicas} replicas"
        kubectl scale deploy ${ZBX_DEPLOYMENT_NAME} --replicas=${deployment_replicas}

        # we are ready to go
	exit 0
    elif [ ${zbx_version_major} -lt ${db_version_major} ]; then
        echo "*** FATAL database schema version ${db_version_major} is higher than zabbix server's ${zbx_version_major}, downgrade is not supported!"
	exit 252
    else
        echo "*** DB schema is up-to-date"
	exit 0
    fi
}

if [ "$1" == "init_and_upgrade_db" ]; then
    prepare_db
    update_zbx_config
    init_and_upgrade_db
else
    exec "$@"
fi


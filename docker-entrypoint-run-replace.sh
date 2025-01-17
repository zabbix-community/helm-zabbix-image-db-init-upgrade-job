
init_and_upgrade_db() {
    # get version of db schema and version of zabbix server within this image
    HELM_HOOK_TYPE="${HELM_HOOK_TYPE:-unknown}"
    echo "job hook type is ${HELM_HOOK_TYPE}"

    # at this point, we know that Zabbix DB schema is existing (either created or verified to be existing in the steps
    # before), and we assume that the version of zabbix_server binary coming with this image is the version of Zabbix
    # server that will be run, afterwards. Therefore, we first find out major releases of the database schema and of
    # the zabbix_server binary inside this image.
    db_version=$(psql_query "SELECT mandatory FROM ${DB_SERVER_SCHEMA}.dbversion" "${DB_SERVER_DBNAME}")
    echo "DB version found: ${db_version} in database ${DB_SERVER_DBNAME} and user ${DB_SERVER_ROOT_USER} on host ${DB_SERVER_HOST}"
    db_version_major=${db_version:0:4}
    zbx_version_major=$(/usr/sbin/zabbix_server --version | head -n 1 | sed -E 's/.* ([0-9]+)\.([0-9]+)\..*/\10\20/')
    echo "db_version_major: ${db_version_major}, zbx_version_major: ${zbx_version_major}"


    # compare those and figure whether a major release upgrade is necessary
    if [[ $zbx_version_major -gt $db_version_major ]]; then
        echo "** initializing the major release upgrade process"
        # in case of an upgrade, it doesn't matter if we come from an HA-enabled or a single-node setup. We will after preparation start a single-node
        # pod anyway which will not fail if it finds an entry of a non-HA-enabled one in the database.

	
        # scale down existing Zabbix deployment
	# This is actually only needed when this job has been started as a pre-UPGRADE job, as otherwise there would be
	# no running pods accessing the database
	if [[ $HELM_HOOK_TYPE == *"upgrade" ]]; then
		deployment_replicas=$(kubectl get deploy ${ZBX_SERVER_DEPLOYMENT_NAME} -o jsonpath='{.spec.replicas}')
        	echo "** scaling zabbix server deployment with name ${ZBX_SERVER_DEPLOYMENT_NAME} from ${deployment_replicas} to 0 replicas"
        	kubectl scale deploy ${ZBX_SERVER_DEPLOYMENT_NAME} --replicas=0

        	# wait for no active zabbix_servers speaking with the db anymore
        	WAIT_TIMEOUT=1
        	while true :
        	do
        		active_servers=$(psql_query "SELECT COUNT(*) FROM ${DB_SERVER_SCHEMA}.ha_node WHERE lastaccess >= extract(epoch from now()) - 10" "${DB_SERVER_DBNAME}")
        		deployment_pods=$(kubectl get pods -l app=${ZBX_SERVER_DEPLOYMENT_NAME} -o custom-columns=NAME:.metadata.name --no-headers | wc -l)
        		if [[ $active_servers -eq 0 && $deployment_pods -eq 0 ]]; then
        			break
        		fi
        		echo "**** ${active_servers} active zabbix_server instances seen within less than 10 seconds and ${deployment_pods} pods of deployment ${ZBX_SERVER_DEPLOYMENT_NAME} still running... waiting"
        		sleep $WAIT_TIMEOUT
		done
	fi


        # now we start the zabbix_server binary with the configuration created above, and we halt it as soon as
        # it went over the point when it upgraded the database schema. This is because there is no controlled
	# way in the zabbix_server binary (yet) to only upgrade the DB schema and exit gracefully:
	# https://support.zabbix.com/browse/ZBXNEXT-9453
        PIPE="/tmp/zabbix_output_pipe"
        mkfifo "$PIPE"
        /usr/sbin/zabbix_server --foreground -c /etc/zabbix/zabbix_server.conf > "$PIPE" 2>&1 &
        ZABBIX_PID=$!
        while IFS= read -r line < "$PIPE"; do
            echo "$line"

            # Check if the line contains the string "starting HA manager"
            if [[ $line == *"starting HA manager"* ]]; then
                echo "Found 'starting HA manager' - killing process"
                kill "$ZABBIX_PID"
                break
            fi
        done

        # Clean up by removing the named pipe
        rm "$PIPE"

        # wait for no active zabbix_servers speaking with the db anymore
        WAIT_TIMEOUT=1
        while true :
        do
            active_servers=$(psql_query "SELECT COUNT(*) FROM ${DB_SERVER_SCHEMA}.ha_node WHERE lastaccess >= extract(epoch from now()) - 10 and status in (0, 3)" "${DB_SERVER_DBNAME}")
            if [[ $active_servers -eq 0 ]]; then
                break
            fi
            echo "**** ${active_servers} active zabbix_server instances seen within less than 10 seconds... waiting"
            sleep $WAIT_TIMEOUT
        done

        # delete eventually remaining active standalone server entries from ha_node table in order that the ha-enabled
	# ones can start up otherwise they will most probably fail for >1 minute
        psql_query "DELETE FROM ${DB_SERVER_SCHEMA}.ha_node WHERE name='' and status=3" "${DB_SERVER_DBNAME}"

        # we are ready to go
        exit 0


    elif [[ $zbx_version_major -lt $db_version_major ]]; then
        echo "*** FATAL database schema version ${db_version_major} is higher than zabbix server's ${zbx_version_major}, downgrade is not supported!"
        exit 252

    else
        echo "*** DB schema is up-to-date, checking for whether we come from a non-HA enabled setup"
        # check if we are coming from a standalone setup, which means, there are entries in the ha_node table with no
	# name set. In that case, we need to wait for those to go away
        # Reason to do this is that Zabbix Server in HA mode refuses to start if a non-HA node has been seen within the
	# FAILOVER PERIOD which is 1 minute by default
        echo "** checking for eventually still connected active non-HA mode pods of Zabbix Server..."
        while true :
        do
		active_servers=$(psql_query "SELECT COUNT(*) FROM ${DB_SERVER_SCHEMA}.ha_node WHERE lastaccess >= extract(epoch from now()) - 60 AND status=3 and name=''" "${DB_SERVER_DBNAME}")
        	if [[ $active_servers -eq 0 ]]; then
                	echo "*** none found, continuing"
                	break
        	fi

        	echo "*** found ${active_servers} in db, waiting 10 seconds"
                sleep $WAIT_TIMEOUT
        done
        exit 0
    fi
}

if [ "$1" == "init_and_upgrade_db" ]; then
    echo "sleeping 10 seconds..."
    sleep 10
    prepare_db
    update_zbx_config
    init_and_upgrade_db
else
    exec "$@"
fi


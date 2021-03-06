#!/bin/bash

set -e

if [ "$1" = 'splunk' ]; then
  shift
  sudo -HEu ${SPLUNK_USER} ${SPLUNK_HOME}/bin/splunk "$@"
elif [ "$1" = 'start-service' ]; then
  # If user changed SPLUNK_USER to root we want to change permission for SPLUNK_HOME
  if [[ "${SPLUNK_USER}:${SPLUNK_GROUP}" != "$(stat --format %U:%G ${SPLUNK_HOME})" ]]; then
    chown -R ${SPLUNK_USER}:${SPLUNK_GROUP} ${SPLUNK_HOME}
  fi

  # If version file exists already - this Splunk has been configured before
  __configured=false
  if [[ -f ${SPLUNK_HOME}/etc/splunk.version ]]; then
    __configured=true
  fi

  __license_ok=false
  # If these files are different override etc folder (possible that this is upgrade or first start cases)
  # Also override ownership of these files to splunk:splunk
  if ! $(cmp --silent /var/opt/splunk/etc/splunk.version ${SPLUNK_HOME}/etc/splunk.version); then
    cp -fR /var/opt/splunk/etc ${SPLUNK_HOME}
    chown -R ${SPLUNK_USER}:${SPLUNK_GROUP} ${SPLUNK_HOME}/etc
    chown -R ${SPLUNK_USER}:${SPLUNK_GROUP} ${SPLUNK_HOME}/var
  else
    __license_ok=true
  fi

  if tty -s; then
    __license_ok=true
  fi

  if [[ "$SPLUNK_START_ARGS" == *"--accept-license"* ]]; then
    __license_ok=true
  fi

  if [[ $__license_ok == "false" ]]; then
    cat << EOF
Splunk Enterprise
==============

  Available Options:

      - Launch container in Interactive mode "-it" to review and accept
        end user license agreement
      - If you have reviewed and accepted the license, start container
        with the environment variable:
            SPLUNK_START_ARGS=--accept-license

  Usage:

    docker run -it splunk/enterprise:6.4.1
    docker run --env SPLUNK_START_ARGS="--accept-license" splunk/enterprise:6.4.1

EOF
    exit 1
  fi

  if [[ $__configured == "false" ]]; then
    # If we have not configured yet allow user to specify some commands which can be executed before we start Splunk for the first time
    if [[ -n ${SPLUNK_BEFORE_START_CMD} ]]; then
      sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk ${SPLUNK_BEFORE_START_CMD}"
    fi
    for n in {1..30}; do
      if [[ -n $(eval echo \$\{SPLUNK_BEFORE_START_CMD_${n}\}) ]]; then
        sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk $(eval echo \$\{SPLUNK_BEFORE_START_CMD_${n}\})"
      else
        # We do not want to iterate all, if one in the sequence is not set
        break
      fi
    done
  fi

  sudo -HEu ${SPLUNK_USER} ${SPLUNK_HOME}/bin/splunk start ${SPLUNK_START_ARGS}
  trap "sudo -HEu ${SPLUNK_USER} ${SPLUNK_HOME}/bin/splunk stop" SIGINT SIGTERM EXIT

  # If this is first time we start this splunk instance
  if [[ $__configured == "false" ]]; then
    __restart_required=false

    # Setup deployment server
    if [[ ${SPLUNK_ENABLE_DEPLOY_SERVER} == "true" ]]; then
      sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk enable deploy-server -auth admin:changeme"
      __restart_required=true
    fi

    # Setup deployment client
    # http://docs.splunk.com/Documentation/Splunk/latest/Updating/Configuredeploymentclients
    if [[ -n ${SPLUNK_DEPLOYMENT_SERVER} ]]; then
      sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk set deploy-poll ${SPLUNK_DEPLOYMENT_SERVER} -auth admin:changeme"
      __restart_required=true
    fi

    # Setup Indexer Master - ARGS should be <label> -secret <secret>
    # http://docs.splunk.com/Documentation/Splunk/6.5.0/Indexer/ConfiguremasterwithCLI
    if [[ -n ${SPLUNK_ENABLE_INDEXER_MASTER} ]]; then
      echo "Enabling indexer master..."
      sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk edit cluster-config -mode master -cluster_label ${SPLUNK_ENABLE_INDEXER_MASTER_ARGS} -auth admin:changeme"
      __restart_required=true
      echo "indexer enabled! Splunk will be restarted to apply the changes."
    fi

    # Setup Indexer Peer - ARGS should be https://<master-hostname>:8089 -replication_port 9887 -secret <secret>
    # http://docs.splunk.com/Documentation/Splunk/6.5.0/Indexer/ConfigurepeerswithCLI
    if [[ -n ${SPLUNK_ENABLE_INDEXER_PEER} ]]; then
      echo "Enabling indexer peer..."
      sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk edit cluster-config -mode slave -master_uri ${SPLUNK_ENABLE_INDEXER_PEER_ARGS} -auth admin:changeme"
      __restart_required=true
      echo "indexer enabled! Splunk will be restarted to apply the changes."
    fi

    # Setup Search Head - ARGS should be https://<master_ip>:8089 -secret <secret>
    # http://docs.splunk.com/Documentation/Splunk/6.5.0/Indexer/ConfiguresearchheadwithCLI
    if [[ -n ${SPLUNK_ENABLE_SEARCHHEAD} ]]; then
      echo "Enabling search head and connecting it to indexer cluster..."
      sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk edit cluster-config -mode searchhead -master_uri ${SPLUNK_ENABLE_SEARCHHEAD_ARGS} -auth admin:changeme"
      __restart_required=true
      echo "search head enabled! Splunk will be restarted to apply the changes."
    fi

    # Setup Heavy Forwarder
    # http://docs.splunk.com/Documentation/Splunk/6.5.0/Forwarding/Deployaheavyforwarder
    if [[ -n ${SPLUNK_ENABLE_HEAVYFORWARDER} ]]; then
      echo "Enabling heavy forwarder..."
      sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk enable app SplunkForwarder -auth admin:changeme"
      sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk add forward-server ${SPLUNK_ENABLE_HEAVYFORWARDER_ARGS} -auth admin:changeme"
      __restart_required=true
      echo "heavy forwarder enabled! Splunk will be restarted to apply the changes."
    fi

    if [[ "$__restart_required" == "true" ]]; then
      sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk restart"
    fi

    # Setup listening
    # http://docs.splunk.com/Documentation/Splunk/latest/Forwarding/Enableareceiver
    if [[ -n ${SPLUNK_ENABLE_LISTEN} ]]; then
      sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk enable listen ${SPLUNK_ENABLE_LISTEN} -auth admin:changeme ${SPLUNK_ENABLE_LISTEN_ARGS}"
    fi

    # Setup forwarding server
    # http://docs.splunk.com/Documentation/Splunk/latest/Forwarding/Deployanixdfmanually
    if [[ -n ${SPLUNK_FORWARD_SERVER} ]]; then
      sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk add forward-server ${SPLUNK_FORWARD_SERVER} -auth admin:changeme ${SPLUNK_FORWARD_SERVER_ARGS}"
    fi
    for n in {1..10}; do
      if [[ -n $(eval echo \$\{SPLUNK_FORWARD_SERVER_${n}\}) ]]; then
        sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk add forward-server $(eval echo \$\{SPLUNK_FORWARD_SERVER_${n}\}) -auth admin:changeme $(eval echo \$\{SPLUNK_FORWARD_SERVER_${n}_ARGS\})"
      else
        # We do not want to iterate all, if one in the sequence is not set
        break
      fi
    done

    # Setup monitoring
    # http://docs.splunk.com/Documentation/Splunk/latest/Data/MonitorfilesanddirectoriesusingtheCLI
    # http://docs.splunk.com/Documentation/Splunk/latest/Data/Monitornetworkports
    if [[ -n ${SPLUNK_ADD} ]]; then
        sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk add ${SPLUNK_ADD} -auth admin:changeme"
    fi
    for n in {1..30}; do
      if [[ -n $(eval echo \$\{SPLUNK_ADD_${n}\}) ]]; then
        sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk add $(eval echo \$\{SPLUNK_ADD_${n}\}) -auth admin:changeme"
      else
        # We do not want to iterate all, if one in the sequence is not set
        break
      fi
    done

    # Execute anything
    if [[ -n ${SPLUNK_CMD} ]]; then
        sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk ${SPLUNK_CMD}"
    fi
    for n in {1..30}; do
      if [[ -n $(eval echo \$\{SPLUNK_CMD_${n}\}) ]]; then
        sudo -HEu ${SPLUNK_USER} sh -c "${SPLUNK_HOME}/bin/splunk $(eval echo \$\{SPLUNK_CMD_${n}\})"
      else
        # We do not want to iterate all, if one in the sequence is not set
        break
      fi
    done
  fi

  sudo -HEu ${SPLUNK_USER} tail -n 0 -f ${SPLUNK_HOME}/var/log/splunk/splunkd_stderr.log &
  wait
elif [ "$1" = 'splunk-bash' ]; then
  sudo -u ${SPLUNK_USER} /bin/bash --init-file ${SPLUNK_HOME}/bin/setSplunkEnv
else
  "$@"
fi

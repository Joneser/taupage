#!/bin/sh

#read taupage.yaml file
eval $(/opt/taupage/bin/parse-yaml.py /etc/taupage.yaml "config")

# lock task execution, only run once
mkdir /run/taupage-init-ran
if [ "$?" -ne 0 ]; then
    echo "ERROR: Aborting init process; init already ran."
    exit 0
fi

echo "INFO: Starting Taupage AMI init process.."
# save current timestamp,
# this timestamp is used has Taupage's boot time reference
date --utc --iso-8601=seconds | tee /run/taupage-init-ran/date
START_TIME=$(date +"%s")

# reset dir
cd $(dirname $0)

# general preparation
for script in $(ls init.d); do
    ./init.d/$script
    if [ "$?" -ne 0 ]; then
        echo "ERROR: Failed to start $script" >&2
        exit 1
    fi
done

if [ -z "$config_runtime" ]; then
    echo "ERROR: No runtime configuration found!" >&2
    exit 1
fi

# make sure there are no path hacks
RUNTIME=$(basename $config_runtime)

# figure out executable
RUNTIME_BIN=/opt/taupage/runtime/${RUNTIME}.py

if [ ! -f "$RUNTIME_BIN" ]; then
    echo "ERROR: Runtime '$RUNTIME' not found!" >&2
    exit 1
fi

# do magic!
$RUNTIME_BIN
result=$?

# run healthcheck if runtime returns successfully
if [ "$result" -eq 0 ]; then
    # run healthcheck if configured
    if [ -n "$config_healthcheck_type" ]; then

        # make sure there are no path hacks
        HEALTHCHECK=$(basename $config_healthcheck_type)

        # figure out executable
        HEALTHCHECK_BIN=/opt/taupage/healthcheck/${HEALTHCHECK}.py

        if [ ! -f "$HEALTHCHECK_BIN" ]; then
            echo "ERROR: Healthcheck '$HEALTHCHECK' not found!" >&2
            exit 1
        fi

        $HEALTHCHECK_BIN
        result=$?
    else
        echo "WARNING: No healthcheck configuration found!" >&2
    fi
fi

### notify cloud formation
if [ -z "$config_notify_cfn_stack" ] || [ -z "$config_notify_cfn_resource" ]; then
    echo "INFO: Skipping notification of CloudFormation."
else
    EC2_AVAIL_ZONE=$( curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone )
    EC2_REGION="$( echo \"$EC2_AVAIL_ZONE\" | sed -e 's:\([0-9][0-9]*\)[a-z]*\$:\\1:' )"

    echo "INFO: Notifying CloudFormation (region $EC2_REGION stack $config_notify_cfn_stack resource $config_notify_cfn_resource status $result)..."

    cfn-signal -e $result --stack $config_notify_cfn_stack --resource $config_notify_cfn_resource --region $EC2_REGION
fi

END_TIME=$(date +"%s")
ELAPSED_SECONDS=$(($END_TIME-$START_TIME))

if [ "$result" -eq 0 ]; then
    echo "SUCCESS: Initialization completed successfully in $ELAPSED_SECONDS seconds"
else
    echo "ERROR: $RUNTIME failed to start with exit code $result ($ELAPSED_SECONDS seconds elapsed)"
fi

# finished!
exit $result

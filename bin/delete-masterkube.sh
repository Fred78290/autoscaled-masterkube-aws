#!/bin/bash
CURDIR=$(dirname $0)
NODEGROUP_NAME="aws-ca-k8s"
MASTERKUBE=${NODEGROUP_NAME}-masterkube
CONTROLNODES=3
WORKERNODES=3
FORCE=NO
AWSDEFS=${CURDIR}/aws.defs

TEMP=$(getopt -o fg:p:r: --long aws-defs:,force,node-group:,profile:,region: -n "$0" -- "$@")

eval set -- "${TEMP}"

while true; do
    case "$1" in
        --aws-defs)
            AWSDEFS=$2
            if [ ! -f ${AWSDEFS} ]; then
                echo_red "AWS definitions: ${AWSDEFS} not found"
                exit 1
            fi
            shift 2
            ;;
        -f|--force)
            FORCE=YES
            shift 1
            ;;
        -p|--profile)
            AWS_PROFILE="$2"
            shift 2
            ;;
        -r|--region)
            AWS_REGION="$2"
            shift 2
            ;;
        -g|--node-group)
            NODEGROUP_NAME=$2
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "$1 - Internal error!"
            exit 1
            ;;
    esac
done

# import aws hidden definitions
source ${AWSDEFS}

function wait_jobs_finish() {
    while :
    do
        if test "$(jobs | wc -l)" -eq 0; then
            break
        fi

    wait -n
    done

    wait
}

function wait_instance_status() {
    local INSTANCE_ID=$1
    local STATUS=$2

    while [ ! $(aws ec2  describe-instances --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-ids "${INSTANCE_ID}" | jq -r '.Reservations[0].Instances[0].State.Code') -eq ${STATUS} ];
    do
        sleep 1
    done
}

function delete_instance_id() {
    local INSTANCE_ID=$1

    aws ec2 stop-instances --force --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-ids "${INSTANCE_ID}" &>/dev/null

    wait_instance_status $INSTANCE_ID 80

    aws ec2 terminate-instances --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-ids "${INSTANCE_ID}" &>/dev/null

    wait_instance_status $INSTANCE_ID 48

    echo "Terminated instance: ${INSTANCE_ID}"
}

pushd ${CURDIR}/../

if [ -f ./cluster/${NODEGROUP_NAME}/buildenv ]; then
    source ./cluster/${NODEGROUP_NAME}/buildenv
fi

echo "Delete masterkube ${MASTERKUBE} previous instance"

if [ "$(uname -s)" == "Linux" ]; then
    SED=sed
else
    SED=gsed
fi

if [ "$FORCE" = "YES" ]; then
    TOTALNODES=$((WORKERNODES + $CONTROLNODES))

    for NODEINDEX in $(seq 0 $TOTALNODES)
    do
        if [ $NODEINDEX = 0 ]; then
            MASTERKUBE_NODE="${MASTERKUBE}"
        elif [[ $NODEINDEX > $CONTROLNODES ]]; then
            NODEINDEX=$((NODEINDEX - $CONTROLNODES))
            MASTERKUBE_NODE="${NODEGROUP_NAME}-worker-0${NODEINDEX}"
        else
            MASTERKUBE_NODE="${NODEGROUP_NAME}-master-0${NODEINDEX}"
        fi

        INSTANCE=$(aws ec2  describe-instances --profile ${AWS_PROFILE} --region ${AWS_REGION} --filters "Name=tag:Name,Values=$MASTERKUBE_NODE" | jq -r '.Reservations[].Instances[]|select(.State.Code == 16)')
        INSTANCE_ID=$(echo $INSTANCE | jq -r '.InstanceId // ""')

        if [ ! -z "$INSTANCE_ID" ]; then
            echo "Delete VM: $MASTERKUBE_NODE"
            delete_instance_id "${INSTANCE_ID}" &
        fi

    done

elif [ -f ./cluster/${NODEGROUP_NAME}/config ]; then
    for INSTANCE_ID in $(kubectl get node -o json --kubeconfig ./cluster/${NODEGROUP_NAME}/config | jq '.items| .[] | .metadata.annotations["cluster.autoscaler.nodegroup/instance-id"]' | tr -d '"')
    do
        echo "Delete Instance ID: $INSTANCE_ID"
            delete_instance_id "${INSTANCE_ID}" &
    done

    INSTANCE=$(aws ec2  describe-instances --profile ${AWS_PROFILE} --region ${AWS_REGION} --filters "Name=tag:Name,Values=$MASTERKUBE" | jq -r '.Reservations[].Instances[]|select(.State.Code == 16)')
    INSTANCE_ID=$(echo $INSTANCE | jq -r '.InstanceId // ""')

    if [ ! -z "$INSTANCE_ID" ]; then
        echo "Delete Instance ID: $INSTANCE_ID"
        delete_instance_id "${INSTANCE_ID}" &
    fi
fi

# Delete all alive instances
for FILE in ./config/${NODEGROUP_NAME}/instance-*.json
do
    if [ -f $FILE ]; then
        INSTANCE=$(cat $FILE)
        INSTANCE_ID=$(echo $INSTANCE | jq -r '.InstanceId // ""')

        if [ ! -z "$INSTANCE_ID" ]; then
            STATUSCODE=$(aws ec2  describe-instances --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-ids "${INSTANCE_ID}" | jq -r '.Reservations[0].Instances[0].State.Code//"48"')

            if [ ${STATUSCODE} -eq 16 ]; then
                echo "Delete Instance ID: $INSTANCE_ID"
                delete_instance_id "${INSTANCE_ID}" &
            fi
        fi
    fi
done

wait_jobs_finish

./bin/delete-aws-nlb.sh --profile ${AWS_PROFILE} --region ${AWS_REGION} --name nlb-${MASTERKUBE}

# Delete DNS entries
for FILE in config/${NODEGROUP_NAME}/dns-*.json
do
    if [ -f $FILE ]; then
        DNS=$(cat $FILE | jq '.Changes[0].Action = "DELETE"')
        echo $DNS | jq . > $FILE

        aws route53 change-resource-record-sets --profile ${AWS_PROFILE_ROUTE53} --region ${AWS_REGION} \
            --hosted-zone-id ${ROUTE53_ZONEID} \
            --change-batch file://${FILE} &> /dev/null
    fi
done

# Delete ENI entries
for FILE in config/${NODEGROUP_NAME}/eni-*.json
do
    if [ -f $FILE ]; then
        ENI=$(cat $FILE | jq -r '.NetworkInterfaceId')
        echo "Delete ENI: ${ENI}"
        aws ec2 delete-network-interface --profile ${AWS_PROFILE} --region ${AWS_REGION} --network-interface-id ${ENI} &> /dev/null
    fi
done

./bin/kubeconfig-delete.sh $MASTERKUBE $NODEGROUP_NAME &> /dev/null

if [ -f ./config/${NODEGROUP_NAME}/aws-autoscaler.pid ]; then
    kill $(cat ./config/${NODEGROUP_NAME}/aws-autoscaler.pid)
fi

rm -rf ./cluster/${NODEGROUP_NAME}
rm -rf ./config/${NODEGROUP_NAME}

popd
#!/bin/bash
CURDIR=$(dirname $0)
NODEGROUP_NAME="aws-ca-rke2"
MASTERKUBE=${NODEGROUP_NAME}-masterkube
CONTROLNODES=3
WORKERNODES=3
FORCE=NO

source ${CURDIR}/common.sh

pushd ${CURDIR}/../ &> /dev/null

AWSDEFS=${PWD}/bin/aws.defs
CONFIGURATION_LOCATION=${PWD}

TEMP=$(getopt -o fg:p:r: --long configuration-location:,aws-defs:,force,node-group:,profile:,region: -n "$0" -- "$@")

eval set -- "${TEMP}"

while true; do
    case "$1" in
        --aws-defs)
            AWSDEFS=$2
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
        --configuration-location)
            CONFIGURATION_LOCATION=$2
            if [ ! -d ${CONFIGURATION_LOCATION} ]; then
                echo_red "kubernetes output : ${CONFIGURATION_LOCATION} not found"
                exit 1
            fi
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo_red "$1 - Internal error!"
            exit 1
            ;;
    esac
done

if [ ! -f ${AWSDEFS} ]; then
	echo_red "AWS definitions: ${AWSDEFS} not found"
	exit 1
fi

# import aws hidden definitions
source ${AWSDEFS}

TARGET_CONFIG_LOCATION=${CONFIGURATION_LOCATION}/config/${NODEGROUP_NAME}/config
TARGET_DEPLOY_LOCATION=${CONFIGURATION_LOCATION}/config/${NODEGROUP_NAME}/deployment
TARGET_CLUSTER_LOCATION=${CONFIGURATION_LOCATION}/cluster/${NODEGROUP_NAME}

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

    echo_blue_bold "Terminated instance: ${INSTANCE_ID}"
}

if [ -f ${TARGET_CONFIG_LOCATION}/buildenv ]; then
    source ${TARGET_CONFIG_LOCATION}/buildenv
fi

echo_title "Delete masterkube ${MASTERKUBE} previous instance"

if [ "$FORCE" = "YES" ]; then
    TOTALNODES=$((WORKERNODES + $CONTROLNODES))

    for NODEINDEX in $(seq 0 $TOTALNODES)
    do
        if [ $NODEINDEX -eq 0 ]; then
            MASTERKUBE_NODE="${MASTERKUBE}"
        elif [ $NODEINDEX -gt $CONTROLNODES ]; then
            NODEINDEX=$((NODEINDEX - $CONTROLNODES))
            MASTERKUBE_NODE="${NODEGROUP_NAME}-worker-0${NODEINDEX}"
        else
            MASTERKUBE_NODE="${NODEGROUP_NAME}-master-0${NODEINDEX}"
        fi

        INSTANCE=$(aws ec2  describe-instances --profile ${AWS_PROFILE} --region ${AWS_REGION} --filters "Name=tag:Name,Values=$MASTERKUBE_NODE" | jq -r '.Reservations[].Instances[]|select(.State.Code == 16)')
        INSTANCE_ID=$(echo $INSTANCE | jq -r '.InstanceId // ""')

        if [ -n "$INSTANCE_ID" ]; then
            echo_blue_bold "Delete VM: $MASTERKUBE_NODE"
            delete_instance_id "${INSTANCE_ID}" &
        fi

    done

elif [ -f ${TARGET_CLUSTER_LOCATION}/config ]; then
    for INSTANCE_ID in $(kubectl get node -o json --kubeconfig ${TARGET_CLUSTER_LOCATION}/config | jq -r '.items| .[] | .metadata.annotations["cluster.autoscaler.nodegroup/instance-id"]')
    do
        echo_blue_bold "Delete k8s node Instance ID: $INSTANCE_ID"
        delete_instance_id "${INSTANCE_ID}" &
    done

    sleep 5

    INSTANCE=$(aws ec2  describe-instances --profile ${AWS_PROFILE} --region ${AWS_REGION} --filters "Name=tag:Name,Values=$MASTERKUBE" | jq -r '.Reservations[].Instances[]|select(.State.Code == 16)')
    INSTANCE_ID=$(echo $INSTANCE | jq -r '.InstanceId // ""')

    if [ -n "$INSTANCE_ID" ]; then
        echo_blue_bold "Delete simple Instance ID: $INSTANCE_ID"
        delete_instance_id "${INSTANCE_ID}" &
    fi
fi

sleep 5
# Delete all alive instances
for FILE in ${TARGET_CONFIG_LOCATION}/instance-*.json
do
    if [ -f $FILE ]; then
        INSTANCE=$(cat $FILE)
        INSTANCE_ID=$(echo $INSTANCE | jq -r '.InstanceId // ""')

        if [ -n "$INSTANCE_ID" ]; then
            STATUSCODE=$(aws ec2  describe-instances --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-ids "${INSTANCE_ID}" | jq -r '.Reservations[0].Instances[0].State.Code//"48"')

            if [ ${STATUSCODE} -eq 16 ]; then
                echo_blue_bold "Delete Instance ID: $INSTANCE_ID"
                delete_instance_id "${INSTANCE_ID}" &
            fi
        fi
    fi
done

wait_jobs_finish

./bin/delete-aws-nlb.sh --profile ${AWS_PROFILE} --region ${AWS_REGION} --name ${MASTERKUBE}

# Delete DNS entries
for FILE in ${TARGET_CONFIG_LOCATION}/dns-*.json
do
    if [ -f $FILE ]; then
        DNS=$(cat $FILE | jq '.Changes[0].Action = "DELETE"')
        DNSNAME=$(echo $DNS | jq -r '.Changes[0].ResourceRecordSet.Name')

        echo $DNS | jq . > $FILE

        echo_blue_bold "Delete DNS entry: ${DNSNAME}"
        if [[ "${DNSNAME}" == *.${PUBLIC_DOMAIN_NAME} ]]; then
            ZONEID=${AWS_ROUTE53_PUBLIC_ZONE_ID}
        else
            ZONEID=${AWS_ROUTE53_ZONE_ID}
        fi

        aws route53 change-resource-record-sets --profile ${AWS_PROFILE_ROUTE53} --region ${AWS_REGION} \
            --hosted-zone-id ${ZONEID} \
            --change-batch file://${FILE} &> /dev/null
        delete_host "${DNSNAME}"
    fi
done

# Delete ENI entries
for FILE in ${TARGET_CONFIG_LOCATION}/eni-*.json
do
    if [ -f $FILE ]; then
        ENI=$(cat $FILE | jq -r '.NetworkInterfaceId')
        echo_blue_bold "Delete ENI: ${ENI}"
        aws ec2 delete-network-interface --profile ${AWS_PROFILE} --region ${AWS_REGION} --network-interface-id ${ENI} &> /dev/null
    fi
done

if [ -n "${GODADDY_API_KEY}" ] && [ -n "${PUBLIC_DOMAIN_NAME}" ] && [ -z "${AWS_ROUTE53_PUBLIC_ZONE_ID}" ]; then
    echo_blue_bold "Delete DNS ${MASTERKUBE} in godaddy"

    if [ "${USE_NLB}" = "YES" ]; then
        curl -s -X DELETE -H "Authorization: sso-key ${GODADDY_API_KEY}:${GODADDY_API_SECRET}" "https://api.godaddy.com/v1/domains/${PUBLIC_DOMAIN_NAME}/records/CNAME/${MASTERKUBE}" > /dev/null
    else
        curl -s -X DELETE -H "Authorization: sso-key ${GODADDY_API_KEY}:${GODADDY_API_SECRET}" "https://api.godaddy.com/v1/domains/${PUBLIC_DOMAIN_NAME}/records/A/${MASTERKUBE}" > /dev/null
    fi

    echo_blue_bold "Delete DNS ${DASHBOARD_HOSTNAME} in godaddy"
    curl -s -X DELETE -H "Authorization: sso-key ${GODADDY_API_KEY}:${GODADDY_API_SECRET}" "https://api.godaddy.com/v1/domains/${PUBLIC_DOMAIN_NAME}/records/CNAME/${DASHBOARD_HOSTNAME}" > /dev/null

    echo_blue_bold "Delete DNS helloworld-aws in godaddy"
    curl -s -X DELETE -H "Authorization: sso-key ${GODADDY_API_KEY}:${GODADDY_API_SECRET}" "https://api.godaddy.com/v1/domains/${PUBLIC_DOMAIN_NAME}/records/CNAME/helloworld-aws" > /dev/null
fi

./bin/kubeconfig-delete.sh $MASTERKUBE $NODEGROUP_NAME &> /dev/null

if [ -f ${TARGET_CONFIG_LOCATION}/aws-autoscaler.pid ]; then
    kill $(cat ${TARGET_CONFIG_LOCATION}/aws-autoscaler.pid)
fi

rm -rf ${TARGET_CLUSTER_LOCATION}
rm -rf ${TARGET_CONFIG_LOCATION}
rm -rf ${TARGET_DEPLOY_LOCATION}

popd &> /dev/null

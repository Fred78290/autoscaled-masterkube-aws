#!/bin/bash
CURDIR=$(dirname $0)
FORCE=NO

source $CURDIR/common.sh

pushd ${CURDIR}/../ &>/dev/null

CONFIGURATION_LOCATION=${PWD}

TEMP=$(getopt -o ftg:p:r: --long trace,configuration-location:,defs:,force,node-group:,profile:,region: -n "$0" -- "$@")

eval set -- "${TEMP}"

while true; do
    case "$1" in
        --defs)
            SCHEMEDEFS=$2
            if [ ! -f ${SCHEMEDEFS} ]; then
                echo_red "definitions: ${SCHEMEDEFS} not found"
                exit 1
            fi
            shift 2
            ;;
        -f|--force)
            FORCE=YES
            shift 1
            ;;
        -t|--trace)
            TRACE=YES
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
                echo_red_bold "kubernetes output : ${CONFIGURATION_LOCATION} not found"
                exit 1
            fi
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo_red_bold "$1 - Internal error!"
            exit 1
            ;;
    esac
done

source ${SCHEMEDEFS}

if [ "${TRACE}" = "YES" ]; then
    set -x
fi

TARGET_CONFIG_LOCATION=${CONFIGURATION_LOCATION}/config/${NODEGROUP_NAME}/config
TARGET_DEPLOY_LOCATION=${CONFIGURATION_LOCATION}/config/${NODEGROUP_NAME}/deployment
TARGET_CLUSTER_LOCATION=${CONFIGURATION_LOCATION}/cluster/${NODEGROUP_NAME}

echo_blue_bold "Delete masterkube ${MASTERKUBE} previous instance"

if [ -f ${TARGET_CONFIG_LOCATION}/buildenv ]; then
    source ${TARGET_CONFIG_LOCATION}/buildenv
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

		delete_vm_by_name ${MASTERKUBE_NODE}
    done

elif [ -f ${TARGET_CLUSTER_LOCATION}/config ]; then
    WORKERNODES=$(kubectl get node -o json --kubeconfig ${TARGET_CLUSTER_LOCATION}/config | jq -r '.items |reverse | .[] | select(.metadata.labels["node-role.kubernetes.io/worker"]) | .metadata.name')

    for NODE in $WORKERNODES
    do
		delete_vm_by_name ${NODE}
    done
	delete_vm_by_name ${MASTERKUBE}
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
                delete_instance "${INSTANCE_ID}" &
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

if [ -f ${TARGET_CONFIG_LOCATION}/autoscaler.pid ]; then
    kill ${TARGET_CONFIG_LOCATION}/autoscaler.pid
fi

rm -rf ${TARGET_CLUSTER_LOCATION}
rm -rf ${TARGET_CONFIG_LOCATION}
rm -rf ${TARGET_DEPLOY_LOCATION}

delete_host "${MASTERKUBE}"
delete_host "masterkube-${SCHEME}"

popd &>/dev/null

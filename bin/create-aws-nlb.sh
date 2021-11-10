#!/bin/bash
set -e

AWS_PROFILE=
AWS_REGION=
AWS_VPCID=
AWS_PRIVATE_SUBNETID=()
AWS_PUBLIC_SUBNETID=()
AWS_SECURITY_GROUP=
AWS_INSTANCES_ID=
AWS_CERT_ARN=
AWS_NLB_PORT=6443
AWS_TARGET_PORT=6443
AWS_NLB_NAME=
AWS_USE_PUBLICIP=false

function echo_red() {
	# echo message in red
	echo -e "\e[31m$1\e[39m"
}

TEMP=`getopt -o n:p:r:s:x --long cert-arn:,trace,expose-public:,name:,profile:,region:,target-vpc-id:,private-subnet-id:,public-subnet-id:,nlb-port:,target-port:,security-group:,instances-id: -n "$0" -- "$@"`
eval set -- "$TEMP"

# extract options and their arguments into variables.
while true ; do
	#echo "1:$1"
    case "$1" in
        -x|--trace)
            set -x
            shift 1
            ;;
        --name)
            AWS_NLB_NAME="$2"
            shift 2
            ;;
        --expose-public)
            AWS_USE_PUBLICIP="$2"
            shift 2
            ;;
        --profile)
            AWS_PROFILE="$2"
            shift 2
            ;;
        --region)
            AWS_REGION="$2"
            shift 2
            ;;
        --cert-arn)
            AWS_CERT_ARN="$2"
            shift 2
            ;;
        --security-group)
            AWS_SECURITY_GROUP="$2"
            shift 2
            ;;
        --instances-id)
            IFS=, read -a AWS_INSTANCES_ID <<< $2
            shift 2
            ;;
        --public-subnet-id)
            IFS=, read -a AWS_PUBLIC_SUBNETID <<< $2
            shift 2
            ;;
        --private-subnet-id)
            IFS=, read -a AWS_PRIVATE_SUBNETID <<< $2
            shift 2
            ;;
        --nlb-port)
            AWS_NLB_PORT="$2"
            shift 2
            ;;
        --target-vpc-id)
            AWS_VPCID="$2"
            shift 2
            ;;
        --target-port)
            AWS_TARGET_PORT="$2"
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

if [ -z $AWS_NLB_NAME ]; then
    echo_red "subnet is not defined"
    exit -1
fi

if [ ${#AWS_PUBLIC_SUBNETID[@]} -eq 0 ]; then
    echo_red "public subnet is not defined"
    exit -1
fi

if [ ${#AWS_PRIVATE_SUBNETID[@]} -eq 0 ]; then
    echo_red "private subnet is not defined"
    exit -1
fi

if [ -z $AWS_SECURITY_GROUP ]; then
    echo_red "security group is not defined"
    exit -1
fi

if [ -z $AWS_CERT_ARN ]; then
    echo_red "certificat arn is not defined"
    exit -1
fi

if [ ${#AWS_INSTANCES_ID[@]} -eq 0 ]; then
    echo_red "instances is not defined"
    exit -1
fi

# Extract IP
for INSTANCE in $(aws ec2  describe-instances --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-ids ${AWS_INSTANCES_ID[*]} | jq '.Reservations[].Instances[].PrivateIpAddress')
do
    INSTANCES+=("Id=$INSTANCE")
done

function create_nlb() {
    local NLB_NAME=$1
    local SCHEME=$2
    local AWS_SUBNETID=$3
    local TARGET_PORTS=$4
    local TYPE=$5
    local NLB_ARN
    local TARGET_ARN
    local TARGET_PORT

    if [ $TYPE == "network" ]; then
        NLB_ARN=$(aws elbv2 create-load-balancer --profile=${AWS_PROFILE} --region=${AWS_REGION} --name ${NLB_NAME} --scheme ${SCHEME} --type ${TYPE} --subnets ${AWS_SUBNETID} | jq -r '.LoadBalancers[0].LoadBalancerArn')
    else
        NLB_ARN=$(aws elbv2 create-load-balancer --profile=${AWS_PROFILE} --region=${AWS_REGION} --name ${NLB_NAME} --security-groups ${AWS_SECURITY_GROUP} --scheme ${SCHEME} --type ${TYPE} --subnets ${AWS_SUBNETID} | jq -r '.LoadBalancers[0].LoadBalancerArn')
    fi

    for TARGET_PORT in $TARGET_PORTS
    do

        local CERTIFICAT_ARGS=
        local PROTOCOL=

        if [ $TYPE == "network" ]; then
            PROTOCOL=TCP
       elif [ "${TARGET_PORT}" = "80" ]; then
            PROTOCOL=HTTP
        else
            PROTOCOL=HTTPS
            CERTIFICAT_ARGS="--certificates CertificateArn=${AWS_CERT_ARN}"
        fi

        TARGET_ARN=$(aws elbv2 create-target-group --profile=${AWS_PROFILE} --region=${AWS_REGION} \
            --name ${NLB_NAME}-${TARGET_PORT} --protocol ${PROTOCOL} \
            --port ${TARGET_PORT} \
            --vpc-id ${AWS_VPCID} \
            --target-type ip | jq -r '.TargetGroups[0].TargetGroupArn')

        aws elbv2 register-targets --profile=${AWS_PROFILE} --region=${AWS_REGION} --target-group-arn ${TARGET_ARN} --targets ${INSTANCES[*]} > /dev/null

        aws elbv2 create-listener ${CERTIFICAT_ARGS} \
            --profile=${AWS_PROFILE} \
            --region=${AWS_REGION} \
            --load-balancer-arn ${NLB_ARN} \
            --protocol ${PROTOCOL} \
            --port ${TARGET_PORT} \
            --default-actions Type=forward,TargetGroupArn=${TARGET_ARN} > /dev/null
    done

    echo $NLB_ARN
}

if [ $AWS_USE_PUBLICIP = "true" ]; then
    create_nlb "p-${AWS_NLB_NAME}" internet-facing "${AWS_PUBLIC_SUBNETID[*]}" "80 443" network
fi

NLB_ARN=$(create_nlb "${AWS_NLB_NAME}" internal "${AWS_PRIVATE_SUBNETID[*]}" "${AWS_TARGET_PORT}" network)

echo -n "Wait NLB to start $NLB_ARN"

while [ "$(echo "$NBL_DESCRIBE" | jq -r '.LoadBalancers[0].State.Code // ""')" != "active" ];
do
    echo -n .
    sleep 1
    NBL_DESCRIBE=$(aws elbv2 describe-load-balancers --profile=${AWS_PROFILE} --region=${AWS_REGION} --load-balancer-arns ${NLB_ARN})
done

echo
#/bin/bash

# This script create every thing to deploy a simple kubernetes autoscaled cluster with aws.
# It will generate:
# Custom AMI image with every thing for kubernetes
# Config file to deploy the cluster autoscaler.

set -e

CURDIR=$(dirname $0)

export SCHEME="aws"
export NODEGROUP_NAME="aws-ca-k8s"
export MASTERKUBE="${NODEGROUP_NAME}-masterkube"
export SSH_PRIVATE_KEY=~/.ssh/id_rsa
export SSH_PUBLIC_KEY="${SSH_PRIVATE_KEY}.pub"
export KUBERNETES_VERSION=v1.21.4
export KUBECONFIG=${HOME}/.kube/config
export ROOT_IMG_NAME=focal-k8s
export CNI_PLUGIN_VERSION=v1.0.1
export CNI_PLUGIN=aws
export CLOUD_PROVIDER=aws
export USE_NLB=NO
export HA_CLUSTER=false
export FIRSTNODE_INDEX=0
export CONTROLNODES=1
export WORKERNODES=3
export MINNODES=0
export MAXNODES=9
export MAXTOTALNODES=${MAXNODES}
export CORESTOTAL="0:16"
export MEMORYTOTAL="0:48"
export MAXAUTOPROVISIONNEDNODEGROUPCOUNT="1"
export SCALEDOWNENABLED="true"
export SCALEDOWNDELAYAFTERADD="1m"
export SCALEDOWNDELAYAFTERDELETE="1m"
export SCALEDOWNDELAYAFTERFAILURE="1m"
export SCALEDOWNUNEEDEDTIME="1m"
export SCALEDOWNUNREADYTIME="1m"
export DEFAULT_MACHINE="t3a.medium"
export NGINX_MACHINE="t3a.small"
export UNREMOVABLENODERECHECKTIMEOUT="1m"
export OSDISTRO=$(uname -s)
export TRANSPORT="tcp"
export SSH_KEYNAME="aws-k8s-key"
export VOLUME_SIZE=10
export MAX_PODS=110
export MASTER_PROFILE_NAME="kubernetes-master-profile"
export WORKER_PROFILE_NAME="kubernetes-worker-profile"
export TARGET_IMAGE="${ROOT_IMG_NAME}-cni-${CNI_PLUGIN}-${KUBERNETES_VERSION}-${CONTAINER_ENGINE}-${SEED_ARCH}"
export REGISTRY=fred78290
export RESUME=NO
export EXTERNAL_ETCD=false
export CONTAINER_ENGINE=containerd
export SILENT="&> /dev/null"

# aws region eu-west1
export SEED_ARCH=amd64
export SEED_USER=ubuntu
export SEED_IMAGE_AMD64="ami-08bac620dc84221eb"
export SEED_IMAGE_ARM64="ami-09e0d6fdf60750e33"

# defined in private aws.defs
export AWSDEFS=${CURDIR}/aws.defs
export MASTER_INSTANCE_PROFILE_ARN="<to be filled>"
export WORKER_INSTANCE_PROFILE_ARN="<to be filled>"
export VPC_PUBLIC_SUBNET_ID="<to be filled>"
export VPC_PUBLIC_SECURITY_GROUPID="<to be filled>"
export VPC_PRIVATE_SUBNET_ID="<to be filled>"
export VPC_PRIVATE_SECURITY_GROUPID="<to be filled>"
export ROUTE53_ZONEID="<to be filled>"

export EXPOSE_PUBLIC_CLUSTER=true
export CONTROLPLANE_USE_PUBLICIP=true
export WORKERNODE_USE_PUBLICIP=false

export LAUNCH_CA=YES
export PRIVATE_DOMAIN_NAME=

VPC_PUBLIC_SUBNET_IDS=()
VPC_PRIVATE_SUBNET_IDS=()
LAUNCHED_INSTANCES=()
IPADDRS=()

# import hidded definitions
source ${AWSDEFS}

SSH_OPTIONS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
SCP_OPTIONS="${SSH_OPTIONS} -r"

if [ "$(uname -s)" == "Linux" ]; then
    SED=sed
else
    SED=gsed
fi

function verbose() {
    if [ ${VERBOSE} = "YES" ]; then
        eval "$1"
    else
        eval "$1 &> /dev/null"
    fi
}

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

function echo_blue_dot() {
	echo -n -e "\e[90m\e[39m\e[1m\e[34m.\e[0m\e[39m"
}

function echo_blue_dot_title() {
	# echo message in blue and bold
	echo -n -e "\e[90m= \e[39m\e[1m\e[34m$1\e[0m\e[39m"
}

function echo_blue_bold() {
	# echo message in blue and bold
	echo -e "\e[90m= \e[39m\e[1m\e[34m$1\e[0m\e[39m"
}

function echo_title() {
	# echo message in blue and bold
    echo_line
	echo_blue_bold "$1"
    echo_line
}

function echo_grey() {
	# echo message in light grey
	echo -e "\e[90m$1\e[39m"
}

function echo_red() {
	# echo message in red
	echo -e "\e[31m$1\e[39m"
}

function echo_separator() {
    echo_line
	echo
	echo
}

function echo_line() {
	echo_grey "============================================================================================================================="
}

function usage() {
cat <<EOF
$0 create a kubernetes simple cluster or HA cluster with 3 control planes
Options are:
--help | -h                                      # Display usage
--verbose | -v                                   # Verbose
--resume | -r                                    # Allow resume interrupted creation of cluster kubernetes
--trace | -x                                     # Trace execution
--create-image-only                              # Create image only

### Flags to set AWS informations

--profile | -p=<value>                           # Specify AWS profile, default ${AWS_PROFILE}
--route53-profile=<value>                        # Specify AWS profile for route53, default ${AWS_PROFILE_ROUTE53}
--region | -r=<value>                            # Specify AWS region, default ${AWS_REGION}

### Design the kubernetes cluster

--ha-cluster | -c                                # Allow to create an HA cluster, default ${HA_CLUSTER}
--worker-nodes=<value>                           # Specify the number of worker node created in HA cluster, default ${WORKERNODES}
--container-runtime=<docker|containerd|cri-o>    # Specify which OCI runtime to use, default ${CONTAINER_ENGINE}
--internet-facing/--no-internet-facing           # Specify if the cluster is exposed on internet port: 80 443, default ${EXPOSE_PUBLIC_CLUSTER}
--max-pods                                       # Specify the max pods per created VM, default ${MAX_PODS}

### Flags in single master node only

--control-plane-public/--no-control-plane-public # Specify if master is hosted in public subnet, default ${CONTROLPLANE_USE_PUBLICIP}
--worker-node-public/--no-worker-node-public     # Specify if worker nodes asre hosted in public subnet, default ${WORKERNODE_USE_PUBLICIP}

### Flags in ha mode only

--create-external-etcd | -e                      # Allow to create an external HA etcd cluster, default ${EXTERNAL_ETCD}
--use-nlb | -u                                   # Allow to use AWS ELB as load balancer else NGINX is used in public vpc

### Flags in both mode

--default-machine | -d=<value>                   # Override machine type used for auto scaling, default ${DEFAULT_MACHINE}
--ssh-private-key | -s=<value>                   # Override ssh key is used, default ${SSH_PRIVATE_KEY}
--transport | -t=<value>                         # Override the transport to be used between autoscaler and aws-autoscaler, default ${TRANSPORT}
--no-cloud-provider                              # Set cloud provider to none, default $CLOUD_PROVIDER
--node-group=<value>                             # Override the node group name, default ${NODEGROUP_NAME}
--cni-plugin-version=<value>                     # Override CNI plugin version, default: ${CNI_PLUGIN_VERSION}
--cni-plugin=<value>                             # Override CNI plugin, default: ${CNI_PLUGIN}
--kubernetes-version | -k=<value>                # Override the kubernetes version, default ${KUBERNETES_VERSION}
--volume-type                                    # Override the root EBS volume type, default ${VOLUME_TYPE}
--volume-size                                    # Override the root EBS volume size in Gb, default ${VOLUME_SIZE}

### Flags to configure network in aws

--public-subnet-id                               # Specify the public subnet ID for created VM, default ${VPC_PUBLIC_SUBNET_ID}
--public-sg-id                                   # Specify the public security group ID for VM, default ${VPC_PUBLIC_SECURITY_GROUPID}
--private-subnet-id                              # Specify the private subnet ID for created VM, default ${VPC_PRIVATE_SUBNET_ID}
--private-sg-id                                  # Specify the private security group ID for VM, default ${VPC_PRIVATE_SECURITY_GROUPID}

### Flags to set the template vm

--target-image=<value>                           # Override the prefix template VM image used for created VM, default ${ROOT_IMG_NAME}
--seed-image=<value>                             # Override the seed image name used to create template, default ${SEED_IMAGE}
--seed-user=<value>                              # Override the seed user in template, default ${SEED_USER}
--arch | -a=<value>                              # Specify the architecture of VM (amd64|arm64), default ${SEED_ARCH}

### Flags for autoscaler

--max-nodes-total=<value>                        # autoscaler flag, default: ${MAXTOTALNODES}
--cores-total=<value>                            # autoscaler flag, default: ${CORESTOTAL}
--memory-total=<value>                           # autoscaler flag, default: ${MEMORYTOTAL}
--max-autoprovisioned-node-group-count=<value>   # autoscaler flag, default: ${MAXAUTOPROVISIONNEDNODEGROUPCOUNT}
--scale-down-enabled=<value>                     # autoscaler flag, default: ${SCALEDOWNENABLED}
--scale-down-delay-after-add=<value>             # autoscaler flag, default: ${SCALEDOWNDELAYAFTERADD}
--scale-down-delay-after-delete=<value>          # autoscaler flag, default: ${SCALEDOWNDELAYAFTERDELETE}
--scale-down-delay-after-failure=<value>         # autoscaler flag, default: ${SCALEDOWNDELAYAFTERFAILURE}
--scale-down-unneeded-time=<value>               # autoscaler flag, default: ${SCALEDOWNUNEEDEDTIME}
--scale-down-unready-time=<value>                # autoscaler flag, default: ${SCALEDOWNUNREADYTIME}
--unremovable-node-recheck-timeout=<value>       # autoscaler flag, default: ${UNREMOVABLENODERECHECKTIMEOUT}
EOF
}

TEMP=$(getopt -o xvhrceuwa::p:r:k:n:p:s:t: --long aws-defs:,container-runtime:,cni-plugin:,trace,help,verbose,resume,ha-cluster,create-external-etcd,use-nlb,worker-nodes:,arch:,cloud-provider:,max-pods:,profile:,region:,node-group:,target-image:,seed-image:,seed-user:,vpc-id:,public-subnet-id:,public-sg-id:,private-subnet-id:,private-sg-id:,transport:,ssh-private-key:,cni-plugin-version:,kubernetes-version:,max-nodes-total:,cores-total:,memory-total:,max-autoprovisioned-node-group-count:,scale-down-enabled:,scale-down-delay-after-add:,scale-down-delay-after-delete:,scale-down-delay-after-failure:,scale-down-unneeded-time:,scale-down-unready-time:,unremovable-node-recheck-timeout: -n "$0" -- "$@")

eval set -- "${TEMP}"

# extract options and their arguments into variables.
while true; do
    case "$1" in
    -h|--help)
        usage
        exit 0
        ;;
    -v|--verbose)
        SILENT=
        shift 1
        ;;
    -x|--trace)
        set -x
        shift 1
        ;;
    -r|--resume)
        RESUME=YES
        shift 1
        ;;
    --no-cloud-provider)
        CLOUD_PROVIDER=""
        shift 1
        ;;
    --aws-defs)
        AWSDEFS=$2
        if [ -f ${AWSDEFS} ]; then
            source ${AWSDEFS}
        else
            echo_red "AWS definitions: ${AWSDEFS} not found"
            exit 1
        fi
        shift 2
        ;;
    -c|--ha-cluster)
        HA_CLUSTER=true
        CONTROLNODES=3
        shift 1
        ;;
    -e|--create-external-etcd)
        EXTERNAL_ETCD=true
        shift 1
        ;;
    -u|--use-nlb)
        USE_NLB=YES
        shift 1
        ;;
    --worker-nodes)
        WORKERNODES=$2
        shift 2
        ;;
    --volume-size)
        VOLUME_SIZE=$2
        shift 2
        ;;
    --volume-type)
        VOLUME_TYPE=$2
        shift 2
        ;;
    --internet-facing)
        EXPOSE_PUBLIC_CLUSTER=true
        shift 1
        ;;

    --no-internet-facing)
        EXPOSE_PUBLIC_CLUSTER=false
        shift 1
        ;;

    --control-plane-public)
        CONTROLPLANE_USE_PUBLICIP=true
        shift 1
        ;;

    --no-control-plane-public)
        CONTROLPLANE_USE_PUBLICIP=false
        shift 1
        ;;

    --worker-node-public)
        WORKERNODE_USE_PUBLICIP=true
        shift 1
        ;;

    --no-worker-node-public)
        WORKERNODE_USE_PUBLICIP=false
        shift 1
        ;;

    --container-runtime)
        case "$2" in
            "docker"|"cri-o"|"containerd")
                CONTAINER_ENGINE="$2"
                ;;
            *)
                echo "Unsupported container runtime: $2"
                exit 1
                ;;
        esac
        shift 2;;

    -p|--profile)
        AWS_PROFILE="$2"
        shift 2
        ;;
    -r|--region)
        AWS_REGION="$2"
        shift 2
        ;;

    --max-pods)
        MAX_PODS=$2
        shift 2
        ;;

    --node-group)
        NODEGROUP_NAME="$2"
        MASTERKUBE="${NODEGROUP_NAME}-masterkube"
        shift 2
        ;;

    --target-image)
        ROOT_IMG_NAME="$2"
        shift 2
        ;;

    -a|--arch)
        SEED_ARCH=$2
        shift 2
        ;;

    --seed-image)
        SEED_IMAGE="$2"
        shift 2
        ;;

    --seed-user)
        SEED_USER="$2"
        shift 2
        ;;

    --public-subnet-id)
        VPC_PUBLIC_SUBNET_ID="$2"
        shift 2
        ;;

    --public-sg-id)
        VPC_PUBLIC_SECURITY_GROUPID="$2"
        shift 2
        ;;

    --private-subnet-id)
        VPC_PRIVATE_SUBNET_ID="$2"
        shift 2
        ;;

    --private-sg-id)
        VPC_PRIVATE_SECURITY_GROUPID="$2"
        shift 2
        ;;

    -d | --default-machine)
        DEFAULT_MACHINE="$2"
        shift 2
        ;;
    -s | --ssh-private-key)
        SSH_PRIVATE_KEY=$2
        shift 2
        ;;
    --cni-plugin-version)
        CNI_PLUGIN_VERSION="$2"
        shift 2
        ;;
    --cni-plugin)
        CNI_PLUGIN="$2"
        shift 2
        ;;
    -t | --transport)
        TRANSPORT="$2"
        shift 2
        ;;
    -k | --kubernetes-version)
        KUBERNETES_VERSION="$2"
        shift 2
        ;;

    # Same argument as cluster-autoscaler
    --max-nodes-total)
        MAXTOTALNODES="$2"
        shift 2
        ;;
    --cores-total)
        CORESTOTAL="$2"
        shift 2
        ;;
    --memory-total)
        MEMORYTOTAL="$2"
        shift 2
        ;;
    --max-autoprovisioned-node-group-count)
        MAXAUTOPROVISIONNEDNODEGROUPCOUNT="$2"
        shift 2
        ;;
    --scale-down-enabled)
        SCALEDOWNENABLED="$2"
        shift 2
        ;;
    --scale-down-delay-after-add)
        SCALEDOWNDELAYAFTERADD="$2"
        shift 2
        ;;
    --scale-down-delay-after-delete)
        SCALEDOWNDELAYAFTERDELETE="$2"
        shift 2
        ;;
    --scale-down-delay-after-failure)
        SCALEDOWNDELAYAFTERFAILURE="$2"
        shift 2
        ;;
    --scale-down-unneeded-time)
        SCALEDOWNUNEEDEDTIME="$2"
        shift 2
        ;;
    --scale-down-unready-time)
        SCALEDOWNUNREADYTIME="$2"
        shift 2
        ;;
    --unremovable-node-recheck-timeout)
        UNREMOVABLENODERECHECKTIMEOUT="$2"
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

if [ "${SEED_ARCH}" == "amd64" ]; then
    export SEED_IMAGE=${SEED_IMAGE_AMD64}
    export DEFAULT_MACHINE="t3a.medium"
    export NGINX_MACHINE="t3a.small"
    export MACHINES_TYPES=$(cat<<EOF
    {
        "t3a.nano": {
            "price": 0.0051,
            "memsize": 512,
            "vcpus": 2,
            "disksize": 10
        },
        "t3a.micro": {
            "price": 0.0102,
            "memsize": 1024,
            "vcpus": 2,
            "disksize": 10
        },
        "t3a.small": {
            "price": 0.0204,
            "memsize": 2048,
            "vcpus": 2,
            "disksize": 10
        },
        "t3a.medium": {
            "price": 0.0408,
            "memsize": 4096,
            "vcpus": 2,
            "disksize": 10
        },
        "t3a.large": {
            "price": 0.0816,
            "memsize": 8192,
            "vcpus": 2,
            "disksize": 10
        },
        "t3a.xlarge": {
            "price": 0.1632,
            "memsize": 16384,
            "vcpus": 4,
            "disksize": 10
        },
        "t3a.2xlarge": {
            "price": 0.3264,
            "memsize": 32768,
            "vcpus": 8,
            "disksize": 10
        }
    }
EOF
    )
elif [ "${SEED_ARCH}" == "arm64" ]; then
    export SEED_IMAGE=${SEED_IMAGE_ARM64}
    export DEFAULT_MACHINE="t4g.medium"
    export NGINX_MACHINE="t4g.small"
    export MACHINES_TYPES=$(cat<<EOF
    {
        "t4g.nano": {
            "price": 0.0046,
            "memsize": 512,
            "vcpus": 2,
            "disksize": 10
        },
        "t4g.micro": {
            "price": 0.096,
            "memsize": 1024,
            "vcpus": 2,
            "disksize": 10
        },
        "t4g.small": {
            "price": 0.0184,
            "memsize": 2048,
            "vcpus": 2,
            "disksize": 10
        },
        "t4g.medium": {
            "price": 0.0368,
            "memsize": 4096,
            "vcpus": 2,
            "disksize": 10
        },
        "t4g.large": {
            "price": 0.0736,
            "memsize": 8192,
            "vcpus": 2,
            "disksize": 10
        },
        "t4g.xlarge": {
            "price": 0.1472,
            "memsize": 16384,
            "vcpus": 4,
            "disksize": 10
        },
        "t4g.2xlarge": {
            "price": 0.2944,
            "memsize": 32768,
            "vcpus": 8,
            "disksize": 10
        }
    }
EOF
    )
else
    echo "Unsupported architecture: ${SEED_ARCH}"
    exit -1
fi

pushd ${CURDIR}/../

export SSH_KEY_FNAME="$(basename ${SSH_PRIVATE_KEY})"
export SSH_PUBLIC_KEY="${SSH_PRIVATE_KEY}.pub"

# Check if we can resume the creation process
if [ ! -f ./config/${NODEGROUP_NAME}/buildenv ] && [ "${RESUME}" = "YES" ]; then
    echo_red "Unable to resume, building env is not found"
    exit -1
fi

# Check if ssh private key exists
if [ ! -f ${SSH_PRIVATE_KEY} ]; then
    echo_red "The private ssh key: ${SSH_PRIVATE_KEY} is not found"
    exit -1
fi

# Check if ssh public key exists
if [ ! -f ${SSH_PUBLIC_KEY} ]; then
    echo_red "The private ssh key: ${SSH_PRIVATE_KEY} is not found"
    exit -1
fi

export SSH_KEY=$(cat "${SSH_PUBLIC_KEY}")

# If we use AWS CNI, install eni-max-pods.txt definition file
if [ ${CNI_PLUGIN} = "aws" ]; then
    AWS_MAX_PODS=$(curl -s "https://raw.githubusercontent.com/awslabs/amazon-eks-ami/master/files/eni-max-pods.txt" | grep ^${DEFAULT_MACHINE} | awk '{print $2}')

    if [ -z "${AWS_MAX_PODS}" ]; then
        echo "No entry for ${DEFAULT_MACHINE} in eni-max-pods.txt. Not setting ${MAX_PODS} max pods for kubelet"
    else
        MAX_PODS=${AWS_MAX_PODS}
    fi
fi

# If no master instance profile defined, use the default
if [ -z ${MASTER_INSTANCE_PROFILE_ARN} ]; then
    MASTER_INSTANCE_PROFILE_ARN=$(aws iam get-instance-profile --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-profile-name ${MASTER_PROFILE_NAME} 2> /dev/null | jq -r '.InstanceProfile.Arn // ""')

    # If not found, create it
    if [ -z ${MASTER_INSTANCE_PROFILE_ARN} ]; then
        aws iam create-role --profile ${AWS_PROFILE} --region ${AWS_REGION} --role-name ${MASTER_PROFILE_NAME} --assume-role-policy-document file://templates/profile/master/trusted.json &> /dev/null
        aws iam put-role-policy --profile ${AWS_PROFILE} --region ${AWS_REGION} --role-name ${MASTER_PROFILE_NAME} --policy-name kubernetes-master-permissions --policy-document file://templates/profile/master/permissions.json &> /dev/null
        aws iam create-instance-profile --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-profile-name ${MASTER_PROFILE_NAME} &> /dev/null
        aws iam add-role-to-instance-profile --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-profile-name ${MASTER_PROFILE_NAME} --role-name ${MASTER_PROFILE_NAME} &> /dev/null

        MASTER_INSTANCE_PROFILE_ARN=$(aws iam get-instance-profile --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-profile-name ${MASTER_PROFILE_NAME} | jq -r '.InstanceProfile.Arn // ""')
    fi
fi

# If no worker instance profile defined, use the default
if [ -z ${WORKER_INSTANCE_PROFILE_ARN} ]; then
    WORKER_INSTANCE_PROFILE_ARN=$(aws iam get-instance-profile --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-profile-name ${WORKER_PROFILE_NAME} 2> /dev/null | jq -r '.InstanceProfile.Arn // ""')

    # If not found, create it
    if [ -z ${WORKER_INSTANCE_PROFILE_ARN} ]; then
        aws iam create-role --profile ${AWS_PROFILE} --region ${AWS_REGION} --role-name ${WORKER_PROFILE_NAME} --assume-role-policy-document file://templates/profile/worker/trusted.json &> /dev/null
        aws iam put-role-policy --profile ${AWS_PROFILE} --region ${AWS_REGION} --role-name ${WORKER_PROFILE_NAME} --policy-name kubernetes-worker-permissions --policy-document file://templates/profile/worker/permissions.json &> /dev/null
        aws iam create-instance-profile --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-profile-name ${WORKER_PROFILE_NAME} &> /dev/null
        aws iam add-role-to-instance-profile --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-profile-name ${WORKER_PROFILE_NAME} --role-name ${WORKER_PROFILE_NAME} &> /dev/null

        WORKER_INSTANCE_PROFILE_ARN=$(aws iam get-instance-profile --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-profile-name ${WORKER_PROFILE_NAME} | jq -r '.InstanceProfile.Arn // ""')
    fi
fi

# Tag VPC & Subnet
IFS=, read -a VPC_PUBLIC_SUBNET_IDS <<<${VPC_PUBLIC_SUBNET_ID}
for SUBNET in ${VPC_PUBLIC_SUBNET_IDS[*]}
do
    TAGGED=$(aws ec2 describe-subnets --profile ${AWS_PROFILE} --region ${AWS_REGION} --filters "Name=subnet-id,Values=${SUBNET}" | jq -r ".Subnets[].Tags[]|select(.Key == \"kubernetes.io/cluster/${NODEGROUP_NAME}\")|.Value")
    if [ -z ${TAGGED} ]; then
        aws ec2 create-tags --profile ${AWS_PROFILE} --region ${AWS_REGION} --resources ${SUBNET} --tags "Key=kubernetes.io/cluster/${NODEGROUP_NAME},Value=owned" 2> /dev/null
    fi

    if [ -z "${PUBLIC_SUBNET_NLB_TARGET}" ]; then
        PUBLIC_SUBNET_NLB_TARGET="${SUBNET}"
    else
        PUBLIC_SUBNET_NLB_TARGET="${PUBLIC_SUBNET_NLB_TARGET},${SUBNET}"
    fi
done

if [ ${#VPC_PUBLIC_SUBNET_IDS[@]} = 1 ]; then
    VPC_PUBLIC_SUBNET_IDS+=(${VPC_PUBLIC_SUBNET_IDS[0]} ${VPC_PUBLIC_SUBNET_IDS[0]})
elif [ ${#VPC_PUBLIC_SUBNET_IDS[@]} = 2 ]; then
    VPC_PUBLIC_SUBNET_IDS+=(${VPC_PUBLIC_SUBNET_IDS[1]})
fi

# Tag VPC & Subnet
IFS=, read -a VPC_PRIVATE_SUBNET_IDS <<<${VPC_PRIVATE_SUBNET_ID}
for SUBNET in ${VPC_PRIVATE_SUBNET_IDS[*]}
do
    TAGGED=$(aws ec2 describe-subnets --profile ${AWS_PROFILE} --region ${AWS_REGION} --filters "Name=subnet-id,Values=${SUBNET}" | jq -r ".Subnets[].Tags[]|select(.Key == \"kubernetes.io/cluster/${NODEGROUP_NAME}\")|.Value")
    if [ -z ${TAGGED} ]; then
        aws ec2 create-tags --profile ${AWS_PROFILE} --region ${AWS_REGION} --resources ${SUBNET} --tags "Key=kubernetes.io/cluster/${NODEGROUP_NAME},Value=owned" 2> /dev/null
    fi

    if [ -z "${PRIVATE_SUBNET_NLB_TARGET}" ]; then
        PRIVATE_SUBNET_NLB_TARGET="${SUBNET}"
    else
        PRIVATE_SUBNET_NLB_TARGET="${PRIVATE_SUBNET_NLB_TARGET},${SUBNET}"
    fi
done

if [ ${#VPC_PRIVATE_SUBNET_IDS[@]} = 1 ]; then
    VPC_PRIVATE_SUBNET_IDS+=(${VPC_PRIVATE_SUBNET_IDS[0]} ${VPC_PRIVATE_SUBNET_IDS[0]})
elif [ ${#VPC_PRIVATE_SUBNET_IDS[@]} = 2 ]; then
    VPC_PRIVATE_SUBNET_IDS+=(${VPC_PRIVATE_SUBNET_IDS[1]})
fi

TARGET_IMAGE="${ROOT_IMG_NAME}-cni-${CNI_PLUGIN}-${KUBERNETES_VERSION}-${CONTAINER_ENGINE}-${SEED_ARCH}"
KEYEXISTS=$(aws ec2 describe-key-pairs --profile ${AWS_PROFILE} --region ${AWS_REGION} --key-names "${SSH_KEYNAME}" | jq -r '.KeyPairs[].KeyName // ""')
ECR_PASSWORD=$(aws ecr get-login-password  --profile ${AWS_PROFILE} --region us-west-2)

if [ -z ${KEYEXISTS} ]; then
    echo "SSH Public key doesn't exist"
    aws ec2 import-key-pair --profile ${AWS_PROFILE} --region ${AWS_REGION} --key-name ${SSH_KEYNAME} --public-key-material "file://${SSH_PUBLIC_KEY}"
else
    echo "SSH Public key already exists"
fi

# GRPC network endpoint
if [ "${LAUNCH_CA}" != "YES" ]; then
    SSH_PRIVATE_KEY_LOCAL="${SSH_PRIVATE_KEY}"

    if [ "${TRANSPORT}" == "unix" ]; then
        LISTEN="/var/run/cluster-autoscaler/aws.sock"
        CONNECTTO="unix:/var/run/cluster-autoscaler/aws.sock"
    elif [ "${TRANSPORT}" == "tcp" ]; then
        if [ "${OSDISTRO}" == "Linux" ]; then
            NET_IF=$(ip route get 1 | awk '{print $5;exit}')
            IPADDR=$(ip addr show ${NET_IF} | grep -m 1 "inet\s" | tr '/' ' ' | awk '{print $2}')
        else
            NET_IF=$(route get 1 | grep -m 1 interface | awk '{print $2}')
            IPADDR=$(ifconfig ${NET_IF} | grep -m 1 "inet\s" | sed -n 1p | awk '{print $2}')
        fi

        LISTEN="${IPADDR}:5200"
        CONNECTTO="${IPADDR}:5200"
    else
        echo "Unknown transport: ${TRANSPORT}, should be unix or tcp"
        exit -1
    fi
else
    SSH_PRIVATE_KEY_LOCAL="/root/.ssh/id_rsa"
    TRANSPORT=unix
    LISTEN="/var/run/cluster-autoscaler/aws.sock"
    CONNECTTO="unix:/var/run/cluster-autoscaler/aws.sock"
fi

echo "Transport set to:${TRANSPORT}, listen endpoint at ${LISTEN}"

export PATH=./bin:${PATH}

# If CERT doesn't exist, create one autosigned
if [ ! -f ./etc/ssl/privkey.pem ]; then
    mkdir -p ./etc/ssl/
    openssl genrsa 2048 >./etc/ssl/privkey.pem
    openssl req -new -x509 -nodes -sha1 -days 3650 -key ./etc/ssl/privkey.pem >./etc/ssl/cert.pem
    cat ./etc/ssl/cert.pem ./etc/ssl/privkey.pem >./etc/ssl/fullchain.pem
    chmod 644 ./etc/ssl/*
fi

export TARGET_IMAGE_AMI=$(aws ec2 describe-images --profile ${AWS_PROFILE} --region ${AWS_REGION} --filters "Name=name,Values=${TARGET_IMAGE}" | jq -r '.Images[0].ImageId // ""')

# Extract the domain name from CERT
export DOMAIN_NAME=$(openssl x509 -noout -subject -in ./etc/ssl/cert.pem | awk -F= '{print $NF}' | sed -e 's/^[ \t]*//' | sed 's/\*\.//g')

export ACM_CERTIFICATE_ARN=$(aws acm list-certificates --profile ${AWS_PROFILE} --region ${AWS_REGION} | jq -r --arg DOMAIN_NAME ${DOMAIN_NAME} '.CertificateSummaryList[]|select(.DomainName == $DOMAIN_NAME)|.CertificateArn // ""')

if [ "x${ACM_CERTIFICATE_ARN}" = "x" ]; then
    aws acm import-certificate --profile ${AWS_PROFILE} --region ${AWS_REGION} --tags "Key=Name,Value=${MASTERKUBE}.${DOMAIN_NAME}" \
        --certificate fileb://etc/ssl/cert.pem --certificate-chain fileb://etc/ssl/chain.pem --private-key fileb://etc/ssl/privkey.pem
    export ACM_CERTIFICATE_ARN=$(aws acm list-certificates --profile ${AWS_PROFILE} --region ${AWS_REGION} \
        | jq --arg DOMAIN_NAME ${DOMAIN_NAME} '.CertificateSummaryList[]|select(.DomainName == $DOMAIN_NAME)|.CertificateArn' | tr -d '"' | sed -e 's/null//g')
fi               

# Grab private domain name
if [ ! -z ${ROUTE53_ZONEID} ]; then
    PRIVATE_DOMAIN_NAME=$(aws route53 get-hosted-zone --id  ${ROUTE53_ZONEID} --profile ${AWS_PROFILE_ROUTE53} --region ${AWS_REGION} | jq -r '.HostedZone.Name // ""')
    PRIVATE_DOMAIN_NAME=${PRIVATE_DOMAIN_NAME::-1}
else
    PRIVATE_DOMAIN_NAME=${DOMAIN_NAME}
fi

# Delete previous exixting version
if [ "${RESUME}" = "NO" ]; then
    echo_title "Launch custom ${MASTERKUBE} instance with ${TARGET_IMAGE}"
    delete-masterkube-ha.sh
else
    echo_title "Resume custom ${MASTERKUBE} instance with ${TARGET_IMAGE}"
fi

# If the VM template doesn't exists, build it from scrash
if [ -z "${TARGET_IMAGE_AMI}" ]; then
    echo "Create aws preconfigured image ${TARGET_IMAGE}"

    if [ ${CONTROLPLANE_USE_PUBLICIP} == "true" ]; then
        SUBNETID=${VPC_PUBLIC_SUBNET_IDS[0]}
        SGID=${VPC_PUBLIC_SECURITY_GROUPID}
    else
        SUBNETID=${VPC_PRIVATE_SUBNET_IDS[0]}
        SGID=${VPC_PRIVATE_SECURITY_GROUPID}
    fi

    ./bin/create-image.sh \
        --profile="${AWS_PROFILE}" \
        --region="${AWS_REGION}" \
        --cni-plugin-version="${CNI_PLUGIN_VERSION}" \
        --cni-plugin="${CNI_PLUGIN}" \
        --ecr-password="${ECR_PASSWORD}" \
        --custom-image="${TARGET_IMAGE}" \
        --kubernetes-version="${KUBERNETES_VERSION}" \
        --container-runtime=${CONTAINER_ENGINE} \
        --arch="${SEED_ARCH}" \
        --ami="${SEED_IMAGE}" \
        --user="${SEED_USER}" \
        --ssh-key-name="${SSH_KEYNAME}" \
        --subnet-id="${SUBNETID}" \
        --sg-id="${SGID}" \
        --use-public-ip="${CONTROLPLANE_USE_PUBLICIP}"
fi

export TARGET_IMAGE_AMI=$(aws ec2 describe-images --profile ${AWS_PROFILE} --region ${AWS_REGION} --filters "Name=name,Values=${TARGET_IMAGE}" | jq -r '.Images[0].ImageId // ""')

if [ -d ${TARGET_IMAGE_AMI} ]; then
    echo "AMI ${TARGET_IMAGE} not found"
    exit -1
fi

mkdir -p ./config/${NODEGROUP_NAME}/
mkdir -p ./cluster/${NODEGROUP_NAME}/

if [ "${RESUME}" = "NO" ]; then
    cat ${AWSDEFS} > ./config/${NODEGROUP_NAME}/buildenv
    cat >> ./config/${NODEGROUP_NAME}/buildenv <<EOF
export CLOUD_PROVIDER=${CLOUD_PROVIDER}
export CNI_PLUGIN_VERSION=${CNI_PLUGIN_VERSION}
export CNI_PLUGIN=${CNI_PLUGIN}
export CONTROLNODES=${CONTROLNODES}
export CORESTOTAL="${CORESTOTAL}"
export DEFAULT_MACHINE=${DEFAULT_MACHINE}
export EXTERNAL_ETCD=${EXTERNAL_ETCD}
export FIRSTNODE_INDEX=${FIRSTNODE_INDEX}
export HA_CLUSTER=${HA_CLUSTER}
export KUBECONFIG=${KUBECONFIG}
export KUBERNETES_VERSION=${KUBERNETES_VERSION}
export MASTER_PROFILE_NAME=${MASTER_PROFILE_NAME}
export MASTERKUBE=${MASTERKUBE}
export MAX_PODS=${MAX_PODS}
export MAXAUTOPROVISIONNEDNODEGROUPCOUNT=${MAXAUTOPROVISIONNEDNODEGROUPCOUNT}
export MAXNODES=${MAXNODES}
export MAXTOTALNODES=${MAXTOTALNODES}
export MEMORYTOTAL="${MEMORYTOTAL}"
export MINNODES=${MINNODES}
export NODEGROUP_NAME=${NODEGROUP_NAME}
export OSDISTRO=${OSDISTRO}
export PRIVATE_DOMAIN_NAME=${PRIVATE_DOMAIN_NAME}
export REGISTRY=${REGISTRY}
export ROOT_IMG_NAME=${ROOT_IMG_NAME}
export SCALEDOWNDELAYAFTERADD=${SCALEDOWNDELAYAFTERADD}
export SCALEDOWNDELAYAFTERDELETE=${SCALEDOWNDELAYAFTERDELETE}
export SCALEDOWNDELAYAFTERFAILURE=${SCALEDOWNDELAYAFTERFAILURE}
export SCALEDOWNENABLED=${SCALEDOWNENABLED}
export SCALEDOWNUNEEDEDTIME=${SCALEDOWNUNEEDEDTIME}
export SCALEDOWNUNREADYTIME=${SCALEDOWNUNREADYTIME}
export SCHEME=${SCHEME}
export SEED_ARCH=${SEED_ARCH}
export SEED_IMAGE_AMD64=${SEED_IMAGE_AMD64}
export SEED_IMAGE_ARM64=${SEED_IMAGE_ARM64}
export SEED_USER=${SEED_USER}
export SSH_KEYNAME=${SSH_KEYNAME}
export SSH_PRIVATE_KEY=${SSH_PRIVATE_KEY}
export SSH_PRIVATE_KEY=${SSH_PRIVATE_KEY}
export SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY}
export TARGET_IMAGE=${TARGET_IMAGE}
export TRANSPORT=${TRANSPORT}
export UNREMOVABLENODERECHECKTIMEOUT=${UNREMOVABLENODERECHECKTIMEOUT}
export USE_NLB=${USE_NLB}
export VOLUME_TYPE=${VOLUME_TYPE}
export VOLUME_SIZE=${VOLUME_SIZE}
export EXPOSE_PUBLIC_CLUSTER=${EXPOSE_PUBLIC_CLUSTER}
export CONTROLPLANE_USE_PUBLICIP=${CONTROLPLANE_USE_PUBLICIP}
export WORKERNODE_USE_PUBLICIP=${WORKERNODE_USE_PUBLICIP}
export WORKER_PROFILE_NAME=${WORKER_PROFILE_NAME}
export WORKERNODES=${WORKERNODES}
EOF
else
    source ./config/${NODEGROUP_NAME}/buildenv
fi

if [ ${HA_CLUSTER} = "true" ]; then
    if [ "${USE_NLB}" == "YES" ]; then
        FIRSTNODE_INDEX=1
        CONTROLNODE_INDEX=1
        LASTNODE_INDEX=$((WORKERNODES + ${CONTROLNODES}))
    else
        CONTROLNODE_INDEX=${#VPC_PUBLIC_SUBNET_IDS[*]}
        LASTNODE_INDEX=$((WORKERNODES + ${CONTROLNODES} + ${#VPC_PUBLIC_SUBNET_IDS[*]} - 1))
    fi
else
    CONTROLNODES=1
    CONTROLNODE_INDEX=0
    LASTNODE_INDEX=${WORKERNODES}
    EXTERNAL_ETCD=false

    if [ "${EXPOSE_PUBLIC_CLUSTER}" != "${CONTROLPLANE_USE_PUBLICIP}" ]; then
        if [ "${EXPOSE_PUBLIC_CLUSTER}" == "true" ]; then

            if [ ${USE_NLB} = "YES" ]; then
                FIRSTNODE_INDEX=1
            fi

            CONTROLNODE_INDEX=1
            LASTNODE_INDEX=$((LASTNODE_INDEX + 1))
        fi
    fi
fi

WORKERNODE_INDEX=$((CONTROLNODE_INDEX + ${CONTROLNODES}))

# No external nginx lb, use nlb
if [ ${FIRSTNODE_INDEX} -gt 0 ]; then
    IPADDRS+=("0.0.0.0")
fi

function wait_nlb_ready() {
    echo_blue_dot_title "Wait for ELB start on IP: ${CONTROL_PLANE_ENDPOINT}"

    while :
    do
        echo_blue_dot
        curl -s -k "https://${CONTROL_PLANE_ENDPOINT}:6443" &> /dev/null && break
        sleep 1
    done
    echo

    echo -n ${CONTROL_PLANE_ENDPOINT}:6443 > ./cluster/${NODEGROUP_NAME}/manager-ip
}

function create_vm() {
    local INDEX=$1
    local MASTERKUBE_NODE=
    local IPADDR=
    local INSTANCE_ID=
    local NODEINDEX=

    if [ ${HA_CLUSTER} = "true" ]; then
        if [[ ${INDEX} < ${CONTROLNODE_INDEX} ]]; then
            NODEINDEX=$((INDEX + 1))
            if [[ ${CONTROLNODE_INDEX} > 1 ]]; then
                MASTERKUBE_NODE="${MASTERKUBE}-0${NODEINDEX}"
            else
                MASTERKUBE_NODE="${MASTERKUBE}"
            fi
        elif [[ ${INDEX} -ge $((CONTROLNODE_INDEX + ${CONTROLNODES})) ]]; then
            NODEINDEX=$((INDEX - ${CONTROLNODES} - ${CONTROLNODE_INDEX} + 1))
            MASTERKUBE_NODE="${NODEGROUP_NAME}-worker-0${NODEINDEX}"
        else
            NODEINDEX=$((INDEX - ${CONTROLNODE_INDEX} + 1))
            MASTERKUBE_NODE="${NODEGROUP_NAME}-master-0${NODEINDEX}"
        fi
    else
        if [ ${INDEX} -lt ${CONTROLNODE_INDEX} ]; then
            NODEINDEX=1
            MASTERKUBE_NODE="${MASTERKUBE}"
        elif [ ${INDEX} -eq ${CONTROLNODE_INDEX} ]; then
            NODEINDEX=1
            if [ ${INDEX} -eq 0 ]; then
                MASTERKUBE_NODE="${MASTERKUBE}"
            else
                MASTERKUBE_NODE="${NODEGROUP_NAME}-master-01"
            fi
        else
            NODEINDEX=$((INDEX - ${CONTROLNODE_INDEX}))
            MASTERKUBE_NODE="${NODEGROUP_NAME}-worker-0${NODEINDEX}"
        fi
    fi

    LAUNCHED_INSTANCE=$(aws ec2  describe-instances --profile ${AWS_PROFILE} --region ${AWS_REGION} --filters "Name=tag:Name,Values=${MASTERKUBE_NODE}" | jq -r '.Reservations[].Instances[]|select(.State.Code == 16)' )

    if [ -z $(echo ${LAUNCHED_INSTANCE} | jq '.InstanceId') ]; then
        # Cloud init user-data
    cat > ./config/${NODEGROUP_NAME}/userdata-0${INDEX}.yaml <<EOF
#cloud-config
runcmd:
  - echo "Create ${MASTERKUBE_NODE}" > /var/log/masterkube.log
  - hostnamectl set-hostname "${MASTERKUBE_NODE}"
EOF

    cat > ./config/${NODEGROUP_NAME}/mapping-0${INDEX}.json <<EOF
    [
        {
            "DeviceName": "/dev/sda1",
            "Ebs": {
                "DeleteOnTermination": true,
                "VolumeType": "${VOLUME_TYPE}",
                "VolumeSize": ${VOLUME_SIZE},
                "Encrypted": false
            }
        }
    ]
EOF

        # Worker options by default
        local SUBNET_INDEX=$(echo "$((NODEINDEX - 1)) % ${#VPC_PRIVATE_SUBNET_IDS[@]}" | bc)
        local SUBNETID="${VPC_PRIVATE_SUBNET_IDS[${SUBNET_INDEX}]}"
        local SGID="${VPC_PRIVATE_SECURITY_GROUPID}"
        local IAM_PROFILE_OPTIONS="--iam-instance-profile Arn=${WORKER_INSTANCE_PROFILE_ARN}"
        local PUBLIC_IP_OPTIONS="--no-associate-public-ip-address"
        local MACHINE_TYPE=${DEFAULT_MACHINE}

        if [ ${HA_CLUSTER} = "true" ]; then
            if [ ${INDEX} -lt ${CONTROLNODE_INDEX} ]; then
                # NGINX Load blancer
                MACHINE_TYPE=${NGINX_MACHINE}

                # Use subnet public for NGINX Load balancer
                if [ "${EXPOSE_PUBLIC_CLUSTER}" == "true" ]; then
                    PUBLIC_IP_OPTIONS=--associate-public-ip-address
                    SUBNET_INDEX=$(echo "$((NODEINDEX - 1)) % ${#VPC_PUBLIC_SUBNET_IDS[@]}" | bc)
                    SUBNETID="${VPC_PUBLIC_SUBNET_IDS[${SUBNET_INDEX}]}"
                    SGID="${VPC_PUBLIC_SECURITY_GROUPID}"
                    IAM_PROFILE_OPTIONS=
                fi
            elif [ ${INDEX} -lt ${WORKERNODE_INDEX} ]; then
                IAM_PROFILE_OPTIONS="--iam-instance-profile Arn=${MASTER_INSTANCE_PROFILE_ARN}"
            fi
        elif [ ${INDEX} -lt ${WORKERNODE_INDEX} ]; then
            if [ ${INDEX} = ${CONTROLNODE_INDEX} ] && [ "${CONTROLPLANE_USE_PUBLICIP}" == "true" ]; then
                PUBLIC_IP_OPTIONS=--associate-public-ip-address
                SUBNET_INDEX=$(echo "$((NODEINDEX - 1)) % ${#VPC_PUBLIC_SUBNET_IDS[@]}" | bc)
                SUBNETID="${VPC_PUBLIC_SUBNET_IDS[${SUBNET_INDEX}]}"

                SGID="${VPC_PUBLIC_SECURITY_GROUPID}"
                IAM_PROFILE_OPTIONS="--iam-instance-profile Arn=${MASTER_INSTANCE_PROFILE_ARN}"
            # Use subnet public for NGINX Load balancer
            elif [ ${INDEX} -lt ${CONTROLNODE_INDEX} ] && [ "${EXPOSE_PUBLIC_CLUSTER}" == "true" ]; then
                PUBLIC_IP_OPTIONS=--associate-public-ip-address
                SUBNET_INDEX=$(echo "$((NODEINDEX - 1)) % ${#VPC_PUBLIC_SUBNET_IDS[@]}" | bc)
                SUBNETID="${VPC_PUBLIC_SUBNET_IDS[${SUBNET_INDEX}]}"

                SGID="${VPC_PUBLIC_SECURITY_GROUPID}"
                IAM_PROFILE_OPTIONS=
            fi
        fi

        echo_title "Clone ${TARGET_IMAGE} to ${MASTERKUBE_NODE}"

        LAUNCHED_INSTANCE=$(aws ec2 run-instances \
            --profile "${AWS_PROFILE}" \
            --region "${AWS_REGION}" \
            --image-id "${TARGET_IMAGE_AMI}" \
            --count 1  \
            --instance-type "${MACHINE_TYPE}" \
            --key-name "${SSH_KEYNAME}" \
            --subnet-id "${SUBNETID}" \
            --security-group-ids "${SGID}" \
            --user-data "file://config/${NODEGROUP_NAME}/userdata-0${INDEX}.yaml" \
            --block-device-mappings "file://config/${NODEGROUP_NAME}/mapping-0${INDEX}.json" \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${MASTERKUBE_NODE}},{Key=NodeGroup,Value=${NODEGROUP_NAME}},{Key=kubernetes.io/cluster/${NODEGROUP_NAME},Value=owned},{Key=KubernetesCluster,Value=${NODEGROUP_NAME}}]" \
            ${IAM_PROFILE_OPTIONS} \
            ${PUBLIC_IP_OPTIONS})

        LAUNCHED_ID=$(echo ${LAUNCHED_INSTANCE} | jq -r '.Instances[0].InstanceId // ""')

        if [ -z ${LAUNCHED_ID} ]; then
            echo_red "Something goes wrong when launching ${MASTERKUBE_NODE}"
            exit -1
        fi

        if [ ${CNI_PLUGIN} == "flannel" ]; then
            aws ec2 modify-instance-attribute --profile "${AWS_PROFILE}" --region "${AWS_REGION}" --instance-id=${LAUNCHED_ID} --no-source-dest-check
        fi

        echo_blue_bold "Wait for ${MASTERKUBE_NODE} instanceID ${LAUNCHED_ID} to boot"

        while [ ! $(aws ec2  describe-instances --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-ids "${LAUNCHED_ID}" | jq -r '.Reservations[0].Instances[0].State.Code') -eq 16 ];
        do
            sleep 1
        done

        LAUNCHED_INSTANCE=$(aws ec2  describe-instances --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-ids ${LAUNCHED_ID} | jq .Reservations[0].Instances[0])

        LAUNCHED_INSTANCES[${INDEX}]="${LAUNCHED_INSTANCE}"
        IPADDR=$(echo ${LAUNCHED_INSTANCE} | jq -r '.PrivateIpAddress // ""')
        PRIVATEDNS=$(echo ${LAUNCHED_INSTANCE} | jq -r '.PrivateDnsName // ""')
        IPADDRS[${INDEX}]=${IPADDR}

        # Record Masterkube in Route53 DNS
        if [ ! -z ${ROUTE53_ZONEID} ]; then
            cat > ./config/${NODEGROUP_NAME}/dns-0${INDEX}.json <<EOF
{
    "Comment": "${MASTERKUBE_NODE} private DNS entry",
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "${MASTERKUBE_NODE}.${PRIVATE_DOMAIN_NAME}",
                "Type": "A",
                "TTL": 300,
                "ResourceRecords": [
                    {
                        "Value": "${IPADDR}"
                    }
                ]
            }
        }
    ]
}
EOF
            aws route53 change-resource-record-sets --profile ${AWS_PROFILE_ROUTE53} --region ${AWS_REGION} --hosted-zone-id ${ROUTE53_ZONEID} \
                --change-batch file://config/${NODEGROUP_NAME}/dns-0${INDEX}.json > /dev/null

        elif [ ${INDEX} -ge ${CONTROLNODE_INDEX} ] || [ "${PRIVATE_DOMAIN_NAME}" == "${DOMAIN_NAME}" ]; then
            # Register kubernetes nodes in godaddy if we don't use route53 and private domain
            curl -s -X PUT "https://api.godaddy.com/v1/domains/${DOMAIN_NAME}/records/A/${MASTERKUBE_NODE}" \
                -H "Authorization: sso-key ${GODADDY_API_KEY}:${GODADDY_API_SECRET}" \
                -H "Content-Type: application/json" -d "[{\"data\": \"${IPADDR}\"}]"
        fi

        echo_blue_bold "Wait for ssh ready on ${MASTERKUBE_NODE}, IP=${IPADDR}"

        sleep 5

        while :
        do
            ssh ${SSH_OPTIONS} -o ConnectTimeout=1 "${SEED_USER}@${IPADDR}" sudo hostnamectl set-hostname "${MASTERKUBE_NODE}" 2>/dev/null && break
            sleep 1
        done

        ssh ${SSH_OPTIONS} "${SEED_USER}@${IPADDR}" mkdir /home/${SEED_USER}/cluster -p  2>/dev/null

        echo_blue_bold "SSH is ready on ${MASTERKUBE_NODE}, IP=${IPADDR}"
    else
        LAUNCHED_INSTANCES[${INDEX}]="${LAUNCHED_INSTANCE}"
        IPADDR=$(echo ${LAUNCHED_INSTANCE} | jq -r '.PrivateIpAddress // ""')
        PRIVATEDNS=$(echo ${LAUNCHED_INSTANCE} | jq -r '.PrivateDnsName // ""')
        IPADDRS[${INDEX}]=${IPADDR}

        echo_blue_bold "Already launched ${MASTERKUBE_NODE}, IP=${IPADDR}"
    fi

    echo -n ${LAUNCHED_INSTANCE} | jq . > ./config/${NODEGROUP_NAME}/instance-0${INDEX}.json
}

for INDEX in $(seq ${FIRSTNODE_INDEX} ${LASTNODE_INDEX})
do
    LAUNCHED_INSTANCES+=("{}")
    IPADDRS+=("0.0.0.0")
    create_vm ${INDEX} &
done

wait_jobs_finish

LOAD_BALANCER_IP=
GODADDY_REGISTER="[]"
ROUTE53_REGISTER=$(cat << EOF
{
    "Comment": "${MASTERKUBE_NODE} private DNS entry",
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "${MASTERKUBE}.${PRIVATE_DOMAIN_NAME}",
                "Type": "A",
                "TTL": 300,
                "ResourceRecords": [
                ]
            }
        }
    ]
}
EOF
)

for INDEX in $(seq ${FIRSTNODE_INDEX} ${LASTNODE_INDEX})
do
    LAUNCHED_INSTANCES[${INDEX}]=$(cat ./config/${NODEGROUP_NAME}/instance-0${INDEX}.json)
    IPADDR=$(echo ${LAUNCHED_INSTANCES[${INDEX}]} | jq -r '.PrivateIpAddress // ""')
    IPADDRS[${INDEX}]=${IPADDR}
    PUBLICIPADDR=${IPADDR}

    if [ ${INDEX} -eq 0 ] || [ ${INDEX} -lt ${CONTROLNODE_INDEX} ]; then
        PUBLICIPADDR=$(echo ${LAUNCHED_INSTANCES[${INDEX}]} | jq --arg IPADDR ${IPADDR} -r '.PublicIpAddress // $IPADDR')
        GODADDY_REGISTER=$(echo ${GODADDY_REGISTER} | jq --arg IPADDR "${PUBLICIPADDR}" '. += [ { "data": $IPADDR } ]')
        ROUTE53_REGISTER=$(echo ${ROUTE53_REGISTER} | jq --arg IPADDR "${IPADDR}" '.Changes[0].ResourceRecordSet.ResourceRecords += [ { "Value": $IPADDR } ]')

        if [ -z ${LOAD_BALANCER_IP} ]; then
            LOAD_BALANCER_IP=${IPADDR}
        else
            LOAD_BALANCER_IP=${LOAD_BALANCER_IP},${IPADDR}
        fi
    fi
done

# Register in godaddy IP addresses point in public IP
if [ "${USE_NLB}" != "YES" ]; then
    curl -s -X PUT "https://api.godaddy.com/v1/domains/${DOMAIN_NAME}/records/A/${MASTERKUBE}" \
        -H "Authorization: sso-key ${GODADDY_API_KEY}:${GODADDY_API_SECRET}" \
        -H "Content-Type: application/json" \
        -d "${GODADDY_REGISTER}"
fi

if [ ! -z ${ROUTE53_ZONEID} ]; then
    echo ${ROUTE53_REGISTER} > ./config/${NODEGROUP_NAME}/dns-nlb.json
    aws route53 change-resource-record-sets --profile ${AWS_PROFILE_ROUTE53} --region ${AWS_REGION} \
        --hosted-zone-id ${ROUTE53_ZONEID} \
        --change-batch file://config/${NODEGROUP_NAME}/dns-nlb.json > /dev/null
fi

CLUSTER_NODES=
INSTANCEID_NLB_TARGET=

${SED} -i -e '/CLUSTER_NODES/d' -e '/NLB_DNS/d' ./config/${NODEGROUP_NAME}/buildenv

CONTROL_PLANE_ENDPOINT=${MASTERKUBE}.${PRIVATE_DOMAIN_NAME}

if [ "${HA_CLUSTER}" = "true" ]; then

    IPADDR="${IPADDRS[${CONTROLNODE_INDEX}]}"
    JOIN_IP="${IPADDR}:6443"

    for INDEX in $(seq 1 ${CONTROLNODES})
    do
        INSTANCE_INDEX=$((${INDEX} + ${CONTROLNODE_INDEX} - 1))
        LAUNCHED_INSTANCE=${LAUNCHED_INSTANCES[${INSTANCE_INDEX}]}
        INSTANCE_ID=$(echo ${LAUNCHED_INSTANCE} | jq -r '.InstanceId // ""')
        MASTERKUBE_NODE="${NODEGROUP_NAME}-master-0${INDEX}"
        IPADDR="${IPADDRS[${INSTANCE_INDEX}]}"
        NODE_DNS="${MASTERKUBE_NODE}.${PRIVATE_DOMAIN_NAME}:${IPADDR}"
        PRIVATEDNS="$(echo ${LAUNCHED_INSTANCE} | jq -r '.PrivateDnsName // ""')"

        if [ -z "${CLUSTER_NODES}" ]; then
            CLUSTER_NODES="${NODE_DNS},${PRIVATEDNS}"
            MASTER_NODES="${NODE_DNS}"
        else
            CLUSTER_NODES="${CLUSTER_NODES},${NODE_DNS},${PRIVATEDNS}"
            MASTER_NODES="${MASTER_NODES},${NODE_DNS}"
        fi

        if [ -z ${INSTANCEID_NLB_TARGET} ]; then
            INSTANCEID_NLB_TARGET="${INSTANCE_ID}"
        else
            INSTANCEID_NLB_TARGET="${INSTANCEID_NLB_TARGET},${INSTANCE_ID}"
        fi

    done

    echo "export CLUSTER_NODES=${CLUSTER_NODES}" >> ./config/${NODEGROUP_NAME}/buildenv

    if [ "${USE_NLB}" = "YES" ]; then
        echo_title "Create NLB nlb-${MASTERKUBE}"
        TARGET_VPC=$(aws ec2 describe-subnets --profile ${AWS_PROFILE} --region ${AWS_REGION} --filters "Name=subnet-id,Values=${VPC_PRIVATE_SUBNET_ID}" | jq -r ".Subnets[0].VpcId")

        eval create-aws-nlb.sh --name "${MASTERKUBE}-nlb" \
            --profile=${AWS_PROFILE} \
            --region=${AWS_REGION} \
            --name=nlb-${MASTERKUBE} \
            --cert-arn=${ACM_CERTIFICATE_ARN} \
            --expose-public=${EXPOSE_PUBLIC_CLUSTER} \
            --public-subnet-id="${PUBLIC_SUBNET_NLB_TARGET}" \
            --private-subnet-id="${PRIVATE_SUBNET_NLB_TARGET}" \
            --nlb-port=6443 \
            --target-vpc-id=${TARGET_VPC} \
            --target-port=6443 \
            --security-group=${VPC_PRIVATE_SECURITY_GROUPID} \
            --instances-id="${INSTANCEID_NLB_TARGET}" ${SILENT}

        NLB_DNS=$(aws elbv2 describe-load-balancers --profile=${AWS_PROFILE} --region=${AWS_REGION} | jq -r --arg NLB_NAME nlb-${MASTERKUBE} '.LoadBalancers[]|select(.LoadBalancerName == $NLB_NAME)|.DNSName')

        # Record Masterkube in Route53 DNS
        if [ ! -z ${ROUTE53_ZONEID} ]; then
            cat > ./config/${NODEGROUP_NAME}/dns-nlb.json <<EOF
{
    "Comment": "${MASTERKUBE} private DNS entry",
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "${MASTERKUBE}.${PRIVATE_DOMAIN_NAME}",
                "Type": "CNAME",
                "TTL": 300,
                "ResourceRecords": [
                    {
                        "Value": "${NLB_DNS}"
                    }
                ]
            }
        }
    ]
}
EOF
            aws route53 change-resource-record-sets --profile ${AWS_PROFILE_ROUTE53} --region ${AWS_REGION} --hosted-zone-id ${ROUTE53_ZONEID} \
                --change-batch file://config/${NODEGROUP_NAME}/dns-nlb.json > /dev/null
        fi

        LOAD_BALANCER_IP="${MASTERKUBE}.${PRIVATE_DOMAIN_NAME}"

        if [ "${EXPOSE_PUBLIC_CLUSTER}" == "true" ]; then
            PUBLIC_NLB_DNS=$(aws elbv2 describe-load-balancers --profile=${AWS_PROFILE} --region=${AWS_REGION} | jq -r --arg NLB_NAME p-nlb-${MASTERKUBE} '.LoadBalancers[]|select(.LoadBalancerName == $NLB_NAME)|.DNSName')
        else
            PUBLIC_NLB_DNS=${NLB_DNS}
        fi

        curl -s -X PUT "https://api.godaddy.com/v1/domains/${DOMAIN_NAME}/records/CNAME/${MASTERKUBE}" \
            -H "Authorization: sso-key ${GODADDY_API_KEY}:${GODADDY_API_SECRET}" \
            -H "Content-Type: application/json" \
            -d "[{\"data\": \"${PUBLIC_NLB_DNS}\"}]"
    fi

    echo "export NLB_DNS=${NLB_DNS}" >> ./config/${NODEGROUP_NAME}/buildenv

    if [ "${EXTERNAL_ETCD}" = "true" ]; then
        echo_title "Created etcd cluster: ${MASTER_NODES}"

        eval prepare-etcd.sh --node-group=${NODEGROUP_NAME} --cluster-nodes="${MASTER_NODES}" ${SILENT}

        for INDEX in $(seq 1 ${CONTROLNODES})
        do
            if [ ! -f ./config/${NODEGROUP_NAME}/etdc-0${INDEX}-prepared ]; then
                INSTANCE_INDEX=$((${INDEX} + ${CONTROLNODE_INDEX} - 1))
                IPADDR="${IPADDRS[${INSTANCE_INDEX}]}"

                echo_title "Start etcd node: ${IPADDR}"
                
                eval scp ${SCP_OPTIONS} bin ${SEED_USER}@${IPADDR}:~ ${SILENT}
                eval scp ${SCP_OPTIONS} cluster/${NODEGROUP_NAME}/* ${SEED_USER}@${IPADDR}:~/cluster ${SILENT}
                eval ssh ${SSH_OPTIONS} ${SEED_USER}@${IPADDR} sudo cp /home/${SEED_USER}/bin/* /usr/local/bin ${SILENT}

                eval ssh ${SSH_OPTIONS} ${SEED_USER}@${IPADDR} sudo install-etcd.sh \
                    --user=${SEED_USER} \
                    --cluster-nodes="${MASTER_NODES}" \
                    --node-index="${INDEX}" ${SILENT}

                touch ./config/${NODEGROUP_NAME}/etdc-0${INDEX}-prepared
            fi
        done
    fi
else
    LOAD_BALANCER_IP=${IPADDRS[0]}
    JOIN_IP="${IPADDRS[${CONTROLNODE_INDEX}]}:6443"
    CLUSTER_NODES="${MASTERKUBE}.${DOMAIN_NAME}:${IPADDRS[${CONTROLNODE_INDEX}]}"
    MASTER_NODES="${CLUSTER_NODES}"

    echo "export CLUSTER_NODES=${CLUSTER_NODES}" >> ./config/${NODEGROUP_NAME}/buildenv
fi

for INDEX in $(seq ${FIRSTNODE_INDEX} ${LASTNODE_INDEX})
do
    if [ ${HA_CLUSTER} = "true" ]; then
        if [[ ${INDEX} < ${CONTROLNODE_INDEX} ]]; then
            NODEINDEX=$((INDEX + 1))
            if [[ ${CONTROLNODE_INDEX} > 1 ]]; then
                MASTERKUBE_NODE="${MASTERKUBE}-0${NODEINDEX}"
            else
                MASTERKUBE_NODE="${MASTERKUBE}"
            fi
        elif [[ ${INDEX} -ge $((CONTROLNODE_INDEX + ${CONTROLNODES})) ]]; then
            NODEINDEX=$((INDEX - ${CONTROLNODES} - ${CONTROLNODE_INDEX} + 1))
            MASTERKUBE_NODE="${NODEGROUP_NAME}-worker-0${NODEINDEX}"
        else
            NODEINDEX=$((INDEX - ${CONTROLNODE_INDEX} + 1))
            MASTERKUBE_NODE="${NODEGROUP_NAME}-master-0${NODEINDEX}"
        fi
    else
        if [ ${INDEX} -lt ${CONTROLNODE_INDEX} ]; then
            NODEINDEX=1
            MASTERKUBE_NODE="${MASTERKUBE}"
        elif [ ${INDEX} -eq ${CONTROLNODE_INDEX} ]; then
            NODEINDEX=1
            if [ ${INDEX} -eq 0 ]; then
                MASTERKUBE_NODE="${MASTERKUBE}"
            else
                MASTERKUBE_NODE="${NODEGROUP_NAME}-master-0${NODEINDEX}"
            fi
        else
            NODEINDEX=$((INDEX - ${CONTROLNODE_INDEX}))
            MASTERKUBE_NODE="${NODEGROUP_NAME}-worker-0${NODEINDEX}"
        fi
    fi

    if [ -f ./config/${NODEGROUP_NAME}/instance-0${INDEX}-prepared ]; then
        echo_title "Already prepared VM ${MASTERKUBE_NODE}"
    else
        IPADDR="${IPADDRS[${INDEX}]}"

        echo_title "Prepare VM ${MASTERKUBE_NODE} with IP:${IPADDR}"

        eval scp ${SCP_OPTIONS} bin ${SEED_USER}@${IPADDR}:~ ${SILENT}
        eval ssh ${SSH_OPTIONS} ${SEED_USER}@${IPADDR} sudo cp /home/${SEED_USER}/bin/* /usr/local/bin ${SILENT}

        if [ "${HA_CLUSTER}" = "true" ]; then
            # Start nginx load balancer
            if [ ${INDEX} -lt ${CONTROLNODE_INDEX} ]; then
                echo_blue_bold "Start load balancer ${MASTERKUBE_NODE} instance"

                eval ssh ${SSH_OPTIONS} ${SEED_USER}@${IPADDR} sudo install-load-balancer.sh \
                    --master-nodes="${MASTER_NODES}" \
                    --control-plane-endpoint=${CONTROL_PLANE_ENDPOINT} \
                    --listen-ip="0.0.0.0" ${SILENT}
                NLB_DNS=${IPADDR}
            # Start join worker node
            elif [ ${INDEX} -ge $((CONTROLNODE_INDEX + ${CONTROLNODES})) ]; then
                echo_blue_bold "Join node ${MASTERKUBE_NODE} instance worker node number ${NODEINDEX}, kubernetes version=${KUBERNETES_VERSION}"

                eval scp ${SCP_OPTIONS} ./cluster/${NODEGROUP_NAME}/*  ${SEED_USER}@${IPADDR}:~/cluster ${SILENT}

                eval ssh ${SSH_OPTIONS} ${SEED_USER}@${IPADDR} sudo join-cluster.sh \
                    --join-master=${JOIN_IP} \
                    --cloud-provider=${CLOUD_PROVIDER} \
                    --use-external-etcd=${EXTERNAL_ETCD} \
                    --node-group=${NODEGROUP_NAME} \
                    --node-index=${NODEINDEX} ${SILENT}
            # Start create first master node
            elif [ ${INDEX} = ${CONTROLNODE_INDEX} ]; then
                echo_blue_bold "Start kubernetes ${MASTERKUBE_NODE} instance master node number ${NODEINDEX}, kubernetes version=${KUBERNETES_VERSION}"

                if [ ${DOMAIN_NAME} = ${PRIVATE_DOMAIN_NAME} ]; then
                    CERT_EXTRA_SANS="${MASTERKUBE}.${DOMAIN_NAME},${MASTERKUBE}.${PRIVATE_DOMAIN_NAME}"
                else
                    CERT_EXTRA_SANS="${MASTERKUBE}.${DOMAIN_NAME}"
                fi

                ssh ${SSH_OPTIONS} ${SEED_USER}@${IPADDR} sudo create-cluster.sh \
                    --max-pods=${MAX_PODS} \
                    --ecr-password=${ECR_PASSWORD} \
                    --private-zone-id="${ROUTE53_ZONEID}" \
                    --private-zone-name="${PRIVATE_DOMAIN_NAME}" \
                    --use-external-etcd=${EXTERNAL_ETCD} \
                    --node-group=${NODEGROUP_NAME} \
                    --node-index=${NODEINDEX} \
                    --load-balancer-ip=${LOAD_BALANCER_IP} \
                    --cert-extra-sans="${CERT_EXTRA_SANS}" \
                    --container-runtime=${CONTAINER_ENGINE} \
                    --cloud-provider=${CLOUD_PROVIDER} \
                    --cluster-nodes="${CLUSTER_NODES}" \
                    --control-plane-endpoint="${CONTROL_PLANE_ENDPOINT}" \
                    --ha-cluster=true \
                    --cni-plugin="${CNI_PLUGIN}" \
                    --kubernetes-version="${KUBERNETES_VERSION}" ${SILENT}

                eval scp ${SCP_OPTIONS} ${SEED_USER}@${IPADDR}:/etc/cluster/* ./cluster/${NODEGROUP_NAME}  ${SILENT}

                wait_nlb_ready

                JOIN_IP=${IPADDR}:6443
            # Start control-plane join master node
            else
                echo_blue_bold "Join control-plane ${MASTERKUBE_NODE} instance master node number ${NODEINDEX}, kubernetes version=${KUBERNETES_VERSION}"

                eval scp ${SCP_OPTIONS} ./cluster/${NODEGROUP_NAME}/*  ${SEED_USER}@${IPADDR}:~/cluster ${SILENT}

                eval ssh ${SSH_OPTIONS} ${SEED_USER}@${IPADDR} sudo join-cluster.sh \
                    --join-master=${JOIN_IP} \
                    --control-plane=true \
                    --cloud-provider=${CLOUD_PROVIDER} \
                    --use-external-etcd=${EXTERNAL_ETCD} \
                    --node-group=${NODEGROUP_NAME} \
                    --node-index=${NODEINDEX} ${SILENT}
            fi
        else
            # Start nginx load balancer
            if [ ${INDEX} -lt ${CONTROLNODE_INDEX} ]; then
                echo_blue_bold "Start load balancer ${MASTERKUBE_NODE} instance"

                eval ssh ${SSH_OPTIONS} ${SEED_USER}@${IPADDR} sudo install-load-balancer.sh \
                    --master-nodes="${MASTER_NODES}" \
                    --control-plane-endpoint=${CONTROL_PLANE_ENDPOINT} \
                    --listen-ip="0.0.0.0" ${SILENT}
                NLB_DNS=${IPADDR}

            # Single instance master node
            elif [ ${INDEX} = ${CONTROLNODE_INDEX} ]; then
                echo_blue_bold "Start kubernetes ${MASTERKUBE_NODE} single instance master node number ${NODEINDEX}, kubernetes version=${KUBERNETES_VERSION}"

                if [ "${DOMAIN_NAME}" != "${PRIVATE_DOMAIN_NAME}" ]; then
                    CERT_EXTRA_SANS="${MASTERKUBE}.${DOMAIN_NAME},${MASTERKUBE}.${PRIVATE_DOMAIN_NAME}"
                else
                    CERT_EXTRA_SANS="${MASTERKUBE}.${DOMAIN_NAME}"
                fi

                eval ssh ${SSH_OPTIONS} ${SEED_USER}@${IPADDR} sudo create-cluster.sh \
                    --max-pods=${MAX_PODS} \
                    --ecr-password=${ECR_PASSWORD} \
                    --private-zone-id="${ROUTE53_ZONEID}" \
                    --private-zone-name="${PRIVATE_DOMAIN_NAME}" \
                    --cert-extra-sans="${CERT_EXTRA_SANS}" \
                    --container-runtime=${CONTAINER_ENGINE} \
                    --cloud-provider=${CLOUD_PROVIDER} \
                    --cluster-nodes="${MASTERKUBE}.${DOMAIN_NAME}" \
                    --control-plane-endpoint="${CONTROL_PLANE_ENDPOINT}" \
                    --node-group=${NODEGROUP_NAME} \
                    --node-index=${NODEINDEX} \
                    --cni-plugin="${CNI_PLUGIN}" \
                    --kubernetes-version="${KUBERNETES_VERSION}" ${SILENT}

                eval scp ${SCP_OPTIONS} ${SEED_USER}@${IPADDR}:/etc/cluster/* ./cluster/${NODEGROUP_NAME}  ${SILENT}

                JOIN_IP=${IPADDR}:6443
            else
                echo_blue_bold "Join node ${MASTERKUBE_NODE} instance worker node number ${NODEINDEX}, kubernetes version=${KUBERNETES_VERSION}"

                eval scp ${SCP_OPTIONS} ./cluster/${NODEGROUP_NAME}/*  ${SEED_USER}@${IPADDR}:~/cluster ${SILENT}

                eval ssh ${SSH_OPTIONS} ${SEED_USER}@${IPADDR} sudo join-cluster.sh \
                    --join-master=${JOIN_IP} \
                    --control-plane=false \
                    --cloud-provider=${CLOUD_PROVIDER} \
                    --use-external-etcd=${EXTERNAL_ETCD} \
                    --node-group=${NODEGROUP_NAME} \
                    --node-index=${NODEINDEX} ${SILENT}
            fi
        fi

        echo ${MASTERKUBE_NODE} > ./config/${NODEGROUP_NAME}/instance-0${INDEX}-prepared
    fi

    echo_separator
done

echo_blue_bold "create cluster done"

MASTER_IP=$(cat ./cluster/${NODEGROUP_NAME}/manager-ip)
TOKEN=$(cat ./cluster/${NODEGROUP_NAME}/token)
CACERT=$(cat ./cluster/${NODEGROUP_NAME}/ca.cert)

kubectl create secret tls kube-system -n kube-system --key ./etc/ssl/privkey.pem --cert ./etc/ssl/fullchain.pem --kubeconfig=./cluster/${NODEGROUP_NAME}/config
kubectl create secret generic autoscaler-ssh-keys -n kube-system --from-file=id_rsa="${SSH_PRIVATE_KEY}" --from-file=id_rsa.pub="${SSH_PUBLIC_KEY}" --kubeconfig=./cluster/${NODEGROUP_NAME}/config

kubeconfig-merge.sh ${MASTERKUBE} ./cluster/${NODEGROUP_NAME}/config

echo "Write aws autoscaler provider config"

echo $(eval "cat <<EOF
$(<./templates/cluster/grpc-config.json)
EOF") | jq . >./config/${NODEGROUP_NAME}/grpc-config.json

if [ "${EXTERNAL_ETCD}" = "true" ]; then
    export EXTERNAL_ETCD_ARGS="--use-external-etcd"
else
    export EXTERNAL_ETCD_ARGS="--no-use-external-etcd"
fi

AUTOSCALER_CONFIG=$(cat <<EOF
{
    "use-external-etcd": ${EXTERNAL_ETCD},
    "src-etcd-ssl-dir": "/etc/etcd/ssl",
    "dst-etcd-ssl-dir": "/etc/etcd/ssl",
    "network": "${TRANSPORT}",
    "listen": "${LISTEN}",
    "secret": "${SCHEME}",
    "minNode": ${MINNODES},
    "maxNode": ${MAXNODES},
    "maxPods": ${MAX_PODS},
    "nodePrice": 0.0,
    "podPrice": 0.0,
    "image": "${TARGET_IMAGE}",
    "cloud-provider": "${CLOUD_PROVIDER}",
    "optionals": {
        "pricing": true,
        "getAvailableMachineTypes": true,
        "newNodeGroup": false,
        "templateNodeInfo": false,
        "createNodeGroup": false,
        "deleteNodeGroup": false
    },
    "kubeadm": {
        "address": "${MASTER_IP}",
        "token": "${TOKEN}",
        "ca": "sha256:${CACERT}",
        "extras-args": [
            "--ignore-preflight-errors=All"
        ]
    },
    "default-machine": "${DEFAULT_MACHINE}",
    "machines": ${MACHINES_TYPES},
    "sync-folder": {
    },
    "ssh-infos" : {
        "user": "${SEED_USER}",
        "ssh-private-key": "${SSH_PRIVATE_KEY_LOCAL}"
    },
    "aws": {
        "${NODEGROUP_NAME}": {
            "accessKey": "${AWS_ACCESSKEY}",
            "secretKey": "${AWS_SECRETKEY}",
            "token": "${AWS_TOKEN}",
            "profile": "${AWS_PROFILE}",
            "region" : "${AWS_REGION}",
            "keyName": "${SSH_KEYNAME}",
            "ami": "${TARGET_IMAGE_AMI}",
            "iam-role-arn": "${WORKER_INSTANCE_PROFILE_ARN}",
            "timeout": 120,
            "tags": [
                {
                    "key": "CustomTag",
                    "value": "CustomValue"
                }
            ],
            "network": {
                "route53": "${ROUTE53_ZONEID}",
                "privateZoneName": "${PRIVATE_DOMAIN_NAME}",
                "eni": [
                    {
                        "subnets": [
                        ],
                        "securityGroup": "${VPC_PRIVATE_SECURITY_GROUPID}",
                        "publicIP": ${WORKERNODE_USE_PUBLICIP}
                    }
                ]
            }
        }
    }
}
EOF
)

IFS=, read -a VPC_PRIVATE_SUBNET_IDS <<<${VPC_PRIVATE_SUBNET_ID}
for SUBNET in ${VPC_PRIVATE_SUBNET_IDS[*]}
do
    AUTOSCALER_CONFIG=$(echo ${AUTOSCALER_CONFIG} | jq --arg SUBNET ${SUBNET} ".aws.\"${NODEGROUP_NAME}\".network.eni[0].subnets += [ \$SUBNET ]")
done

echo "${AUTOSCALER_CONFIG}" | jq . > ./config/${NODEGROUP_NAME}/kubernetes-aws-autoscaler.json

# Recopy config file on master node
kubectl create configmap config-cluster-autoscaler --kubeconfig=./cluster/${NODEGROUP_NAME}/config -n kube-system \
	--from-file ./config/${NODEGROUP_NAME}/grpc-config.json \
	--from-file ./config/${NODEGROUP_NAME}/kubernetes-aws-autoscaler.json

# Create Pods
create-ingress-controller.sh
create-dashboard.sh
create-metrics.sh
create-helloworld.sh
create-external-dns.sh

if [ "${LAUNCH_CA}" != "NO" ]; then
    create-autoscaler.sh ${LAUNCH_CA}
fi

# Add cluster config in configmap
kubectl create configmap masterkube-config --kubeconfig=./cluster/${NODEGROUP_NAME}/config -n kube-system \
	--from-file ./cluster/${NODEGROUP_NAME}/ca.cert \
    --from-file ./cluster/${NODEGROUP_NAME}/dashboard-token \
    --from-file ./cluster/${NODEGROUP_NAME}/token

if [ "${EXTERNAL_ETCD}" = "true" ]; then
    kubectl create secret generic etcd-ssl --kubeconfig=./cluster/${NODEGROUP_NAME}/config -n kube-system \
        --from-file ./cluster/${NODEGROUP_NAME}/etcd/ssl
else
    kubectl create secret generic etcd-ssl --kubeconfig=./cluster/${NODEGROUP_NAME}/config -n kube-system
fi

curl -s -X PUT "https://api.godaddy.com/v1/domains/${DOMAIN_NAME}/records/CNAME/masterkube-aws-dashboard" \
    -H "Authorization: sso-key ${GODADDY_API_KEY}:${GODADDY_API_SECRET}" \
    -H "Content-Type: application/json" \
    -d "[{\"data\": \"${MASTERKUBE}.${DOMAIN_NAME}\"}]"

curl -s -X PUT "https://api.godaddy.com/v1/domains/${DOMAIN_NAME}/records/CNAME/helloworld-aws" \
    -H "Authorization: sso-key ${GODADDY_API_KEY}:${GODADDY_API_SECRET}" \
    -H "Content-Type: application/json" \
    -d "[{\"data\": \"${MASTERKUBE}.${DOMAIN_NAME}\"}]"

popd

#/bin/bash

set -e

KUBERNETES_VERSION=$(curl -sSL https://dl.k8s.io/release/stable.txt)
CNI_PLUGIN_VERSION=v1.0.1
CNI_PLUGIN=aws
CACHE=~/.local/aws/cache
OSDISTRO=$(uname -s)
SSH_KEYNAME="aws-k8s-key"
CURDIR=$(dirname $0)
FORCE=NO
INSTANCE_IMAGE=t3a.small
SEED_ARCH=amd64
SEED_USER=ubuntu
SEED_IMAGE="<to be filled>"
TARGET_IMAGE=
CONTAINER_ENGINE=docker
CONTAINER_CTL=docker
VPC_PUBLIC_SUBNET_ID="<to be filled>"
VPC_PUBLIC_SECURITY_GROUPID="<to be filled>"

VPC_MASTER_USE_PUBLICIP=true

SSH_OPTIONS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

source ${CURDIR}/aws.defs

if [ "$OSDISTRO" == "Linux" ]; then
    TZ=$(cat /etc/timezone)
else
    TZ=$(sudo systemsetup -gettimezone | awk '{print $2}')
fi

function get_ecs_container_account_for_region () {
    local region="$1"
    case "${region}" in
    ap-east-1)
        echo "800184023465";;
    me-south-1)
        echo "558608220178";;
    cn-north-1)
        echo "918309763551";;
    cn-northwest-1)
        echo "961992271922";;
    us-gov-west-1)
        echo "013241004608";;
    us-gov-east-1)
        echo "151742754352";;
    *)
        echo "602401143452";;
    esac
}

mkdir -p $CACHE

TEMP=`getopt -o kfc:i:n:op:s:u:v: --long container-runtime:,arch:,ecr-password:,force,profile:,region:,subnet-id:,sg-id:,use-public-ip:,user:,ami:,custom-image:,ssh-key-name:,cni-plugin:,cni-plugin-version:,kubernetes-version: -n "$0" -- "$@"`
eval set -- "$TEMP"

# extract options and their arguments into variables.
while true ; do
	#echo "1:$1"
    case "$1" in
        -f|--force) FORCE=YES ; shift;;

        -p|--profile) AWS_PROFILE="${2}" ; shift 2;;
        -r|--region) AWS_REGION="${2}" ; shift 2;;
        -i|--custom-image) TARGET_IMAGE="$2" ; shift 2;;
        -i|--cni-plugin-version) CNI_PLUGIN_VERSION=$2 ; shift 2;;
        -c|--cni-plugin) CNI_PLUGIN=$2 ; shift 2;;
        -u|--user) SEED_USER=$2 ; shift 2;;
        -v|--kubernetes-version) KUBERNETES_VERSION=$2 ; shift 2;;

        --ami) SEED_IMAGE=$2 ; shift 2;;
        --arch) SEED_ARCH=$2 ; shift 2;;
        --ecr-password) ECR_PASSWORD=$2 ; shift 2;;
        --ssh-key-name) SSH_KEYNAME=$2 ; shift 2;;
        --subnet-id) VPC_PUBLIC_SUBNET_ID="${2}" ; shift 2;;
        --sg-id) VPC_PUBLIC_SECURITY_GROUPID="${2}" ; shift 2;;
        --use-public-ip) VPC_MASTER_USE_PUBLICIP="${2}" ; shift 2;;

        --container-runtime)
            case "$2" in
                "docker")
                    CONTAINER_ENGINE="$2"
                    CONTAINER_CTL=docker
                    ;;
                "cri-o"|"containerd")
                    CONTAINER_ENGINE="$2"
                    CONTAINER_CTL=crictl
                    ;;
                *)
                    echo "Unsupported container runtime: $2"
                    exit 1
                    ;;
            esac
            shift 2;;

        --) shift ; break ;;
        *) echo "$1 - Internal error!" ; exit 1 ;;
    esac
done

if [ -z "$TARGET_IMAGE" ]; then
    TARGET_IMAGE="focal-k8s-cni-${CNI_PLUGIN}-${KUBERNETES_VERSION}-${CONTAINER_ENGINE}-${SEED_ARCH}"
fi

if [ "$SEED_ARCH" == "amd64" ]; then
    INSTANCE_TYPE=t3a.small
elif [ "$SEED_ARCH" == "arm64" ]; then
    INSTANCE_TYPE=t4g.small
else
    echo "Unsupported architecture: $SEED_ARCH"
    exit -1
fi

TARGET_IMAGE_ID=$(aws ec2 describe-images --profile ${AWS_PROFILE} --region ${AWS_REGION} --filters "Name=architecture,Values=x86_64" "Name=name,Values=${TARGET_IMAGE}" "Name=virtualization-type,Values=hvm" 2>/dev/null | jq '.Images[0].ImageId' | tr -d '"' | sed -e 's/null//g')
SOURCE_IMAGE_ID=$(aws ec2 describe-images --profile ${AWS_PROFILE} --region ${AWS_REGION} --image-ids "${SEED_IMAGE}" 2>/dev/null | jq '.Images[0].ImageId' | tr -d '"' | sed -e 's/null//g')
KEYEXISTS=$(aws ec2 describe-key-pairs --profile ${AWS_PROFILE} --region ${AWS_REGION} --key-names "${SSH_KEYNAME}" 2>/dev/null | jq  '.KeyPairs[].KeyName' | tr -d '"')

if [ ! -z "${TARGET_IMAGE_ID}" ]; then
    if [ $FORCE = NO ]; then
        echo "$TARGET_IMAGE already exists!"
        exit 0
    fi
    aws ec2 deregister-image --profile ${AWS_PROFILE} --region ${AWS_REGION} --image-id "${TARGET_IMAGE_ID}" &>/dev/null
fi

if [ -z "${SOURCE_IMAGE_ID}" ]; then
    echo "Source $SOURCE_IMAGE_ID not found!"
    exit -1
fi

if [ -z ${KEYEXISTS} ]; then
    echo "SSH Public key doesn't exist"
    if [ -z ${SSH_KEY_PUB} ]; then
        echo "${SSH_KEY_PUB} doesn't exists. FATAL"
        exit -1
    fi
    aws ec2 import-key-pair --profile ${AWS_PROFILE} --region ${AWS_REGION} --key-name ${SSH_KEYNAME} --public-key-material "file://${SSH_KEY_PUB}"
fi

KUBERNETES_MINOR_RELEASE=$(echo -n $KUBERNETES_VERSION | tr '.' ' ' | awk '{ print $2 }')
CRIO_VERSION=$(echo -n $KUBERNETES_VERSION | tr -d 'v' | tr '.' ' ' | awk '{ print $1"."$2 }')

echo "Prepare ${TARGET_IMAGE} image with cri-o version: $CRIO_VERSION and kubernetes: $KUBERNETES_VERSION"

cat > $CACHE/mapping.json <<EOF
[
    {
        "DeviceName": "/dev/sda1",
        "Ebs": {
            "DeleteOnTermination": true,
            "VolumeType": "gp2",
            "VolumeSize": 10,
            "Encrypted": false
        }
    }
]
EOF

cat > "${CACHE}/prepare-image.sh" << EOF
#!/bin/bash
SEED_ARCH=${SEED_ARCH}
CNI_PLUGIN=${CNI_PLUGIN}
CNI_PLUGIN_VERSION=${CNI_PLUGIN_VERSION}
KUBERNETES_VERSION=${KUBERNETES_VERSION}
KUBERNETES_MINOR_RELEASE=${KUBERNETES_MINOR_RELEASE}
ECR_PASSWORD=${ECR_PASSWORD}
CRIO_VERSION=${CRIO_VERSION}
CONTAINER_ENGINE=${CONTAINER_ENGINE}
CONTAINER_CTL=${CONTAINER_CTL}

echo "==============================================================================================================================="
echo "= Upgrade ubuntu distro"
echo "==============================================================================================================================="
apt update
apt dist-upgrade -y
echo

apt update

echo "==============================================================================================================================="
echo "= Install mandatories packages"
echo "==============================================================================================================================="
apt install jq socat conntrack awscli net-tools traceroute -y
snap install yq --classic
echo

EOF

cat >> "${CACHE}/prepare-image.sh" <<"EOF"

function pull_image() {
    local DOCKER_IMAGES=$(curl -s $1 | yq eval -P - | grep "image: " | sed -E 's/.+image: (.+)/\1/g')
    local USERNAME=$2
    local PASSWORD=$3

    if [ "${USERNAME}X${PASSWORD}" != "X" ]; then
        if [ ${CONTAINER_CTL} == crictl ]; then
            AUTHENT="--creds ${USERNAME}:${PASSWORD}"
        else
            ${CONTAINER_CTL} login -u ${USERNAME} -p "${PASSWORD}" "602401143452.dkr.ecr.us-west-2.amazonaws.com"
        fi
    fi

    for DOCKER_IMAGE in $DOCKER_IMAGES
    do
        echo "Pull image $DOCKER_IMAGE"
        ${CONTAINER_CTL} pull ${AUTHENT} $DOCKER_IMAGE
    done
}

mkdir -p /opt/cni/bin
mkdir -p /usr/local/bin

echo "net.bridge.bridge-nf-call-ip6tables = 1" >> /etc/sysctl.conf
echo "net.bridge.bridge-nf-call-iptables = 1" >> /etc/sysctl.conf
echo "net.bridge.bridge-nf-call-arptables = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf

echo "overlay" >> /etc/modules
echo "br_netfilter" >> /etc/modules

modprobe overlay
modprobe br_netfilter

echo '1' > /proc/sys/net/bridge/bridge-nf-call-iptables

sysctl --system

. /etc/os-release

OS=x${NAME}_${VERSION_ID}

systemctl disable apparmor

echo "Prepare to install CNI plugins"

echo "==============================================================================================================================="
echo "= Install CNI plugins"
echo "==============================================================================================================================="

curl -sL "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-linux-${SEED_ARCH}-${CNI_PLUGIN_VERSION}.tgz" | tar -C /opt/cni/bin -xz

ls -l /opt/cni/bin

echo

if [ "${CONTAINER_ENGINE}" = "docker" ]; then

    echo "==============================================================================================================================="
    echo "Install Docker"
    echo "==============================================================================================================================="

    mkdir -p /etc/docker
    mkdir -p /etc/systemd/system/docker.service.d

    curl -s https://get.docker.com | bash

    cat > /etc/docker/daemon.json <<SHELL
{
    "exec-opts": [
        "native.cgroupdriver=systemd"
    ],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m"
    },
    "storage-driver": "overlay2"
}
SHELL

    # Restart docker.
    systemctl daemon-reload
    systemctl restart docker

    usermod -aG docker ubuntu

elif [ "${CONTAINER_ENGINE}" == "containerd" ]; then

    echo "==============================================================================================================================="
    echo "Install Containerd"
    echo "==============================================================================================================================="

    curl -sL  https://github.com/containerd/containerd/releases/download/v1.5.8/cri-containerd-cni-1.5.8-linux-amd64.tar.gz | tar -C / -xz

    mkdir -p /etc/containerd
    containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/g' | tee /etc/containerd/config.toml

    systemctl enable containerd.service
    systemctl restart containerd
else

    echo "==============================================================================================================================="
    echo "Install CRI-O repositories"
    echo "==============================================================================================================================="

    echo "deb http://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIO_VERSION/$OS/ /" > /etc/apt/sources.list.d/devel:kubic:libcontainers:stable:cri-o:$CRIO_VERSION.list
    curl -sL https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable:cri-o:$CRIO_VERSION/$OS/Release.key | sudo apt-key --keyring /etc/apt/trusted.gpg.d/libcontainers-cri-o.gpg add -

    apt update
    apt install cri-o cri-o-runc -y
    echo

    mkdir -p /etc/crio/crio.conf.d/

#    cat > /etc/crio/crio.conf.d/02-cgroup-manager.conf <<SHELL
#conmon_cgroup = "pod"
#cgroup_manager = "cgroupfs"
#SHELL

    systemctl daemon-reload
    systemctl enable crio
    systemctl restart crio
fi

echo "==============================================================================================================================="
echo "= Install crictl"
echo "==============================================================================================================================="
curl -sL https://github.com/kubernetes-sigs/cri-tools/releases/download/v${CRIO_VERSION}.0/crictl-v${CRIO_VERSION}.0-linux-${SEED_ARCH}.tar.gz  | tar -C /usr/local/bin -xz
chmod +x /usr/local/bin/crictl

echo "==============================================================================================================================="
echo "= Clean ubuntu distro"
echo "==============================================================================================================================="
apt-get autoremove -y
echo

echo

# Set NTP server
echo "set NTP server"
sed -i '/^NTP/d' /etc/systemd/timesyncd.conf
echo "NTP=169.254.169.123" >>/etc/systemd/timesyncd.conf
timedatectl set-timezone UTC
systemctl restart systemd-timesyncd.service

# Add some EKS init 
if [ $CNI_PLUGIN = "aws" ]; then
    mkdir -p /etc/eks
    mkdir -p /etc/sysconfig
    wget https://raw.githubusercontent.com/awslabs/amazon-eks-ami/master/files/eni-max-pods.txt -O /etc/eks/eni-max-pods.txt

    /sbin/iptables-save > /etc/sysconfig/iptables

    wget https://raw.githubusercontent.com/awslabs/amazon-eks-ami/master/files/iptables-restore.service -O /etc/systemd/system/iptables-restore.service

    sudo systemctl daemon-reload
    sudo systemctl enable iptables-restore
fi

echo "==============================================================================================================================="
echo "= Install kubernetes binaries"
echo "==============================================================================================================================="

cd /usr/local/bin
curl -sL --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/${SEED_ARCH}/{kubeadm,kubelet,kubectl,kube-proxy}
chmod +x /usr/local/bin/kube*

echo

echo "==============================================================================================================================="
echo "= Configure kubelet"
echo "==============================================================================================================================="

mkdir -p /etc/systemd/system/kubelet.service.d
mkdir -p /var/lib/kubelet

cat > /etc/systemd/system/kubelet.service <<SHELL
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=http://kubernetes.io/docs/

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
SHELL

if [ $CNI_PLUGIN = "aws" ]; then
    cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<- "SHELL"
    # Note: This dropin only works with kubeadm and kubelet v1.11+
    [Service]
    Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
    Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
    # This is a file that "kubeadm init" and "kubeadm join" generate at runtime, populating the KUBELET_KUBEADM_ARGS variable dynamically
    EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
    # This is a file that the user can use for overrides of the kubelet args as a last resort. Preferably, the user should use
    # the .NodeRegistration.KubeletExtraArgs object in the configuration files instead. KUBELET_EXTRA_ARGS should be sourced from this file.
    EnvironmentFile=-/etc/default/kubelet
    # Add iptables enable forwarding
    ExecStartPre=/sbin/iptables -P FORWARD ACCEPT -w 5
    ExecStart=
    ExecStart=/usr/local/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
SHELL
else
    cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<- "SHELL"
    # Note: This dropin only works with kubeadm and kubelet v1.11+
    [Service]
    Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
    Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
    # This is a file that "kubeadm init" and "kubeadm join" generate at runtime, populating the KUBELET_KUBEADM_ARGS variable dynamically
    EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
    # This is a file that the user can use for overrides of the kubelet args as a last resort. Preferably, the user should use
    # the .NodeRegistration.KubeletExtraArgs object in the configuration files instead. KUBELET_EXTRA_ARGS should be sourced from this file.
    EnvironmentFile=-/etc/default/kubelet
    ExecStart=
    ExecStart=/usr/local/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
SHELL
fi

if [ ${CONTAINER_ENGINE} = "docker" ]; then
    echo 'KUBELET_EXTRA_ARGS="--network-plugin=cni"' > /etc/default/kubelet
    echo 'KUBELET_KUBEADM_ARGS=""' > /var/lib/kubelet/kubeadm-flags.env
elif [ ${CONTAINER_ENGINE} = "containerd" ]; then
    echo > /etc/default/kubelet
    echo 'KUBELET_KUBEADM_ARGS="--container-runtime=remote --container-runtime-endpoint=/run/containerd/containerd.sock"' > /var/lib/kubelet/kubeadm-flags.env
else
    echo > /etc/default/kubelet
    echo 'KUBELET_KUBEADM_ARGS="--container-runtime=remote --container-runtime-endpoint=/var/run/crio/crio.sock"' > /var/lib/kubelet/kubeadm-flags.env
fi

apt dist-upgrade -y
apt autoremove -y

echo 'export PATH=/opt/cni/bin:$PATH' >> /etc/profile.d/apps-bin-path.sh

echo "==============================================================================================================================="
echo "= Restart kubelet"
echo "==============================================================================================================================="

systemctl enable kubelet
systemctl restart kubelet

echo "==============================================================================================================================="
echo "= Pull kube images"
echo "==============================================================================================================================="

/usr/local/bin/kubeadm config images pull --kubernetes-version=${KUBERNETES_VERSION}

echo "==============================================================================================================================="
echo "= Pull cni image"
echo "==============================================================================================================================="

if [ "$CNI_PLUGIN" = "aws" ]; then
    if [ ${KUBERNETES_MINOR_RELEASE} -gt 20 ]; then
      AWS_CNI_URL=https://raw.githubusercontent.com/aws/amazon-vpc-cni-k8s/release-1.10/config/master/aws-k8s-cni.yaml
    else
      AWS_CNI_URL=https://raw.githubusercontent.com/aws/amazon-vpc-cni-k8s/v1.9.3/config/v1.9/aws-k8s-cni.yaml
    fi
    pull_image ${AWS_CNI_URL} AWS ${ECR_PASSWORD}
elif [ "$CNI_PLUGIN" = "calico" ]; then
    curl -s -O -L "https://github.com/projectcalico/calicoctl/releases/download/v3.18.2/calicoctl-linux-${SEED_ARCH}"
    chmod +x calicoctl-linux-${SEED_ARCH}
    mv calicoctl-linux-${SEED_ARCH} /usr/local/bin/calicoctl
    pull_image https://docs.projectcalico.org/manifests/calico-vxlan.yaml
elif [ "$CNI_PLUGIN" = "flannel" ]; then
    pull_image https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
elif [ "$CNI_PLUGIN" = "weave" ]; then
    pull_image "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"
elif [ "$CNI_PLUGIN" = "canal" ]; then
    pull_image https://raw.githubusercontent.com/projectcalico/canal/master/k8s-install/1.7/rbac.yaml
    pull_image https://raw.githubusercontent.com/projectcalico/canal/master/k8s-install/1.7/canal.yaml
elif [ "$CNI_PLUGIN" = "kube" ]; then
    pull_image https://raw.githubusercontent.com/cloudnativelabs/kube-router/master/daemonset/kubeadm-kuberouter.yaml
    pull_image https://raw.githubusercontent.com/cloudnativelabs/kube-router/master/daemonset/kubeadm-kuberouter-all-features.yaml
elif [ "$CNI_PLUGIN" = "romana" ]; then
    pull_image https://raw.githubusercontent.com/romana/romana/master/containerize/specs/romana-kubeadm.yml
fi

echo "==============================================================================================================================="
echo "= Cleanup"
echo "==============================================================================================================================="

# Delete default cni config from containerd
rm -rf /etc/cni/net.d/*

[ -f /etc/cloud/cloud.cfg.d/50-curtin-networking.cfg ] && rm /etc/cloud/cloud.cfg.d/50-curtin-networking.cfg
rm /etc/netplan/*
cloud-init clean

rm -rf /etc/apparmor.d/cache/* /etc/apparmor.d/cache/.features
/usr/bin/truncate --size 0 /etc/machine-id
rm -f /snap/README
find /usr/share/netplan -name __pycache__ -exec rm -r {} +
rm -rf /var/cache/pollinate/seeded /var/cache/snapd/* /var/cache/motd-news
rm -rf /var/lib/cloud /var/lib/dbus/machine-id /var/lib/private /var/lib/systemd/timers /var/lib/systemd/timesync /var/lib/systemd/random-seed
rm -f /var/lib/ubuntu-release-upgrader/release-upgrade-available
rm -f /var/lib/update-notifier/fsck-at-reboot /var/lib/update-notifier/hwe-eol
find /var/log -type f -exec rm -f {} +
rm -r /tmp/* /tmp/.*-unix /var/tmp/*
/bin/sync
EOF

chmod +x "${CACHE}/prepare-image.sh"

if [ "${VPC_MASTER_USE_PUBLICIP}" == "true" ]; then
    PUBLIC_IP_OPTIONS=--associate-public-ip-address
else
    PUBLIC_IP_OPTIONS=--no-associate-public-ip-address
fi

echo "Launch instance ${SEED_IMAGE} to ${TARGET_IMAGE}"
LAUNCHED_INSTANCE=$(aws ec2 run-instances \
    --profile ${AWS_PROFILE} \
    --region ${AWS_REGION} \
    --image-id ${SEED_IMAGE} \
    --count 1  \
    --instance-type ${INSTANCE_TYPE} \
    --key-name ${SSH_KEYNAME} \
    --subnet-id ${VPC_PUBLIC_SUBNET_ID} \
    --security-group-ids ${VPC_PUBLIC_SECURITY_GROUPID} \
    --block-device-mappings "file://${CACHE}/mapping.json" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${TARGET_IMAGE}}]" \
    ${PUBLIC_IP_OPTIONS})

LAUNCHED_ID=$(echo ${LAUNCHED_INSTANCE} | jq '.Instances[0].InstanceId' | tr -d '"' | sed -e 's/null//g')

if [ -z ${LAUNCHED_ID} ]; then
    echo "Something goes wrong when launching ${TARGET_IMAGE}"
    exit -1
fi

echo -n "Wait for ${TARGET_IMAGE} instanceID ${LAUNCHED_ID} to boot"

while [ ! "$(aws ec2  describe-instances --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-ids ${LAUNCHED_ID} | jq .Reservations[0].Instances[0].State.Code)" -eq 16 ];
do
    echo -n "."
    sleep 1
done

echo

LAUNCHED_INSTANCE=$(aws ec2  describe-instances --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-ids ${LAUNCHED_ID} | jq .Reservations[0].Instances[0])

if [ "${VPC_MASTER_USE_PUBLICIP}" == "true" ]; then
    export IPADDR=$(echo ${LAUNCHED_INSTANCE} | jq '.PublicIpAddress' | tr -d '"' | sed -e 's/null//g')
    IP_TYPE="public"
else
    export IPADDR=$(echo ${LAUNCHED_INSTANCE} | jq '.PrivateIpAddress' | tr -d '"' | sed -e 's/null//g')
    IP_TYPE="private"
fi

echo -n "Wait for ${TARGET_IMAGE} ssh ready for on ${IP_TYPE} IP=${IPADDR}"

while :
do
    echo -n "."
    scp ${SSH_OPTIONS} -o ConnectTimeout=1 "${CACHE}/prepare-image.sh" "${SEED_USER}@${IPADDR}":~ 2>/dev/null && break
    sleep 1
done

echo

ssh ${SSH_OPTIONS} -t "${SEED_USER}@${IPADDR}" sudo ./prepare-image.sh
ssh ${SSH_OPTIONS} -t "${SEED_USER}@${IPADDR}" rm ./prepare-image.sh

aws ec2 stop-instances --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-ids "${LAUNCHED_ID}" &> /dev/null

echo -n "Wait ${TARGET_IMAGE} to shutdown"
while [ ! $(aws ec2  describe-instances --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-ids "${LAUNCHED_ID}" | jq .Reservations[0].Instances[0].State.Code) -eq 80 ];
do
    echo -n "."
    sleep 1
done
echo

echo "Created image ${TARGET_IMAGE} with kubernetes version ${KUBERNETES_VERSION}"

IMAGEID=$(aws ec2 create-image --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-id "${LAUNCHED_ID}" --name "${TARGET_IMAGE}" --description "Kubernetes ${KUBERNETES_VERSION} image ready to use, based on AMI ${SEED_IMAGE}" | jq .ImageId | tr -d '"' | sed -e 's/null//g')

if [ -z $IMAGEID ]; then
    echo "Something goes wrong when creating image from ${TARGET_IMAGE}"
    exit -1
fi

echo -n "Wait AMI ${IMAGEID} to be available"
while [ ! $(aws ec2 describe-images --profile ${AWS_PROFILE} --region ${AWS_REGION} --image-ids "${IMAGEID}" | jq .Images[0].State | tr -d '"') == "available" ];
do
    echo -n "."
    sleep 5
done
echo

aws ec2 terminate-instances --profile ${AWS_PROFILE} --region ${AWS_REGION} --instance-ids "${LAUNCHED_ID}" &>/dev/null

exit 0

#!/bin/bash
CNI=aws
CLOUD_PROVIDER=aws
SCHEME="aws"
NODEGROUP_NAME="aws-ca-k8s"
MASTERKUBE="${NODEGROUP_NAME}-masterkube"
CLUSTER_DIR=/etc/cluster
HA_CLUSTER=
EXTERNAL_ETCD=NO
NODEINDEX=0
MASTER_NODE_ALLOW_DEPLOYMENT=NO
LOCALHOSTNAME=$(curl -s http://169.254.169.254/latest/meta-data/local-hostname)
INSTANCEID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
ZONEID=$(curl http://169.254.169.254/latest/meta-data/placement/availability-zone)
REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
INSTANCENAME=$(aws ec2  describe-instances --region $REGION --instance-ids $INSTANCEID | jq -r '.Reservations[0].Instances[0].Tags[]|select(.Key == "Name")|.Value')
IPADDR=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
USE_K3S=false
ETCD_ENDPOINT=

APISERVER_ADVERTISE_ADDRESS="${IPADDR}"
APISERVER_ADVERTISE_PORT="6443"

MASTER_IP=$(cat ./cluster/manager-ip)
TOKEN=$(cat ./cluster/token)

TEMP=$(getopt -o c:i:g: --long etcd-endpoint:,use-k3s:,allow-deployment:,join-master:,cloud-provider:,node-index:,use-external-etcd:,control-plane:,node-group: -n "$0" -- "$@")

eval set -- "${TEMP}"

# extract options and their arguments into variables.
while true; do
    case "$1" in
    -g|--node-group)
        NODEGROUP_NAME="$2"
        shift 2
        ;;
    -i|--node-index)
        NODEINDEX="$2"
        shift 2
        ;;
    -c|--cloud-provider)
        CLOUD_PROVIDER="$2"
        shift 2
        ;;
    --control-plane)
        HA_CLUSTER=$2
        shift 2
        ;;
    --use-external-etcd)
        EXTERNAL_ETCD=$2
        shift 2
        ;;
    --etcd-endpoint)
        ETCD_ENDPOINT="$2"
        shift 2
        ;;
    --join-master)
        MASTER_IP=$2
        shift 2
        ;;
    --allow-deployment)
        MASTER_NODE_ALLOW_DEPLOYMENT=$2 
        shift 2
        ;;
    --use-k3s)
        USE_K3S=$2
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

CONTROL_PLANE_ENDPOINT=${MASTER_IP%%:*}

mkdir -p /etc/kubernetes/pki/etcd

cp cluster/config /etc/kubernetes/admin.conf

export KUBECONFIG=/etc/kubernetes/admin.conf

if [ "$CLOUD_PROVIDER" == "aws" ]; then
    NODENAME=$LOCALHOSTNAME
else
    NODENAME=$HOSTNAME
fi

if [ ${USE_K3S} == "true" ]; then
    ANNOTE_MASTER=true
    echo "K3S_ARGS='--kubelet-arg=provider-id=aws://${ZONEID}/${INSTANCEID} --node-name=${NODENAME} --server=https://${MASTER_IP} --token=${TOKEN}'" > /etc/systemd/system/k3s.service.env

    if [ "$HA_CLUSTER" = "true" ]; then
        echo "K3S_MODE=server" > /etc/default/k3s

        if [ "$CLOUD_PROVIDER" == "aws" ] || [ "$CLOUD_PROVIDER" == "external" ]; then
            echo "K3S_DISABLE_ARGS='--disable-cloud-controller --disable=servicelb --disable=traefik --disable=metrics-server'" > /etc/systemd/system/k3s.disabled.env
        else
            echo "K3S_DISABLE_ARGS='--disable=servicelb --disable=traefik --disable=metrics-server'" > /etc/systemd/system/k3s.disabled.env
        fi

        if [ "${EXTERNAL_ETCD}" == "true" ] && [ -n "${ETCD_ENDPOINT}" ]; then
            echo "K3S_SERVER_ARGS='--datastore-endpoint=${ETCD_ENDPOINT} --datastore-cafile /etc/etcd/ssl/ca.pem --datastore-certfile /etc/etcd/ssl/etcd.pem --datastore-keyfile /etc/etcd/ssl/etcd-key.pem'" > /etc/systemd/system/k3s.server.env
        fi
    fi

    echo -n "Start k3s service"

    systemctl enable k3s.service
    systemctl start k3s.service

    echo -n "Wait node ${NODENAME} to be ready"

    while [ -z "$(kubectl get no ${NODENAME} 2>/dev/null | grep -v NAME)" ];
    do
        echo -n "."
        sleep 1
    done

    echo

else
    CACERT=$(cat ./cluster/ca.cert)

    if [ "$HA_CLUSTER" = "true" ]; then
        cp cluster/kubernetes/pki/ca.crt /etc/kubernetes/pki
        cp cluster/kubernetes/pki/ca.key /etc/kubernetes/pki
        cp cluster/kubernetes/pki/sa.key /etc/kubernetes/pki
        cp cluster/kubernetes/pki/sa.pub /etc/kubernetes/pki
        cp cluster/kubernetes/pki/front-proxy-ca.key /etc/kubernetes/pki
        cp cluster/kubernetes/pki/front-proxy-ca.crt /etc/kubernetes/pki

        chown -R root:root /etc/kubernetes/pki

        chmod 600 /etc/kubernetes/pki/ca.crt
        chmod 600 /etc/kubernetes/pki/ca.key
        chmod 600 /etc/kubernetes/pki/sa.key
        chmod 600 /etc/kubernetes/pki/sa.pub
        chmod 600 /etc/kubernetes/pki/front-proxy-ca.key
        chmod 600 /etc/kubernetes/pki/front-proxy-ca.crt

        if [ -f cluster/kubernetes/pki/etcd/ca.crt ]; then
            cp cluster/kubernetes/pki/etcd/ca.crt /etc/kubernetes/pki/etcd
            cp cluster/kubernetes/pki/etcd/ca.key /etc/kubernetes/pki/etcd

            chmod 600 /etc/kubernetes/pki/etcd/ca.crt
            chmod 600 /etc/kubernetes/pki/etcd/ca.key
        fi

        kubeadm join ${MASTER_IP} \
            --node-name "${NODENAME}" \
            --token "${TOKEN}" \
            --discovery-token-ca-cert-hash "sha256:${CACERT}" \
            --control-plane
    else
        kubeadm join ${MASTER_IP} \
            --node-name "${NODENAME}" \
            --token "${TOKEN}" \
            --discovery-token-ca-cert-hash "sha256:${CACERT}"
    fi

    cat > patch.yaml <<EOF
    spec:
        providerID: 'aws://${ZONEID}/${INSTANCEID}'
EOF

    kubectl patch node ${NODENAME} --patch-file patch.yaml
fi

if [ "$HA_CLUSTER" = "true" ]; then
    kubectl label nodes ${NODENAME} \
        "cluster.autoscaler.nodegroup/name=${NODEGROUP_NAME}" \
        "node-role.kubernetes.io/master=${ANNOTE_MASTER}" \
        "topology.kubernetes.io/region=${REGION}" \
        "topology.kubernetes.io/zone=${ZONEID}" \
        "master=true" \
        --overwrite

    if [ "${MASTER_NODE_ALLOW_DEPLOYMENT}" = "YES" ];then
        kubectl taint node ${NODENAME} node-role.kubernetes.io/master:NoSchedule-
    elif [ "${USE_K3S}" == "true" ]; then
        kubectl taint node ${HOSTNAME} node-role.kubernetes.io/master:NoSchedule node-role.kubernetes.io/control-plane:NoSchedule
    fi
else
    kubectl label nodes ${NODENAME} \
        "cluster.autoscaler.nodegroup/name=${NODEGROUP_NAME}" \
        "node-role.kubernetes.io/worker=${ANNOTE_MASTER}" \
        "topology.kubernetes.io/region=${REGION}" \
        "topology.kubernetes.io/zone=${ZONEID}" \
        "worker=true" \
        --overwrite
fi

kubectl annotate node ${NODENAME} \
    "cluster.autoscaler.nodegroup/name=${NODEGROUP_NAME}" \
    "cluster.autoscaler.nodegroup/instance-id=${INSTANCEID}" \
    "cluster.autoscaler.nodegroup/instance-name=${INSTANCENAME}" \
    "cluster.autoscaler.nodegroup/node-index=${NODEINDEX}" \
    "cluster.autoscaler.nodegroup/autoprovision=false" \
    "cluster-autoscaler.kubernetes.io/scale-down-disabled=true" \
    --overwrite

#!/bin/bash

set -e

export CNI_PLUGIN=aws
export CLOUD_PROVIDER=aws
export CONFIGURE_CLOUD_ROUTE=false
export KUBERNETES_VERSION=$(curl -sSL https://dl.k8s.io/release/stable.txt)
export CLUSTER_DIR=/etc/cluster
export SCHEME="aws"
export NODEGROUP_NAME="aws-ca-k8s"
export IPADDR=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
export LOCALHOSTNAME=$(curl -s http://169.254.169.254/latest/meta-data/local-hostname)
export INSTANCEID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
export REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
export INSTANCENAME=$(aws ec2  describe-instances --region $REGION --instance-ids $INSTANCEID | jq -r '.Reservations[0].Instances[0].Tags[]|select(.Key == "Name")|.Value')
export AWS_DOMAIN=${LOCALHOSTNAME#*.*}
export MAC_ADDRESS="$(curl -s http://169.254.169.254/latest/meta-data/mac)"
export SUBNET_IPV4_CIDR_BLOCK=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC_ADDRESS}/subnet-ipv4-cidr-block)
export VPC_IPV4_CIDR_BLOCK=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC_ADDRESS}/vpc-ipv4-cidr-block)
export DNS_SERVER=$(echo $VPC_IPV4_CIDR_BLOCK | tr './' ' '| awk '{print $1"."$2"."$3".2"}')
export KUBECONFIG=/etc/kubernetes/admin.conf
export KUBEADM_CONFIG=/etc/kubernetes/kubeadm-config.yaml
export K8_OPTIONS="--ignore-preflight-errors=All --config ${KUBEADM_CONFIG}"
export KUBEADM_TOKEN=$(kubeadm token generate)
export APISERVER_ADVERTISE_ADDRESS="${IPADDR}"
export APISERVER_ADVERTISE_PORT="6443"
export TOKEN_TLL="0s"
export POD_NETWORK_CIDR="10.244.0.0/16"
export SERVICE_NETWORK_CIDR="10.96.0.0/12"
export CLUSTER_DNS="10.96.0.10"
export CERT_EXTRA_SANS=()
export MAX_PODS=110
export PRIVATE_DOMAIN_NAME=
export ROUTE53_ZONEID=
export LOAD_BALANCER_IP=($IPADDR)
export EXTERNAL_ETCD=false
export NODEINDEX=0
export CLUSTER_NODES=()
export CONTAINER_ENGINE=docker
export CONTAINER_RUNTIME=docker
export CONTAINER_CTL=/var/run/dockershim.sock

# /var/run/crio/crio.sock

if [ "$(uname -p)" == "aarch64" ];  then
	ARCH="arm64"
else
	ARCH="amd64"
fi

TEMP=$(getopt -o xh:i:p:n:c:k:s: --long ecr-password:,allow-deployment:,container-runtime:,trace,control-plane-endpoint:,use-external-etcd:,cluster-nodes:,load-balancer-ip:,ha-cluster:,node-index:,private-zone-id:,private-zone-name:,cloud-provider:,max-pods:,node-group:,cert-extra-sans:,cni-plugin:,kubernetes-version: -n "$0" -- "$@")

eval set -- "${TEMP}"

# extract options and their arguments into variables.
while true; do
    case "$1" in
    -x|--trace)
        set -x
        shift 1
        ;;
    -p | --max-pods)
        MAX_PODS=$2
        shift 2
        ;;
    -n | --node-group)
        NODEGROUP_NAME="$2"
        shift 2
        ;;
    -i | --node-index)
        NODEINDEX="$2"
        shift 2
        ;;
    --ecr-password)
        ECR_PASSWORD=$2
        shift 2
        ;;
    --allow-deployment)
        MASTER_NODE_ALLOW_DEPLOYMENT=$2
        shift 2
        ;;

    --container-runtime)
        case "$2" in
            "docker")
                CONTAINER_ENGINE="docker"
                CONTAINER_RUNTIME=docker
                CONTAINER_CTL=/var/run/dockershim.sock
                ;;
            "containerd")
                CONTAINER_ENGINE="$2"
                CONTAINER_RUNTIME=remote
                CONTAINER_CTL=/var/run/containerd/containerd.sock
                ;;
            "cri-o")
                CONTAINER_ENGINE="$2"
                CONTAINER_RUNTIME=remote
                CONTAINER_CTL=/var/run/crio/crio.sock
                ;;
            *)
                echo "Unsupported container runtime: $2"
                exit 1
                ;;
        esac
        shift 2;;
    -c | --cni-plugin)
        CNI_PLUGIN="$2"
        shift 2
        ;;

    -h | --ha-cluster)
        HA_CLUSTER=$2
        shift 2
        ;;
    --load-balancer-ip)
        IFS=, read -a LOAD_BALANCER_IP <<<$2
        shift 2
        ;;
    --control-plane-endpoint)
        CONTROL_PLANE_ENDPOINT="$2"
        shift 2
        ;;
    --cluster-nodes)
        IFS=, read -a CLUSTER_NODES<<<$2
        shift 2
        ;;
    -k | --kubernetes-version)
        KUBERNETES_VERSION="$2"
        shift 2
        ;;

    -s | --cert-extra-sans)
        IFS=, read -a CERT_EXTRA_SANS<<<$2
        shift 2
        ;;

    --use-external-etcd)
        EXTERNAL_ETCD=$2
        shift 2
        ;;

    --cloud-provider)
        CLOUD_PROVIDER="$2"
        shift 2
        ;;

    --private-zone-id)
        ROUTE53_ZONEID="$2"
        shift 2
        ;;

    --private-zone-name)
        PRIVATE_DOMAIN_NAME="$2"
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

mkdir -p $CLUSTER_DIR
mkdir -p /etc/kubernetes

echo -n "${LOAD_BALANCER_IP[0]}:6443" > $CLUSTER_DIR/manager-ip

if [ -f /etc/kubernetes/kubelet.conf ]; then
    echo "Already installed k8s master node"
fi

if [ -e /etc/default/kubelet ]; then
  source /etc/default/kubelet
else
  touch /etc/default/kubelet
fi

systemctl restart kubelet

if [ -z "$CNI_PLUGIN" ]; then
    CNI_PLUGIN="calico"
fi

CNI_PLUGIN=$(echo "$CNI_PLUGIN" | tr '[:upper:]' '[:lower:]')

case $CNI_PLUGIN in
    aws)
        POD_NETWORK_CIDR="${SUBNET_IPV4_CIDR_BLOCK}"

        MAC=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/ -s | head -n 1 | sed 's/\/$//')
        TEN_RANGE=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/$MAC/vpc-ipv4-cidr-blocks | grep -c '^10\..*' || true )

        if [[ "$TEN_RANGE" != "0" ]]; then
          SERVICE_NETWORK_CIDR="172.20.0.0/16"
          CLUSTER_DNS="172.20.0.10"
        else
          CLUSTER_DNS="10.100.0.10"
          SERVICE_NETWORK_CIDR="10.100.0.0/16"
        fi
        ;;
    flannel)
        POD_NETWORK_CIDR="10.244.0.0/16"
        ;;
    weave|canal|kube|romana)
        POD_NETWORK_CIDR="10.244.0.0/16"
        ;;
    calico)
        POD_NETWORK_CIDR="192.168.0.0/16"
        ;;
    *)
        echo "CNI_PLUGIN '$CNI_PLUGIN' is not supported"
        exit -1
        ;;
esac

if [ "$CLOUD_PROVIDER" == "aws" ]; then
  NODENAME=$LOCALHOSTNAME
else
  NODENAME=$HOSTNAME
fi

cat > ${KUBEADM_CONFIG} <<EOF
apiVersion: kubeadm.k8s.io/v1beta2
kind: InitConfiguration
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: ${KUBEADM_TOKEN}
  ttl: ${TOKEN_TLL}
  usages:
  - signing
  - authentication
localAPIEndpoint:
  advertiseAddress: ${APISERVER_ADVERTISE_ADDRESS}
  bindPort: ${APISERVER_ADVERTISE_PORT}
nodeRegistration:
  criSocket: ${CONTAINER_CTL}
  name: ${NODENAME}
  taints:
  - effect: NoSchedule
    key: node-role.kubernetes.io/master
  - effect: NoSchedule
    key: node-role.kubernetes.io/control-plane
  kubeletExtraArgs:
    network-plugin: cni
    container-runtime: ${CONTAINER_RUNTIME}
    container-runtime-endpoint: ${CONTAINER_CTL}
    provider-id: ${SCHEME}://${NODEGROUP_NAME}/object?type=node&name=${INSTANCENAME}
    cloud-provider: "${CLOUD_PROVIDER}"
    node-ip: ${IPADDR}
---
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    cacheTTL: 0s
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 0s
    cacheUnauthorizedTTL: 0s
clusterDNS:
- ${CLUSTER_DNS}
cgroupDriver: systemd
failSwapOn: false
hairpinMode: hairpin-veth
readOnlyPort: 10255
clusterDomain: cluster.local
cpuManagerReconcilePeriod: 0s
evictionPressureTransitionPeriod: 0s
fileCheckFrequency: 0s
healthzBindAddress: 127.0.0.1
healthzPort: 10248
httpCheckFrequency: 0s
imageMinimumGCAge: 0s
nodeStatusReportFrequency: 0s
nodeStatusUpdateFrequency: 0s
rotateCertificates: true
runtimeRequestTimeout: 0s
staticPodPath: /etc/kubernetes/manifests
streamingConnectionIdleTimeout: 0s
syncFrequency: 0s
volumeStatsAggPeriod: 0s
maxPods: ${MAX_PODS}
---
apiVersion: kubeadm.k8s.io/v1beta2
kind: ClusterConfiguration
certificatesDir: /etc/kubernetes/pki
clusterName: ${NODEGROUP_NAME}
dns:
  type: CoreDNS
imageRepository: k8s.gcr.io
kubernetesVersion: ${KUBERNETES_VERSION}
networking:
  dnsDomain: cluster.local
  serviceSubnet: ${SERVICE_NETWORK_CIDR}
  podSubnet: ${POD_NETWORK_CIDR}
scheduler: {}
controllerManager:
  extraArgs:
    cloud-provider: "${CLOUD_PROVIDER}"
    configure-cloud-routes: "${CONFIGURE_CLOUD_ROUTE}"
controlPlaneEndpoint: ${CONTROL_PLANE_ENDPOINT}:${APISERVER_ADVERTISE_PORT}
apiServer:
  extraArgs:
    authorization-mode: Node,RBAC
    cloud-provider: "${CLOUD_PROVIDER}"
  timeoutForControlPlane: 4m0s
  certSANs:
  - ${CONTROL_PLANE_ENDPOINT}
  - ${CONTROL_PLANE_ENDPOINT%%.*}
EOF

echo "${APISERVER_ADVERTISE_ADDRESS} ${CONTROL_PLANE_ENDPOINT}" >> /etc/hosts

for LB_IP in ${LOAD_BALANCER_IP[*]} 
do
    echo "  - $LB_IP" >> ${KUBEADM_CONFIG}
done

for CERT_EXTRA in ${CERT_EXTRA_SANS[*]} 
do
    echo "  - $CERT_EXTRA" >> ${KUBEADM_CONFIG}
done

for CLUSTER_NODE in ${CLUSTER_NODES[*]}
do
echo CLUSTER_NODE=$CLUSTER_NODE
  IFS=: read HOST IP <<< $CLUSTER_NODE
  [ -z ${IP} ] || echo "  - ${IP}" >> ${KUBEADM_CONFIG}
  [ -z ${HOST} ] || echo "  - ${HOST}" >> ${KUBEADM_CONFIG}
  [ -z ${HOST} ] || echo "  - ${HOST%%.*}" >> ${KUBEADM_CONFIG}
done

    # External ETCD
if [ "$EXTERNAL_ETCD" = "true" ]; then
  cat >> ${KUBEADM_CONFIG} <<EOF
etcd:
  external:
    caFile: /etc/etcd/ssl/ca.pem
    certFile: /etc/etcd/ssl/etcd.pem
    keyFile: /etc/etcd/ssl/etcd-key.pem
    endpoints:
EOF

  for CLUSTER_NODE in ${CLUSTER_NODES[*]}
  do
      IFS=: read HOST IP <<< $CLUSTER_NODE
      if [ "x${IP}" != "x" ]; then
        echo "    - https://${IP}:2379" >> ${KUBEADM_CONFIG}
      fi
  done
fi

echo "Init K8 cluster with options:$K8_OPTIONS"

cat ${KUBEADM_CONFIG}

kubeadm init $K8_OPTIONS 2>&1

echo "Retrieve token infos"

openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //' | tr -d '\n' > $CLUSTER_DIR/ca.cert
kubeadm token list 2>&1 | grep "authentication,signing" | awk '{print $1}'  | tr -d '\n' > $CLUSTER_DIR/token 

echo "Set local K8 environement"

mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

cp /etc/kubernetes/admin.conf $CLUSTER_DIR/config

if [ "$HA_CLUSTER" = "true" ]; then
    mkdir -p $CLUSTER_DIR/kubernetes/pki/etcd

    cp /etc/kubernetes/pki/ca.crt $CLUSTER_DIR/kubernetes/pki
    cp /etc/kubernetes/pki/ca.key $CLUSTER_DIR/kubernetes/pki
    cp /etc/kubernetes/pki/sa.key $CLUSTER_DIR/kubernetes/pki
    cp /etc/kubernetes/pki/sa.pub $CLUSTER_DIR/kubernetes/pki
    cp /etc/kubernetes/pki/front-proxy-ca.crt $CLUSTER_DIR/kubernetes/pki
    cp /etc/kubernetes/pki/front-proxy-ca.key $CLUSTER_DIR/kubernetes/pki

    if [ "$EXTERNAL_ETCD" != "true" ]; then
        cp /etc/kubernetes/pki/etcd/ca.crt $CLUSTER_DIR/kubernetes/pki/etcd/ca.crt
        cp /etc/kubernetes/pki/etcd/ca.key $CLUSTER_DIR/kubernetes/pki/etcd/ca.key
    fi
fi

chmod -R uog+r $CLUSTER_DIR/*

# Password for AWS cni plugin
kubectl create secret docker-registry regcred --docker-server=602401143452.dkr.ecr.us-west-2.amazonaws.com --docker-username=AWS --docker-password=${ECR_PASSWORD}

if [ "$CNI_PLUGIN" = "aws" ]; then

    echo "Install AWS network"

    KUBERNETES_MINOR_RELEASE=$(kubectl version -o json | jq -r .serverVersion.minor)

    if [ $KUBERNETES_MINOR_RELEASE -gt 20 ]; then
      AWS_CNI_URL=https://raw.githubusercontent.com/aws/amazon-vpc-cni-k8s/release-1.10/config/master/aws-k8s-cni.yaml
    else
      AWS_CNI_URL=https://raw.githubusercontent.com/aws/amazon-vpc-cni-k8s/v1.9.3/config/v1.9/aws-k8s-cni.yaml
    fi

    case "${CONTAINER_ENGINE}" in
      cri-o)
        curl -s ${AWS_CNI_URL} | yq e -P - \
            | sed -e 's/mountPath: \/var\/run\/dockershim\.sock/mountPath: \/var\/run\/cri\.sock/g' -e 's/path: \/var\/run\/dockershim\.sock/path: \/var\/run\/cri\.sock/g' > cni-aws.yaml
        ;;
      containerd)
        curl -s ${AWS_CNI_URL} | yq e -P - \
            | sed -e 's/mountPath: \/var\/run\/dockershim\.sock/mountPath: \/var\/run\/cri\.sock/g' -e 's/path: \/var\/run\/dockershim\.sock/path: \/var\/run\/containerd\/containerd\.sock/g' > cni-aws.yaml
        ;;
      *)
        curl -s ${AWS_CNI_URL} > cni-aws.yaml
        ;;
    esac

    if [ $CONTAINER_ENGINE == "cri-o" ]; then
      curl -s ${AWS_CNI_URL} | yq e -P - \
          | sed -e 's/mountPath: \/var\/run\/dockershim\.sock/mountPath: \/var\/run\/cri\.sock/g' -e 's/path: \/var\/run\/dockershim\.sock/path: \/var\/run\/cri\.sock/g' > cni-aws.yaml
    elif [ $CONTAINER_ENGINE == "containerd" ]; then
      curl -s ${AWS_CNI_URL} | yq e -P - \
          | sed -e 's/mountPath: \/var\/run\/dockershim\.sock/mountPath: \/var\/run\/cri\.sock/g' -e 's/path: \/var\/run\/dockershim\.sock/path: \/var\/run\/containerd\/containerd\.sock/g' > cni-aws.yaml
    else
      curl -s ${AWS_CNI_URL} > cni-aws.yaml
    fi

    kubectl apply -f cni-aws.yaml

    kubectl set env daemonset -n kube-system aws-node AWS_VPC_K8S_CNI_EXCLUDE_SNAT_CIDRS=${VPC_IPV4_CIDR_BLOCK}

elif [ "$CNI_PLUGIN" = "calico" ]; then

    echo "Install calico network"

    kubectl apply -f "https://docs.projectcalico.org/manifests/calico-vxlan.yaml" 2>&1

elif [ "$CNI_PLUGIN" = "flannel" ]; then

    echo "Install flannel network"

    kubectl apply -f "https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml" 2>&1

elif [ "$CNI_PLUGIN" = "weave" ]; then

    echo "Install weave network for K8"

    kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')" 2>&1

elif [ "$CNI_PLUGIN" = "canal" ]; then

    echo "Install canal network"

    kubectl apply -f "https://raw.githubusercontent.com/projectcalico/canal/master/k8s-install/1.7/rbac.yaml" 2>&1
    kubectl apply -f "https://raw.githubusercontent.com/projectcalico/canal/master/k8s-install/1.7/canal.yaml" 2>&1

    #CNI_SELECTOR="k8s-app=canal"

elif [ "$CNI_PLUGIN" = "kube" ]; then

    echo "Install kube network"

    kubectl apply -f "https://raw.githubusercontent.com/cloudnativelabs/kube-router/master/daemonset/kubeadm-kuberouter.yaml" 2>&1
    kubectl apply -f "https://raw.githubusercontent.com/cloudnativelabs/kube-router/master/daemonset/kubeadm-kuberouter-all-features.yaml" 2>&1

    #CNI_SELECTOR="k8s-app=kube-router"

elif [ "$CNI_PLUGIN" = "romana" ]; then

    echo "Install romana network"

    kubectl apply -f https://raw.githubusercontent.com/romana/romana/master/containerize/specs/romana-kubeadm.yml 2>&1

    #CNI_SELECTOR="romana-app=etcd"
fi

kubectl label nodes ${NODENAME} "cluster.autoscaler.nodegroup/name=${NODEGROUP_NAME}" \
    "node-role.kubernetes.io/master=" \
    "master=true" --overwrite

kubectl annotate node ${NODENAME} \
  "cluster.autoscaler.nodegroup/name=${NODEGROUP_NAME}" \
  "cluster.autoscaler.nodegroup/instance-id=${INSTANCEID}" \
  "cluster.autoscaler.nodegroup/instance-name=${INSTANCENAME}" \
  "cluster.autoscaler.nodegroup/node-index=${NODEINDEX}" \
  "cluster.autoscaler.nodegroup/autoprovision=false" \
  "cluster-autoscaler.kubernetes.io/scale-down-disabled=true" \
  --overwrite

if [ ${MASTER_NODE_ALLOW_DEPLOYMENT} = "YES" ];then
  kubectl taint node ${NODENAME} node-role.kubernetes.io/master:NoSchedule-
fi

sed -i -e "/${CONTROL_PLANE_ENDPOINT%%.}/d" /etc/hosts

echo "Done k8s master node"

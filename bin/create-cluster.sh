#!/bin/bash

set -e

export CNI_PLUGIN=aws
export CLOUD_PROVIDER=aws
export CONFIGURE_CLOUD_ROUTE=false
export KUBERNETES_DISTRO=kubeadm
export KUBERNETES_VERSION=$(curl -sSL https://dl.k8s.io/release/stable.txt)
export CLUSTER_DIR=/etc/cluster
export SCHEME="aws"
export NODEGROUP_NAME="aws-ca-k8s"
export IPADDR=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
export LOCALHOSTNAME=$(curl -s http://169.254.169.254/latest/meta-data/local-hostname)
export INSTANCEID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
export REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
export ZONEID=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
export INSTANCENAME=$(aws ec2  describe-instances --region $REGION --instance-ids $INSTANCEID | jq -r '.Reservations[0].Instances[0].Tags[]|select(.Key == "Name")|.Value')
export AWS_DOMAIN=${LOCALHOSTNAME#*.*}
export MAC_ADDRESS="$(curl -s http://169.254.169.254/latest/meta-data/mac)"
export SUBNET_IPV4_CIDR_BLOCK=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC_ADDRESS}/subnet-ipv4-cidr-block)
export VPC_IPV4_CIDR_BLOCK=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC_ADDRESS}/vpc-ipv4-cidr-block)
export DNS_SERVER=$(echo $VPC_IPV4_CIDR_BLOCK | tr './' ' '| awk '{print $1"."$2"."$3".2"}')
export KUBECONFIG=/etc/kubernetes/admin.conf
export KUBEADM_CONFIG=/etc/kubernetes/kubeadm-config.yaml
export K8_OPTIONS="--ignore-preflight-errors=All --config ${KUBEADM_CONFIG}"
export APISERVER_ADVERTISE_ADDRESS="${IPADDR}"
export APISERVER_ADVERTISE_PORT="6443"
export TOKEN_TLL="0s"
export POD_NETWORK_CIDR="10.244.0.0/16"
export SERVICE_NETWORK_CIDR="10.96.0.0/12"
export CLUSTER_DNS="10.96.0.10"
export CERT_EXTRA_SANS=()
export MAX_PODS=110
export PRIVATE_DOMAIN_NAME=
export AWS_ROUTE53_ZONE_ID=
export LOAD_BALANCER_IP=($IPADDR)
export EXTERNAL_ETCD=false
export NODEINDEX=0
export CLUSTER_NODES=()
export CERT_SANS=
export CONTAINER_ENGINE=docker
export CONTAINER_RUNTIME=docker
export CONTAINER_CTL=unix:///var/run/dockershim.sock
export ETCD_ENDPOINT=
export DELETE_CREDENTIALS_CONFIG=NO

# /var/run/crio/crio.sock

if [ "$(uname -p)" == "aarch64" ]; then
	ARCH="arm64"
else
	ARCH="amd64"
fi

TEMP=$(getopt -o xh:i:p:n:c:k:s: --long tls-san:,delete-credentials-provider:,etcd-endpoint:,k8s-distribution:,ecr-password:,allow-deployment:,container-runtime:,trace,control-plane-endpoint:,use-external-etcd:,cluster-nodes:,load-balancer-ip:,ha-cluster:,node-index:,private-zone-id:,private-zone-name:,cloud-provider:,max-pods:,node-group:,cni-plugin:,kubernetes-version: -n "$0" -- "$@")

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
    --delete-credentials-provider)
        DELETE_CREDENTIALS_CONFIG=$2
        shift 2
        ;;
    --k8s-distribution)
        case "$2" in
            kubeadm|k3s|rke2)
                KUBERNETES_DISTRO=$2
                ;;
            *)
                echo "Unsupported kubernetes distribution: $2"
                exit 1
                ;;
        esac
        shift 2
        ;;
    --container-runtime)
        case "$2" in
            "docker")
                CONTAINER_ENGINE="docker"
                CONTAINER_RUNTIME=docker
                CONTAINER_CTL=unix:///var/run/dockershim.sock
                ;;
            "containerd")
                CONTAINER_ENGINE="$2"
                CONTAINER_RUNTIME=remote
                CONTAINER_CTL=unix:///var/run/containerd/containerd.sock
                ;;
            "cri-o")
                CONTAINER_ENGINE="$2"
                CONTAINER_RUNTIME=remote
                CONTAINER_CTL=unix:///var/run/crio/crio.sock
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
        IFS=, read -a LOAD_BALANCER_IP <<< "$2"
        shift 2
        ;;
    --control-plane-endpoint)
        CONTROL_PLANE_ENDPOINT="$2"
        shift 2
        ;;
    --cluster-nodes)
        IFS=, read -a CLUSTER_NODES <<< "$2"
        shift 2
        ;;
    -k | --kubernetes-version)
        KUBERNETES_VERSION="$2"
        shift 2
        ;;

    --tls-san)
        CERT_SANS="$2"
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

    --cloud-provider)
        CLOUD_PROVIDER="$2"
        shift 2
        ;;

    --private-zone-id)
        AWS_ROUTE53_ZONE_ID="$2"
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

# Hack because k3s and rke2 1.28.4 don't set the good feature gates
if [ "${DELETE_CREDENTIALS_CONFIG}" == "YES" ]; then
    case "${KUBERNETES_DISTRO}" in
        k3s|rke2)
            rm -rf /var/lib/rancher/credentialprovider
            ;;
    esac
fi

mkdir -p $CLUSTER_DIR
mkdir -p /etc/kubernetes

echo -n "${LOAD_BALANCER_IP[0]}:6443" > $CLUSTER_DIR/manager-ip

if [ "$CLOUD_PROVIDER" == "aws" ]; then
  NODENAME=$LOCALHOSTNAME
else
  NODENAME=$HOSTNAME
fi

if [ ${KUBERNETES_DISTRO} == "rke2" ]; then
  ANNOTE_MASTER=true

  cat > /etc/rancher/rke2/config.yaml <<EOF
kubelet-arg:
  - cloud-provider=external
  - fail-swap-on=false
  - provider-id=aws://${ZONEID}/${INSTANCEID}
  - max-pods=${MAX_PODS}
node-name: ${HOSTNAME}
advertise-address: ${APISERVER_ADVERTISE_ADDRESS}
disable-cloud-controller: true
cloud-provider-name: external
disable:
  - rke2-ingress-nginx
  - rke2-metrics-server
  - servicelb
tls-san:
EOF

  for CERT_SAN in $(echo -n ${CERT_SANS} | tr ',' ' ')
  do
    echo "  - ${CERT_SAN}" >> /etc/rancher/rke2/config.yaml
  done

  if [ "$HA_CLUSTER" = "true" ]; then
    if [ "${EXTERNAL_ETCD}" == "true" ] && [ -n "${ETCD_ENDPOINT}" ]; then
      echo "disable-etcd: true" >> /etc/rancher/rke2/config.yaml
      echo "datastore-endpoint: ${ETCD_ENDPOINT}" >> /etc/rancher/rke2/config.yaml
      echo "datastore-cafile: /etc/etcd/ssl/ca.pem" >> /etc/rancher/rke2/config.yaml
      echo "datastore-certfile: /etc/etcd/ssl/etcd.pem" >> /etc/rancher/rke2/config.yaml
      echo "datastore-keyfile: /etc/etcd/ssl/etcd-key.pem" >> /etc/rancher/rke2/config.yaml
    else
      echo "cluster-init: true" >> /etc/rancher/rke2/config.yaml
    fi
  fi

  echo -n "Start rke2-server service"

  systemctl enable rke2-server.service
  systemctl start rke2-server.service

  while [ ! -f /etc/rancher/rke2/rke2.yaml ];
  do
    echo -n "."
    sleep 1
  done

  echo

  mkdir -p $CLUSTER_DIR/kubernetes/pki

  mkdir -p $HOME/.kube
  cp -i /etc/rancher/rke2/rke2.yaml $HOME/.kube/config
  chown $(id -u):$(id -g) $HOME/.kube/config

  cp /etc/rancher/rke2/rke2.yaml $CLUSTER_DIR/config
  cp /var/lib/rancher/rke2/server/token $CLUSTER_DIR/token
  cp -r /var/lib/rancher/rke2/server/tls/* $CLUSTER_DIR/kubernetes/pki/

  openssl x509 -pubkey -in /var/lib/rancher/rke2/server/tls/server-ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //' | tr -d '\n' > $CLUSTER_DIR/ca.cert

  sed -i -e "s/127.0.0.1/${CONTROL_PLANE_ENDPOINT}/g" -e "s/default/k8s-${HOSTNAME}-admin@${NODEGROUP_NAME}/g" $CLUSTER_DIR/config

  rm -rf $CLUSTER_DIR/kubernetes/pki/temporary-certs

  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

  echo -n "Wait node ${HOSTNAME} to be ready"

  while [ -z "$(kubectl get no ${HOSTNAME} 2>/dev/null | grep -v NAME)" ];
  do
    echo -n "."
    sleep 1
  done

  echo

elif [ ${KUBERNETES_DISTRO} == "k3s" ]; then
  ANNOTE_MASTER=true

  echo "K3S_MODE=server" > /etc/default/k3s
  echo "K3S_ARGS='--kubelet-arg=provider-id=aws://${ZONEID}/${INSTANCEID} --node-name=${NODENAME} --advertise-address=${APISERVER_ADVERTISE_ADDRESS} --advertise-port=${APISERVER_ADVERTISE_PORT} --tls-san=${CERT_SANS}'" > /etc/systemd/system/k3s.service.env

  if [ "$CLOUD_PROVIDER" == "aws" ] || [ "$CLOUD_PROVIDER" == "external" ]; then
    echo "K3S_DISABLE_ARGS='--disable-cloud-controller --disable=servicelb --disable=traefik --disable=metrics-server'" > /etc/systemd/system/k3s.disabled.env
  else
    echo "K3S_DISABLE_ARGS='--disable=servicelb --disable=traefik --disable=metrics-server'" > /etc/systemd/system/k3s.disabled.env
  fi

  if [ "$HA_CLUSTER" = "true" ]; then
      if [ "${EXTERNAL_ETCD}" == "true" ] && [ -n "${ETCD_ENDPOINT}" ]; then
          echo "K3S_SERVER_ARGS='--datastore-endpoint=${ETCD_ENDPOINT} --datastore-cafile /etc/etcd/ssl/ca.pem --datastore-certfile /etc/etcd/ssl/etcd.pem --datastore-keyfile /etc/etcd/ssl/etcd-key.pem'" > /etc/systemd/system/k3s.server.env
      else
          echo "K3S_SERVER_ARGS=--cluster-init" > /etc/systemd/system/k3s.server.env
      fi
  fi

  echo -n "Start k3s service"

  systemctl enable k3s.service
  systemctl start k3s.service

  while [ ! -f /etc/rancher/k3s/k3s.yaml ];
  do
    echo -n "."
    sleep 1
  done

  echo

  mkdir -p $CLUSTER_DIR/kubernetes/pki

  mkdir -p $HOME/.kube
  cp -i /etc/rancher/k3s/k3s.yaml $HOME/.kube/config
  chown $(id -u):$(id -g) $HOME/.kube/config

  cp /etc/rancher/k3s/k3s.yaml $CLUSTER_DIR/config
  cp /var/lib/rancher/k3s/server/token $CLUSTER_DIR/token
  cp -r /var/lib/rancher/k3s/server/tls/* $CLUSTER_DIR/kubernetes/pki/

  openssl x509 -pubkey -in /var/lib/rancher/k3s/server/tls/server-ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //' | tr -d '\n' > $CLUSTER_DIR/ca.cert

  sed -i -e "s/127.0.0.1/${CONTROL_PLANE_ENDPOINT}/g" -e "s/default/k8s-${NODEGROUP_NAME}-masterkube-admin@${NODEGROUP_NAME}/g" $CLUSTER_DIR/config

  rm -rf $CLUSTER_DIR/kubernetes/pki/temporary-certs

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  echo -n "Wait node ${NODENAME} to be ready"

  while [ -z "$(kubectl get no ${NODENAME} 2>/dev/null | grep -v NAME)" ];
  do
    echo -n "."
    sleep 1
  done

  echo

else
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
  KUBEADM_TOKEN=$(kubeadm token generate)

  case $CNI_PLUGIN in
      aws)
          POD_NETWORK_CIDR="${VPC_IPV4_CIDR_BLOCK}"
          TEN_RANGE=$(echo -n ${VPC_IPV4_CIDR_BLOCK} | grep -c '^10\..*' || true )

          if [ $TEN_RANGE -eq 0 ]; then
            CLUSTER_DNS="10.100.0.10"
            SERVICE_NETWORK_CIDR="10.100.0.0/16"
          else
            SERVICE_NETWORK_CIDR="172.20.0.0/16"
            CLUSTER_DNS="172.20.0.10"
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

  cat > ${KUBEADM_CONFIG} <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
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
    container-runtime: ${CONTAINER_RUNTIME}
    container-runtime-endpoint: ${CONTAINER_CTL}
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
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
certificatesDir: /etc/kubernetes/pki
clusterName: ${NODEGROUP_NAME}
imageRepository: registry.k8s.io
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
#dns:
#  imageRepository: registry.k8s.io/coredns
#  imageTag: v1.9.3
apiServer:
  extraArgs:
    authorization-mode: Node,RBAC
    cloud-provider: "${CLOUD_PROVIDER}"
  timeoutForControlPlane: 4m0s
  certSANs:
EOF

  echo "${APISERVER_ADVERTISE_ADDRESS} ${CONTROL_PLANE_ENDPOINT}" >> /etc/hosts

  for CERT_SAN in $(echo -n ${CERT_SANS} | tr ',' ' ')
  do
    echo "  - $CERT_SAN" >> ${KUBEADM_CONFIG}
  done

# External ETCD
  if [ "$EXTERNAL_ETCD" = "true" ] && [ -n "${ETCD_ENDPOINT}" ]; then
    cat >> ${KUBEADM_CONFIG} <<EOF
etcd:
  external:
    caFile: /etc/etcd/ssl/ca.pem
    certFile: /etc/etcd/ssl/etcd.pem
    keyFile: /etc/etcd/ssl/etcd-key.pem
    endpoints:
EOF

  for ENDPOINT in $(echo -n ${ETCD_ENDPOINT} | tr ',' ' ')
  do
    echo "    - ${ENDPOINT}" >> ${KUBEADM_CONFIG}
  done
fi

  # If version 27 or greater, remove this kuletet argument
  if [ $MAJOR -ge 27 ]; then
    sed -i '/container-runtime:/d' ${KUBEADM_CONFIG}
  fi

  echo "Init K8 cluster with options:$K8_OPTIONS"

  cat ${KUBEADM_CONFIG}

  kubeadm init $K8_OPTIONS 2>&1

  echo "Retrieve token infos"

  openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //' | tr -d '\n' > $CLUSTER_DIR/ca.cert
  kubeadm token list 2>&1 | grep "authentication,signing" | awk '{print $1}'  | tr -d '\n' > $CLUSTER_DIR/token 

  echo "Get token:$(cat $CLUSTER_DIR/token)"
  echo "Get cacert:$(cat $CLUSTER_DIR/ca.cert)"
  echo "Set local K8 environement"

  mkdir -p $HOME/.kube
  cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  chown $(id -u):$(id -g) $HOME/.kube/config

  cp /etc/kubernetes/admin.conf $CLUSTER_DIR/config

  export KUBECONFIG=/etc/kubernetes/admin.conf

  mkdir -p $CLUSTER_DIR/kubernetes/pki

  cp /etc/kubernetes/pki/ca.crt $CLUSTER_DIR/kubernetes/pki
  cp /etc/kubernetes/pki/ca.key $CLUSTER_DIR/kubernetes/pki
  cp /etc/kubernetes/pki/sa.key $CLUSTER_DIR/kubernetes/pki
  cp /etc/kubernetes/pki/sa.pub $CLUSTER_DIR/kubernetes/pki
  cp /etc/kubernetes/pki/front-proxy-ca.crt $CLUSTER_DIR/kubernetes/pki
  cp /etc/kubernetes/pki/front-proxy-ca.key $CLUSTER_DIR/kubernetes/pki

  if [ "$EXTERNAL_ETCD" != "true" ]; then
      mkdir -p $CLUSTER_DIR/kubernetes/pki/etcd
      cp /etc/kubernetes/pki/etcd/ca.crt $CLUSTER_DIR/kubernetes/pki/etcd/ca.crt
      cp /etc/kubernetes/pki/etcd/ca.key $CLUSTER_DIR/kubernetes/pki/etcd/ca.key
  fi

  chmod -R uog+r $CLUSTER_DIR/*

  # Password for AWS cni plugin
  kubectl create secret docker-registry aws-registry --docker-server=602401143452.dkr.ecr.us-west-2.amazonaws.com --docker-username=AWS --docker-password=${ECR_PASSWORD}

  if [ "$CNI_PLUGIN" = "aws" ]; then

      echo "Install AWS network"

      KUBERNETES_MINOR_RELEASE=$(kubectl version -o json | jq -r .serverVersion.minor)
      UBUNTU_VERSION_ID=$(cat /etc/os-release | grep VERSION_ID | tr -d '"' | cut -d '=' -f 2 | cut -d '.' -f 1)

      if [ $KUBERNETES_MINOR_RELEASE -gt 26 ]; then
        AWS_CNI_URL=https://raw.githubusercontent.com/aws/amazon-vpc-cni-k8s/v1.15.5/config/master/aws-k8s-cni.yaml
      elif [ $KUBERNETES_MINOR_RELEASE -gt 25 ]; then
        AWS_CNI_URL=https://raw.githubusercontent.com/aws/amazon-vpc-cni-k8s/v1.14.1/config/master/aws-k8s-cni.yaml
      elif [ $KUBERNETES_MINOR_RELEASE -gt 24 ]; then
        AWS_CNI_URL=https://raw.githubusercontent.com/aws/amazon-vpc-cni-k8s/v1.12.1/config/master/aws-k8s-cni.yaml
      elif [ $KUBERNETES_MINOR_RELEASE -gt 22 ]; then
        AWS_CNI_URL=https://raw.githubusercontent.com/aws/amazon-vpc-cni-k8s/release-1.11/config/master/aws-k8s-cni.yaml
      elif [ $KUBERNETES_MINOR_RELEASE -gt 20 ]; then
        AWS_CNI_URL=https://raw.githubusercontent.com/aws/amazon-vpc-cni-k8s/release-1.10/config/master/aws-k8s-cni.yaml
      else
        AWS_CNI_URL=https://raw.githubusercontent.com/aws/amazon-vpc-cni-k8s/v1.9.3/config/v1.9/aws-k8s-cni.yaml
      fi

      if [ $CONTAINER_ENGINE == "cri-o" ]; then
        curl -s ${AWS_CNI_URL} | yq e -P - \
            | sed -e 's/mountPath: \/var\/run\/dockershim\.sock/mountPath: \/var\/run\/cri\.sock/g' -e 's/path: \/var\/run\/dockershim\.sock/path: \/var\/run\/cri\.sock/g' > cni-aws.yaml
      elif [ $CONTAINER_ENGINE == "containerd" ]; then
        curl -s ${AWS_CNI_URL} | yq e -P - \
            | sed -e 's/mountPath: \/var\/run\/dockershim\.sock/mountPath: \/var\/run\/cri\.sock/g' -e 's/path: \/var\/run\/dockershim\.sock/path: \/var\/run\/containerd\/containerd\.sock/g' > cni-aws.yaml
      else
        curl -s ${AWS_CNI_URL} > cni-aws.yaml
      fi

      # https://github.com/aws/amazon-vpc-cni-k8s/issues/2103
      if [ ${UBUNTU_VERSION_ID} -ge 22 ]; then
        sed -i '/ENABLE_IPv6/i\            - name: ENABLE_NFTABLES\n              value: "true"' cni-aws.yaml
      fi

      kubectl apply -f cni-aws.yaml

      kubectl set env daemonset -n kube-system aws-node AWS_VPC_K8S_CNI_EXCLUDE_SNAT_CIDRS=${VPC_IPV4_CIDR_BLOCK}

  elif [ "$CNI_PLUGIN" = "calico" ]; then

      echo "Install calico network"

      kubectl apply -f "https://docs.projectcalico.org/manifests/calico-vxlan.yaml" 2>&1

  elif [ "$CNI_PLUGIN" = "flannel" ]; then

      echo "Install flannel network"

      kubectl apply -f "https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml" 2>&1

  elif [ "$CNI_PLUGIN" = "weave" ]; then

      echo "Install weave network for K8"

      kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')" 2>&1

  elif [ "$CNI_PLUGIN" = "canal" ]; then

      echo "Install canal network"

      kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/v3.24.5/manifests/canal.yaml" 2>&1

  elif [ "$CNI_PLUGIN" = "kube" ]; then

      echo "Install kube network"

      kubectl apply -f "https://raw.githubusercontent.com/cloudnativelabs/kube-router/master/daemonset/kubeadm-kuberouter.yaml" 2>&1
      kubectl apply -f "https://raw.githubusercontent.com/cloudnativelabs/kube-router/master/daemonset/kubeadm-kuberouter-all-features.yaml" 2>&1

  elif [ "$CNI_PLUGIN" = "romana" ]; then

      echo "Install romana network"

      kubectl apply -f https://raw.githubusercontent.com/romana/romana/master/containerize/specs/romana-kubeadm.yml 2>&1

  fi

  cat > patch.yaml <<EOF
spec:
    providerID: 'aws://${ZONEID}/${INSTANCEID}'
EOF

  kubectl patch node ${NODENAME} --patch-file patch.yaml
fi

chmod -R uog+r $CLUSTER_DIR/*

kubectl label nodes ${NODENAME} "cluster.autoscaler.nodegroup/name=${NODEGROUP_NAME}" \
    "node-role.kubernetes.io/master=${ANNOTE_MASTER}" \
    "topology.kubernetes.io/region=${REGION}" \
    "topology.kubernetes.io/zone=${ZONEID}" \
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
  kubectl taint node ${HOSTNAME} node-role.kubernetes.io/master:NoSchedule- node-role.kubernetes.io/control-plane:NoSchedule-
elif [ "${KUBERNETES_DISTRO}" == "k3s" ]; then
  kubectl taint node ${HOSTNAME} node-role.kubernetes.io/master:NoSchedule node-role.kubernetes.io/control-plane:NoSchedule
fi

sed -i -e "/${CONTROL_PLANE_ENDPOINT%%.}/d" /etc/hosts

echo "Done k8s master node"

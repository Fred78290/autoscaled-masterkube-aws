#!/bin/bash
KUBERNETES_VERSION=$1
CNI_VERSION="v1.0.1"

if [ "$(uname -p)" == "aarch64" ];  then
	ARCH="arm64"
else
	ARCH="amd64"
fi

curl -s https://get.docker.com | bash

if [ "x$KUBERNETES_VERSION" == "x" ]; then
	RELEASE="$(curl -sSL https://dl.k8s.io/release/stable.txt)"
else
	RELEASE=$KUBERNETES_VERSION
fi

echo "Prepare kubernetes version $RELEASE"

mkdir -p /opt/cni/bin
curl -sL "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-${ARCH}-${CNI_VERSION}.tgz" | tar -C /opt/cni/bin -xz

mkdir -p /usr/local/bin
cd /usr/local/bin
curl -sL --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${RELEASE}/bin/linux/${ARCH}/{kubeadm,kubelet,kubectl}
chmod +x /usr/local/bin/kube*

echo "KUBELET_EXTRA_ARGS='--fail-swap-on=false --read-only-port=10255'" > /etc/default/kubelet

curl -sSL "https://raw.githubusercontent.com/kubernetes/kubernetes/${RELEASE}/build/debs/kubelet.service" | sed "s:/usr/bin:/usr/local/bin:g" > /etc/systemd/system/kubelet.service
mkdir -p /etc/systemd/system/kubelet.service.d
curl -sSL "https://raw.githubusercontent.com/kubernetes/kubernetes/${RELEASE}/build/debs/10-kubeadm.conf" | sed "s:/usr/bin:/usr/local/bin:g" > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

systemctl enable kubelet

echo 'export PATH=/opt/cni/bin:$PATH' >> /etc/bash.bashrc

kubeadm config images pull --kubernetes-version=$RELEASE

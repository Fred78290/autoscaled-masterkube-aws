#!/bin/bash
set -e

CURDIR=$(dirname $0)
SSH_OPTIONS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
SCP_OPTIONS="${SSH_OPTIONS} -p -r"

KUBECONFIG_CONTEXT=k8s-${MASTERKUBE}-admin@${NODEGROUP_NAME}

mkdir -p ${TARGET_CONFIG_LOCATION}
mkdir -p ${TARGET_CLUSTER_LOCATION}

kubectl config get-contexts ${KUBECONFIG_CONTEXT} &>/dev/null || (echo_red_bold "Cluster ${KUBECONFIG_CONTEXT} not found in kubeconfig" ; exit 1)
kubectl config set-context ${KUBECONFIG_CONTEXT} &>/dev/null

pushd ${CURDIR}/../ &>/dev/null

source ${PWD}/bin/common.sh

# Keep directory location
KEEP_TARGET_CONFIG_LOCATION=${TARGET_CONFIG_LOCATION}
KEEP_TARGET_DEPLOY_LOCATION=${TARGET_DEPLOY_LOCATION}
KEEP_TARGET_CLUSTER_LOCATION=${TARGET_CLUSTER_LOCATION}
KEEP_SSL_LOCATION=${SSL_LOCATION}
KEEP_SSH_PRIVATE_KEY=${SSH_PRIVATE_KEY}
KEEP_SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY}
KEEP_TARGET_IMAGE=${TARGET_IMAGE}
KEEP_KUBERNETES_VERSION=${KUBERNETES_VERSION}

function extract_configmap() {
	local NAMESPACE=$2
	local NAME=$1
	local DSTDIR=$3

	local CONFIGMAP=$(kubectl get cm ${NAME} -n ${NAMESPACE} -o json)
	local FILES=$(echo ${CONFIGMAP} | jq -r '.data | keys_unsorted|.[]')
	local CONTENT=

	mkdir -p ${DSTDIR}
	pushd ${DSTDIR} &>/dev/null

	for FILE in ${FILES}
	do
		JQPATH='.data."'${FILE}'"'
		CONTENT=$(echo ${CONFIGMAP} | jq -r "${JQPATH}")
		echo -n "${CONTENT}" > ${FILE}
	done

	popd &>/dev/null
}

function extract_deployment() {
	local NAMESPACE=$1
	local CM=

	for CM in $(kubectl get cm -n ${NODEGROUP_NAME} -o json | jq -r '.items[]|.metadata.name')
	do
		extract_configmap ${CM} ${NODEGROUP_NAME} "${TARGET_CONFIG_LOCATION}/../deployment/${CM}"
	done
}

if [ ! -f "${TARGET_CONFIG_LOCATION}/buildenv" ]; then
	echo_title "Restore config files"

	extract_configmap kubernetes-pki kube-system ${TARGET_CLUSTER_LOCATION}/kubernetes/pki
	extract_configmap cluster ${NODEGROUP_NAME} ${TARGET_CLUSTER_LOCATION}
	extract_configmap config ${NODEGROUP_NAME} ${TARGET_CONFIG_LOCATION}
	extract_deployment ${NODEGROUP_NAME}
fi

if [ ! -f "${TARGET_CONFIG_LOCATION}/buildenv" ]; then
	echo_red_bold "${TARGET_CONFIG_LOCATION}/buildenv not found, exit"
	exit 1
fi

source ${TARGET_CONFIG_LOCATION}/buildenv

# Restore directory location
TARGET_CONFIG_LOCATION=${KEEP_TARGET_CONFIG_LOCATION}
TARGET_DEPLOY_LOCATION=${KEEP_TARGET_DEPLOY_LOCATION}
TARGET_CLUSTER_LOCATION=${KEEP_TARGET_CLUSTER_LOCATION}
SSL_LOCATION=${KEEP_SSL_LOCATION}
SSH_PRIVATE_KEY=${KEEP_SSH_PRIVATE_KEY}
SSH_PUBLIC_KEY=${KEEP_SSH_PUBLIC_KEY}
TARGET_IMAGE=${KEEP_TARGET_IMAGE}
KUBERNETES_VERSION=${KEEP_KUBERNETES_VERSION}

if [ ! -f ${TARGET_CLUSTER_LOCATION}/config ]; then
	cp ${HOME}/.kube/config ${TARGET_CLUSTER_LOCATION}/config
fi

    cat ${AWSDEFS} > ${TARGET_CONFIG_LOCATION}/buildenv

cat > ${TARGET_CONFIG_LOCATION}/buildenv <<EOF
export AUTOSCALE_MACHINE=${AUTOSCALE_MACHINE}
export AWS_ROUTE53_PUBLIC_ZONE_ID=${AWS_ROUTE53_PUBLIC_ZONE_ID}
export CERT_DOMAIN=${CERT_DOMAIN}
export CLOUD_PROVIDER=${CLOUD_PROVIDER}
export CNI_PLUGIN_VERSION=${CNI_PLUGIN_VERSION}
export CNI_PLUGIN=${CNI_PLUGIN}
export CONTROL_PLANE_MACHINE=${CONTROL_PLANE_MACHINE}
export CONTROLNODES=${CONTROLNODES}
export CONTROLPLANE_USE_PUBLICIP=${CONTROLPLANE_USE_PUBLICIP}
export CORESTOTAL="${CORESTOTAL}"
export DASHBOARD_HOSTNAME=${DASHBOARD_HOSTNAME}
export DOMAIN_NAME=${DOMAIN_NAME}
export EXPOSE_PUBLIC_CLUSTER=${EXPOSE_PUBLIC_CLUSTER}
export EXTERNAL_ETCD=${EXTERNAL_ETCD}
export FIRSTNODE_INDEX=${FIRSTNODE_INDEX}
export GODADDY_API_KEY=${GODADDY_API_KEY}
export GODADDY_API_SECRET=${GODADDY_API_SECRET}
export GRPC_PROVIDER=${GRPC_PROVIDER}
export HA_CLUSTER=${HA_CLUSTER}
export KUBECONFIG=${KUBECONFIG}
export KUBERNETES_VERSION=${KUBERNETES_VERSION}
export MASTER_INSTANCE_PROFILE_ARN=${MASTER_INSTANCE_PROFILE_ARN}
export MASTER_PROFILE_NAME=${MASTER_PROFILE_NAME}
export MASTERKUBE=${MASTERKUBE}
export MAX_PODS=${MAX_PODS}
export MAXAUTOPROVISIONNEDNODEGROUPCOUNT=${MAXAUTOPROVISIONNEDNODEGROUPCOUNT}
export MAXNODES=${MAXNODES}
export MAXTOTALNODES=${MAXTOTALNODES}
export MEMORYTOTAL="${MEMORYTOTAL}"
export MINNODES=${MINNODES}
export NGINX_MACHINE=${NGINX_MACHINE}
export NODEGROUP_NAME=${NODEGROUP_NAME}
export OSDISTRO=${OSDISTRO}
export PREFER_SSH_PUBLICIP=${PREFER_SSH_PUBLICIP}
export PRIVATE_DOMAIN_NAME=${PRIVATE_DOMAIN_NAME}
export PUBLIC_DOMAIN_NAME=${PUBLIC_DOMAIN_NAME}
export REGISTRY=${REGISTRY}
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
export TARGET_CLUSTER_LOCATION=${TARGET_CLUSTER_LOCATION}
export TARGET_CONFIG_LOCATION=${TARGET_CONFIG_LOCATION}
export TARGET_DEPLOY_LOCATION=${TARGET_DEPLOY_LOCATION}
export TARGET_IMAGE=${TARGET_IMAGE}
export TRANSPORT=${TRANSPORT}
export UNREMOVABLENODERECHECKTIMEOUT=${UNREMOVABLENODERECHECKTIMEOUT}
export USE_K3S=${USE_K3S}
export USE_NGINX_GATEWAY=${USE_NGINX_GATEWAY}
export USE_NLB=${USE_NLB}
export USE_ZEROSSL=${USE_ZEROSSL}
export VOLUME_SIZE=${VOLUME_SIZE}
export VOLUME_TYPE=${VOLUME_TYPE}
export WORKER_INSTANCE_PROFILE_ARN=${WORKER_INSTANCE_PROFILE_ARN}
export WORKER_NODE_MACHINE=${WORKER_NODE_MACHINE}
export WORKER_PROFILE_NAME=${WORKER_PROFILE_NAME}
export WORKERNODE_USE_PUBLICIP=${WORKERNODE_USE_PUBLICIP}
export WORKERNODES=${WORKERNODES}
export ZEROSSL_EAB_HMAC_SECRET=${ZEROSSL_EAB_HMAC_SECRET}
export ZEROSSL_EAB_KID=${ZEROSSL_EAB_KID}
EOF

AWS_AUTOSCALER_CONFIG=$(cat ${TARGET_CONFIG_LOCATION}/kubernetes-aws-autoscaler.json)

echo -n ${AWS_AUTOSCALER_CONFIG} | jq ".image = \"${TARGET_IMAGE}\" | .aws.\"${NODEGROUP_NAME}\".\"ami\" = \"${TARGET_IMAGE_AMI}\"" > ${TARGET_CONFIG_LOCATION}/kubernetes-aws-autoscaler.json

source ${PWD}/bin/create-deployment.sh

if [ "${KUBERNETES_VERSION}" == "$(kubectl version --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -o json | jq -r .serverVersion.gitVersion)" ]; then
	echo_blue_bold "Same kubernetes version, upgrade not necessary"
	exit
fi

if [ "$LAUNCH_CA" == YES ]; then
	kubectl delete po -l k8s-app=cluster-autoscaler -n kube-system --kubeconfig=${TARGET_CLUSTER_LOCATION}/config
fi

if [ ${USE_K3S} == true ]; then
	mkdir -p ${TARGET_DEPLOY_LOCATION}/system-upgrade

	IFS=+ read KUBEVERSION TAILK3S <<< "${KUBERNETES_VERSION}"

	kubectl delete ns system-upgrade --kubeconfig=${TARGET_CLUSTER_LOCATION}/config &>/dev/null || true

	sed -e "s/__KUBEVERSION__/${KUBEVERSION}/g" templates/system-upgrade/system-upgrade-controller.yaml \
		| tee ${TARGET_DEPLOY_LOCATION}/system-upgrade/system-upgrade-controller.yaml \
		| kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -

	kubectl wait --kubeconfig=${TARGET_CLUSTER_LOCATION}/config --namespace system-upgrade --for=condition=ready pod \
		--selector=upgrade.cattle.io/controller=system-upgrade-controller --timeout=240s

	sed -e "s/__KUBERNETES_VERSION__/${KUBERNETES_VERSION}/g" templates/system-upgrade/system-upgrade-plan.yaml \
		| tee ${TARGET_DEPLOY_LOCATION}/system-upgrade/system-upgrade-plan.yaml \
		| kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -

else
	IFS=. read VERSION MAJOR MINOR <<< "$KUBERNETES_VERSION"

	# Update tools
	echo_title "Update kubernetes binaries"
	ADDRESSES=$(kubectl get no --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -o json | jq -r '.items[].status.addresses[]|select(.type == "ExternalIP")|.address')
	for ADDR in ${ADDRESSES}
	do
		ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@${ADDR} <<EOF
			SEED_ARCH=\$([ "\$(uname -m)" == "aarch64" ] && echo -n arm64 || echo -n amd64)
			cd /usr/local/bin
			sudo curl -sL --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/\${SEED_ARCH}/{kubeadm,kubectl,kube-proxy}
			sudo chmod +x /usr/local/bin/kube*
EOF
	done

	# Upgrade control plane
	echo_title "Update control plane nodes"
	ADDRESSES=$(kubectl get no --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -o json | jq -r '.items[]|select(.metadata.labels.master == "true")|.status.addresses[]|select(.type == "ExternalIP")|.address')
	for ADDR in ${ADDRESSES}
	do
		echo_blue_bold "Update node: ${ADDR}"
		ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@${ADDR} <<EOF
			if [ ${MAJOR} -ge 27 ] && [ -f /etc/kubernetes/kubeadm-config.yaml ]; then
				sudo sed -i '/container-runtime:/d' /etc/kubernetes/kubeadm-config.yaml
			fi

			sudo kubeadm upgrade apply ${KUBERNETES_VERSION} --yes --certificate-renewal=false
EOF
	done

	# Upgrade worker
	echo_title "Update worker nodes"
	ADDRESSES=$(kubectl get no --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -o json | jq -r '.items[]|select(.metadata.labels.worker == "true")|.status.addresses[]|select(.type == "ExternalIP")|.address')
	for ADDR in ${ADDRESSES}
	do
		echo_blue_bold "Update node: ${ADDR}"
		ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@${ADDR} <<EOF
		sudo kubeadm upgrade node
EOF
	done

	# Upgrade kubelet
	echo_title "Update kubelet"
	NODES=$(kubectl get no --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -o json)
	COUNT=$(echo ${NODES} | jq '.items|length')

	for INDEX in $(seq 1 ${COUNT})
	do
		NODE=$(echo ${NODES} | jq ".items[$((INDEX-1))]")
		NODENAME=$(echo ${NODE} | jq -r .metadata.name)
		ADDR=$(echo ${NODE} | jq -r '.status.addresses[]|select(.type == "ExternalIP")|.address')

		echo_blue_bold "Update kubelet for node: ${NODENAME}"

		kubectl cordon ${NODENAME} --kubeconfig=${TARGET_CLUSTER_LOCATION}/config

		ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@${ADDR} <<EOF
			if [ ${MAJOR} -ge 27 ] && [ -f /var/lib/kubelet/kubeadm-flags.env ]; then
				sudo sed -i -E 's/--container-runtime=\w+//' /var/lib/kubelet/kubeadm-flags.env
			fi 

			SEED_ARCH=\$([ "\$(uname -m)" == "aarch64" ] && echo -n arm64 || echo -n amd64)
			sudo systemctl stop kubelet
			cd /usr/local/bin
			sudo curl -sL --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/\${SEED_ARCH}/kubelet
			sudo chmod +x /usr/local/bin/kubelet
			sudo systemctl start kubelet
EOF

		kubectl uncordon ${NODENAME} --kubeconfig=${TARGET_CLUSTER_LOCATION}/config

		echo_blue_bold "Kubelet upgraded for node: ${NODENAME}"
	done

fi

popd &>/dev/null
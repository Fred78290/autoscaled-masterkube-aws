#!/bin/bash
CURDIR=$(dirname $0)
KUBERNETES_MINOR_RELEASE=$(echo -n $KUBERNETES_VERSION | awk -F. '{ print $2 }')

source ${CURDIR}/common.sh

mkdir -p ${TARGET_DEPLOY_LOCATION}/rancher
pushd ${TARGET_DEPLOY_LOCATION} &>/dev/null

export K8NAMESPACE=cattle-system

kubectl create ns ${K8NAMESPACE} --dry-run=client --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -o yaml | kubectl apply -f -

if [ ${KUBERNETES_MINOR_RELEASE} -lt 26 ]; then
    REPO=rancher-latest/rancher

    helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
    helm repo update
else
    REPO=/tmp/rancher/

    curl -sL https://releases.rancher.com/server-charts/latest/rancher-2.7.2-rc1.tgz | tar zxvf - -C /tmp

    sed -i -e 's/1.26.0-0/1.27.9-0/' $REPO/Chart.yaml
fi

cat > ${TARGET_DEPLOY_LOCATION}/rancher/rancher.yaml <<EOF
hostname: rancher-aws.$DOMAIN_NAME
ingress:
    ingressClassName: nginx
    extraAnnotations:
        "cert-manager.io/cluster-issuer": cert-issuer-prod
        "external-dns.alpha.kubernetes.io/register": 'true'
        "external-dns.alpha.kubernetes.io/target": "$MASTERKUBE.$DOMAIN_NAME"
        "external-dns.alpha.kubernetes.io/hostname": "rancher-aws.$DOMAIN_NAME"
        "external-dns.alpha.kubernetes.io/ttl": '600'
    tls:
        source: secret
        secretName: tls-rancher-ingress
tls: ingress
replicas: 1
global:
  cattle:
    psp:
      enabled: false
EOF

helm upgrade -i rancher "${REPO}" \
    --kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
    --namespace ${K8NAMESPACE} \
    --values ${TARGET_DEPLOY_LOCATION}/rancher/rancher.yaml

echo_blue_dot_title "Wait Rancher bootstrap"

COUNT=0

while [ -z ${BOOTSTRAP_SECRET} ] && [ $COUNT -lt 120 ];
do
    BOOTSTRAP_SECRET=$(kubectl get secret --namespace ${K8NAMESPACE} bootstrap-secret -o go-template='{{.data.bootstrapPassword|base64decode}}' --kubeconfig=${TARGET_CLUSTER_LOCATION}/config 2>/dev/null)
    sleep 1
    echo_blue_dot
	COUNT=$((COUNT+1))
done

echo

echo_title "Rancher setup URL"
echo_blue_bold "https://rancher-aws.$DOMAIN_NAME/dashboard/?setup=${BOOTSTRAP_SECRET}"
echo_line
echo

popd &>/dev/null
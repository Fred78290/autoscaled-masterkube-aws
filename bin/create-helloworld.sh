#!/bin/bash
CURDIR=$(dirname $0)

pushd $CURDIR/../

export K8NAMESPACE=kube-public
export ETC_DIR=${TARGET_DEPLOY_LOCATION}/helloworld
export KUBERNETES_TEMPLATE=./templates/helloworld

if [ -z "$DOMAIN_NAME" ]; then
    export DOMAIN_NAME=$(openssl x509 -noout -fingerprint -text < ${SSL_LOCATION}/cert.pem | grep 'Subject: CN =' | awk '{print $4}' | sed 's/\*\.//g')
echo "domain:$DOMAIN_NAME"
fi

mkdir -p $ETC_DIR

if [ -z "${PUBLIC_DOMAIN_NAME}" ]; then
    kubectl create secret tls helloworld-tls -n $K8NAMESPACE \
        --key ${SSL_LOCATION}/privkey.pem \
        --cert ${SSL_LOCATION}/fullchain.pem \
        --kubeconfig=${TARGET_CLUSTER_LOCATION}/config
fi

function deploy {
    echo "Create $ETC_DIR/$1.json"
echo $(eval "cat <<EOF
$(<$KUBERNETES_TEMPLATE/$1.json)
EOF") | jq . > $ETC_DIR/$1.json

kubectl apply -f $ETC_DIR/$1.json --kubeconfig=${TARGET_CLUSTER_LOCATION}/config
}

deploy deployment
deploy service
deploy ingress

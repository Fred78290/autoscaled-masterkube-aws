#!/bin/bash
function deploy {
    echo "Create $ETC_DIR/$1.json"

    CONFIG=$(eval "cat <<EOF
$(<$KUBERNETES_TEMPLATE/$1.json)
EOF")

    if [ "${USE_ZEROSSL}" = "YES" ]; then
        echo $CONFIG | jq \
            --arg SERVER "https://acme.zerossl.com/v2/DV90" \
            --arg ZEROSSL_EAB_KID $ZEROSSL_EAB_KID \
            '.spec.acme.server = $SERVER | .spec.acme.externalAccountBinding = {"keyID": $ZEROSSL_EAB_KID, "keyAlgorithm": "HS256", "keySecretRef": { "name": "zero-sll-eabsecret", "key": "secret"}}' > $ETC_DIR/$1.json
    else
        echo $CONFIG | jq \
            --arg SERVER "https://acme-v02.api.letsencrypt.org/directory" \
            --arg CERT_EMAIL ${CERT_EMAIL} \
            '.spec.acme.server = $SERVER | .spec.acme.email = $CERT_EMAIL' > $ETC_DIR/$1.json
    fi

    kubectl apply -f $ETC_DIR/$1.json --kubeconfig=${TARGET_CLUSTER_LOCATION}/config
}

if [ -z "${PUBLIC_DOMAIN_NAME}" ]; then
    echo "Don't install cert-manager, no public domain defined"
else
    echo "Install cert-manager"

    export K8NAMESPACE=cert-manager
    export ETC_DIR=${TARGET_DEPLOY_LOCATION}/cert-manager
    export KUBERNETES_TEMPLATE=./templates/cert-manager

    KUBERNETES_MINOR_RELEASE=$(echo -n $KUBERNETES_VERSION | tr '.' ' ' | awk '{ print $2 }')

    case $KUBERNETES_MINOR_RELEASE in
        24)
            CERT_MANAGER_VERSION=v1.8.0
            GODADDY_WEBHOOK_VERSION=v1.24.6
            ;;
        25)
            CERT_MANAGER_VERSION=v1.9.1
            GODADDY_WEBHOOK_VERSION=v1.25.5
            ;;
        26)
            CERT_MANAGER_VERSION=v1.10.1
            GODADDY_WEBHOOK_VERSION=v1.26.0
            ;;
    esac

    mkdir -p $ETC_DIR

    kubectl --kubeconfig=${TARGET_CLUSTER_LOCATION}/config create namespace $K8NAMESPACE

    helm repo add jetstack https://charts.jetstack.io
    helm repo add godaddy-webhook https://fred78290.github.io/cert-manager-webhook-godaddy/
    helm repo update

    helm upgrade -i $K8NAMESPACE jetstack/cert-manager \
            --kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
            --namespace $K8NAMESPACE \
            --version ${CERT_MANAGER_VERSION} \
            --set installCRDs=true

    if [ "${USE_ZEROSSL}" = "YES" ]; then
        kubectl -n $K8NAMESPACE create secret generic zero-sll-eabsecret — from-literal secret="${ZEROSSL_EAB_HMAC_SECRET}"
    fi

    if [ ! -z "${AWS_ROUTE53_PUBLIC_ZONE_ID}" ]; then
        echo "Register route53 resolver"
        kubectl create secret generic route53-credentials-secret --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -n $K8NAMESPACE --from-literal=secret=${AWS_ROUTE53_SECRETKEY}

        deploy cluster-issuer-route53
    elif [ ! -z ${GODADDY_API_KEY} ]; then

        echo "Register godaddy resolver"
        helm upgrade -i godaddy-webhook godaddy-webhook/godaddy-webhook \
            --version ${GODADDY_WEBHOOK_VERSION} \
            --set groupName=${PUBLIC_DOMAIN_NAME} \
            --set dnsPolicy=ClusterFirst \
            --namespace cert-manager

        kubectl create secret generic godaddy-api-key-prod --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -n cert-manager --from-literal=key=${GODADDY_API_KEY} --from-literal=secret=${GODADDY_API_SECRET}
        deploy cluster-issuer-godaddy
    fi
fi
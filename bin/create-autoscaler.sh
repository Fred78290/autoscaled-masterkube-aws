#/bin/bash
LAUNCH_CA=$1

CURDIR=$(dirname $0)

pushd $CURDIR/../

MASTER_IP=$(cat ${TARGET_CLUSTER_LOCATION}/manager-ip)
TOKEN=$(cat ${TARGET_CLUSTER_LOCATION}/token)
CACERT=$(cat ${TARGET_CLUSTER_LOCATION}/ca.cert)

export K8NAMESPACE=kube-system
export ETC_DIR=${TARGET_DEPLOY_LOCATION}/autoscaler
export KUBERNETES_TEMPLATE=./templates/autoscaler
export KUBERNETES_MINOR_RELEASE=$(echo -n $KUBERNETES_VERSION | tr '.' ' ' | awk '{ print $2 }')
export CLUSTER_AUTOSCALER_VERSION=v1.22.1
export AWS_AUTOSCALER_VERSION=v1.22.7

case $KUBERNETES_MINOR_RELEASE in
    24)
        CLUSTER_AUTOSCALER_VERSION=v1.24.7
        AWS_AUTOSCALER_VERSION=v1.24.5
        ;;
    25)
        CLUSTER_AUTOSCALER_VERSION=v1.25.5
        AWS_AUTOSCALER_VERSION=v1.25.2
        ;;
    26)
        CLUSTER_AUTOSCALER_VERSION=v1.26.0
        AWS_AUTOSCALER_VERSION=v1.26.0
        ;;
esac

mkdir -p $ETC_DIR

function deploy {
    echo "Create $ETC_DIR/$1.json"
echo $(eval "cat <<EOF
$(<$KUBERNETES_TEMPLATE/$1.json)
EOF") | jq . > $ETC_DIR/$1.json

kubectl apply -f $ETC_DIR/$1.json --kubeconfig=${TARGET_CLUSTER_LOCATION}/config
}

deploy service-account-autoscaler
deploy service-account-aws
deploy cluster-role
deploy role
deploy cluster-role-binding
deploy role-binding

if [ "$LAUNCH_CA" == YES ]; then
    deploy deployment
elif [ "$LAUNCH_CA" == "DEBUG" ]; then
    deploy autoscaler
elif [ "$LAUNCH_CA" == "LOCAL" ]; then
    GOOS=$(go env GOOS)
    GOARCH=$(go env GOARCH)
    nohup ../out/$GOOS/$GOARCH/aws-autoscaler \
        --kubeconfig=$KUBECONFIG \
        --config=${TARGET_CONFIG_LOCATION}/kubernetes-vmware-autoscaler.json \
        --save=${TARGET_CONFIG_LOCATION}/vmware-autoscaler-state.json \
        --log-level=info 1>>${TARGET_CONFIG_LOCATION}/vmware-autoscaler.log 2>&1 &
    pid="$!"

    echo -n "$pid" > ${TARGET_CONFIG_LOCATION}/aws-autoscaler.pid

    deploy autoscaler
else
    deploy deployment
fi

popd

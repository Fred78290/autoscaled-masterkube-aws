#/bin/bash
LAUNCH_CA=$1

CURDIR=$(dirname $0)

pushd $CURDIR/../ &>/dev/null

MASTER_IP=$(cat ${TARGET_CLUSTER_LOCATION}/manager-ip)
TOKEN=$(cat ${TARGET_CLUSTER_LOCATION}/token)
CACERT=$(cat ${TARGET_CLUSTER_LOCATION}/ca.cert)

export K8NAMESPACE=kube-system
export ETC_DIR=${TARGET_DEPLOY_LOCATION}/autoscaler
export KUBERNETES_TEMPLATE=./templates/autoscaler
export KUBERNETES_MINOR_RELEASE=$(echo -n $KUBERNETES_VERSION | cut -d . -f 2)
export CLUSTER_AUTOSCALER_VERSION=v1.22.1
export AWS_AUTOSCALER_VERSION=v1.22.7
export AUTOSCALER_REGISTRY=$REGISTRY
export CLOUDPROVIDER_CONFIG=/etc/cluster/grpc-config.json
export USE_VANILLA_GRPC_ARGS=--no-use-vanilla-grpc
export USE_CONTROLER_MANAGER_ARGS="--use-controller-manager"

if [ "${GRPC_PROVIDER}" = "externalgrpc" ]; then
    USE_VANILLA_GRPC_ARGS=--use-vanilla-grpc
    AUTOSCALER_REGISTRY=registry.k8s.io/autoscaling
    CLOUDPROVIDER_CONFIG=/etc/cluster/grpc-config.yaml
fi

if [ -z "${CLOUD_PROVIDER}" ]; then
    USE_CONTROLER_MANAGER_ARGS="--no-use-controller-manager"
fi

case $KUBERNETES_MINOR_RELEASE in
    25)
        CLUSTER_AUTOSCALER_VERSION=v1.25.6
        AWS_AUTOSCALER_VERSION=v1.25.11
        ;;
    26)
        CLUSTER_AUTOSCALER_VERSION=v1.26.1
        AWS_AUTOSCALER_VERSION=v1.26.6
        ;;
    27)
        CLUSTER_AUTOSCALER_VERSION=v1.27.2
        AWS_AUTOSCALER_VERSION=v1.27.3
        ;;
    *)
        echo "Former version aren't supported by aws autoscaler"
        exit 1
esac

mkdir -p $ETC_DIR

function deploy {
    echo "Create $ETC_DIR/$1.json"
echo $(eval "cat <<EOF
$(<$KUBERNETES_TEMPLATE/$1.json)
EOF") | jq . | tee $ETC_DIR/$1.json | kubectl apply -f $ETC_DIR/$1.json --kubeconfig=${TARGET_CLUSTER_LOCATION}/config
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
        --config=${TARGET_CONFIG_LOCATION}/kubernetes-aws-autoscaler.json \
        --save=${TARGET_CONFIG_LOCATION}/aws-autoscaler-state.json \
        --log-level=info 1>>${TARGET_CONFIG_LOCATION}/aws-autoscaler.log 2>&1 &
    pid="$!"

    echo -n "$pid" > ${TARGET_CONFIG_LOCATION}/aws-autoscaler.pid

    deploy autoscaler
else
    deploy deployment
fi

popd &>/dev/null

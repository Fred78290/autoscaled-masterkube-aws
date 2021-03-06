#/bin/bash
LAUNCH_CA=$1

CURDIR=$(dirname $0)

pushd $CURDIR/../

MASTER_IP=$(cat ./cluster/${NODEGROUP_NAME}/manager-ip)
TOKEN=$(cat ./cluster/${NODEGROUP_NAME}/token)
CACERT=$(cat ./cluster/${NODEGROUP_NAME}/ca.cert)

export K8NAMESPACE=kube-system
export ETC_DIR=./config/${NODEGROUP_NAME}/deployment/autoscaler
export KUBERNETES_TEMPLATE=./templates/autoscaler
export KUBERNETES_MINOR_RELEASE=$(echo -n $KUBERNETES_VERSION | tr '.' ' ' | awk '{ print $2 }')
export CLUSTER_AUTOSCALER_VERSION=v1.22.1
export AWS_AUTOSCALER_VERSION=v1.22.7

case $KUBERNETES_MINOR_RELEASE in
    20)
        CLUSTER_AUTOSCALER_VERSION=v1.20.5
        AWS_AUTOSCALER_VERSION=v1.20.15
        ;;
    21)
        CLUSTER_AUTOSCALER_VERSION=v1.21.8
        AWS_AUTOSCALER_VERSION=v1.21.10
        ;;
    22)
        CLUSTER_AUTOSCALER_VERSION=v1.22.5
        AWS_AUTOSCALER_VERSION=v1.22.7
        ;;
    23)
        CLUSTER_AUTOSCALER_VERSION=v1.23.1
        AWS_AUTOSCALER_VERSION=v1.23.4
        ;;
esac

mkdir -p $ETC_DIR

function deploy {
    echo "Create $ETC_DIR/$1.json"
echo $(eval "cat <<EOF
$(<$KUBERNETES_TEMPLATE/$1.json)
EOF") | jq . > $ETC_DIR/$1.json

kubectl apply -f $ETC_DIR/$1.json --kubeconfig=./cluster/${NODEGROUP_NAME}/config
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
        --config=$PWD/config/kubernetes-aws-autoscaler.json \
        --save=$PWD/config/aws-autoscaler-state.json \
        --log-level=info 1>>config/aws-autoscaler.log 2>&1 &
    pid="$!"

    echo -n "$pid" > config/aws-autoscaler.pid

    deploy autoscaler
else
    deploy deployment
fi

popd

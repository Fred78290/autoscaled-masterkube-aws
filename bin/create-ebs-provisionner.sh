#!/bin/bash
export ETC_DIR=${TARGET_DEPLOY_LOCATION}/aws-ebs-provisioner

mkdir -p ${ETC_DIR}

if [ $CLOUD_PROVIDER = "external" ]; then
  helm repo add aws-cloud-controller-manager https://kubernetes.github.io/cloud-provider-aws
  helm repo update aws-cloud-controller-manager

  KUBERNETES_MINOR_RELEASE=$(echo -n $KUBERNETES_VERSION | awk -F. '{ print $2 }')

  case $KUBERNETES_MINOR_RELEASE in
      24)
          AWS_CONTROLLER_VERSION=v1.24.2
          ;;
      25)
          AWS_CONTROLLER_VERSION=v1.25.0
          ;;
      26)
          AWS_CONTROLLER_VERSION=v1.26.0
          ;;
      27)
          AWS_CONTROLLER_VERSION=v1.27.1
          ;;
      28)
          AWS_CONTROLLER_VERSION=v1.28.1
          ;;
      29)
          AWS_CONTROLLER_VERSION=v1.28.1
          ;;
  esac


 if [ "${KUBERNETES_DISTRO}" == "k3s" ] || [ "${KUBERNETES_DISTRO}" == "rke2" ]; then
    cat >> ${ETC_DIR}/aws-cloud-controller.yaml <<EOF
args:
  - --v=2
  - --cloud-provider=aws
  - --configure-cloud-routes=false
image:
  tag: ${AWS_CONTROLLER_VERSION}
nodeSelector:
  node-role.kubernetes.io/control-plane: "true"
EOF
  else
    cat > ${ETC_DIR}/aws-cloud-controller.yaml <<EOF
args:
  - --v=2
  - --cloud-provider=aws
  - --configure-cloud-routes=false
image:
  tag: ${AWS_CONTROLLER_VERSION}
EOF
  fi

  helm upgrade aws-cloud-controller-manager aws-cloud-controller-manager/aws-cloud-controller-manager \
      --install \
      -f ${ETC_DIR}/aws-cloud-controller.yaml
fi

cat > ${ETC_DIR}/aws-ebs-csi.yaml <<EOF
storageClasses:
 - name: aws-ebs
   annotations:
     storageclass.kubernetes.io/is-default-class: "false"
   volumeBindingMode: WaitForFirstConsumer
   reclaimPolicy: Delete
   parameters:
     encrypted: "false"
   parameters:
     encrypted: "false"
EOF

helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update
helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
    --kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
    --namespace kube-system \
    -f ${ETC_DIR}/aws-ebs-csi.yaml 
    
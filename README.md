# Introduction

This directory contains everthing to create an single plane or HA autoscaling kubernetes cluster on AWS cloud profiver. The build process use **kubeadm**.

The cluster will use my autoscaling tools from projects [kubernetes-aws-autoscaler](https://github.com/Fred78290/kubernetes-aws-autoscaler) and [custom autoscaler](https://github.com/Fred78290/autoscaler)

If you allow the cluster to be visible on internet, the process will use GODADDY to register public FCQN if you provide GODADDY key.

## Prerequistes

Ensure that you have sudo right

You must also install

|Linux|MacOS|
| --- | --- |
|kubectl|kubectl|
|aws cli|aws cli|
|jq|jq|
||gnu-getopt|
||gsed|

## Create the masterkube

First step is to fill a file named **aws.defs** in the bin directory with the values needed

```
# AWS account identity
export AWS_PROFILE=
export AWS_PROFILE_ROUTE53=
export AWS_REGION=
export AWS_ACCESSKEY=
export AWS_SECRETKEY=
export AWS_TOKEN=

# EC2 IAM Profile, will be created with essential rights if not defined
export MASTER_INSTANCE_PROFILE_ARN=
export WORKER_INSTANCE_PROFILE_ARN=

export CLOUD_PROVIDER=aws
export AWS_ROUTE53_ZONE_ID=
export VPC_PUBLIC_SUBNET_ID=
export VPC_PUBLIC_SECURITY_GROUPID=
export VPC_PRIVATE_SUBNET_ID=
export VPC_PRIVATE_SECURITY_GROUPID=

# GODADDY account
export GODADDY_API_KEY=
export GODADDY_API_SECRET=
```

The simply way to create the masterkube is to run [create-masterkube.sh](create-masterkube.sh)

Some needed file are located in:

| Name | Description |
| --- | --- |
| `bin` | Essentials scripts to build the master kubernetes node  |
| `etc/ssl`  | Your CERT for https. Autosigned will be generated if empty  |
| `template`  | Templates files to deploy pod & service |

The first thing done by this script is to create a VM Template Ubuntu-20.04.3 image with kubernetes preinstalled with a container runtime.

The VM template will be named by convention focal-k8s-cni-(aws|flannel|calico|...)-(kubernetes version))-(amd64|arm64)-(docker|containerd|cri-o))

Next step will be to launch a cloned VM and create a master node. It will also deploy a dashboard at the URL https://masterkube-aws-dashboard.@your-domain@/

To connect to the dashboard, copy paste the token from file [cluster/aws-ca-k8s/dashboard-token](./cluster/aws-ca-k8s/dashboard-token)

Next step is to deploy a replicaset helloworld. This replicaset use hostnetwork:true to enforce one pod per node.

During the process the script will create many files located in

| Name | Description |
| --- | --- |
| `cluster` | Essentials file to connect to kubernetes with kubeadm join  |
| `config`  | Configuration file generated during the build process  |

## Command line arguments

| Parameter | Description | Default |
| --- | --- |--- |
| `-h\|--help` | Help  | |
| `-v\|--verbose` | Verbose mode  | |
| `-x\|--trace` | Trace execution  | |
| `-r\|--resume` | Allow to resume interrupted creation of cluster kubernetes  | |
| `--create-image-only`| Create image only and exit ||
| **Flags to set AWS informations** |
| `-p\|--profile` | AWS Profile to use | $AWS_PROFILE env vars |
| `--route53-profile` | Specify AWS profile for route53 | $AWS_PROFILE_ROUTE53 env vars |
| `-r\|--region` | AWS Region to deploy  | $AWS_REGION env vars |
| **Flag to design the kubernetes cluster** |
| `-c\|--ha-cluster` | Allow to create an HA cluster with 3 control planes | NO |
| `--worker-nodes` | Specify the number of worker node created in the cluster. | 3 |
| `--container-runtime` | Specify which OCI runtime to use. [**docker**\|**containerd**\|**cri-o**]| containerd |
| `--internet-facing\|--no-internet-facing` | Specify if the cluster is exposed on internet port: 80 443 | public |
| `--max-pods` | Specify the max pods per created VM. | AWS set it for aws plugin else 110 |
| **Flags in single master node only** |
| `--control-plane-public\|-no-control-plane-public` | Specify if master is hosted in public subnet |
| `--worker-node-public\|--no-worker-node-public` | Specify if worker nodes asre hosted in public subnet |
| **Flags in ha mode only** |
| `-e\|--create-external-etcd` | Allow to create and use an external HA etcd cluster  | NO |
| `-u\|--use-nlb` | Allow to use AWS ELB as load balancer else NGINX is used in public vpc | NO |
| **Flags in both mode** |
| `--default-machine` | The instance type name to deploy kubernetes nodes | t3a.medium/t4g.medium |
| `--nginx-machine` | The instance type name to deploy front nginx node | t3a.small/t4g.small |
| `-k\|--ssh-private-key`  | Alternate ssh key file |~/.ssh/id_rsa|
| `-t\|--transport`  | Override the transport to be used between autoscaler and vmware-autoscaler [**tcp**\|**linux**] |linux|
| `--no-cloud-provider`  | Set cloud provider to none | AWS |
| `--node-group` | The name of kubernetes node group  | aws-ca-k8s |
| `--cni-plugin-version`  | CNI version |v1.0.1
| `--cni-plugin`  | Override CNI plugin [**aws**\|**calico**\|**flannel**\|**weave**\|**romana**]|aws|
| `--kubernetes-version` | Which version of kubernetes to use |latest|
| `--volume-type` | The root volume type | gp2 |
| `--volume-size` | The root volume size in Gb | 10 |
| **Flags to configure network in aws** |
| `--public-subnet-id` | Specify the list of public subnet ID for created VM, comma separated |
| `--public-sg-id`| Specify the public security group ID for VM|
| `--private-subnet-id` | Specify the list of private subnet ID for created VM, comma separated |
| `--private-sg-id` | Specify the private security group ID for VM |
| **Flags to set the template vm** |
| `--target-image` | The AMI used for EC2 instances, only if you create your own image |
| `--seed-image` | The AMI used to create the target image, region dependant |
| `--seed-user` | The cloud-init user name | ubuntu |
| `-a\|--arch`| Specify the architecture of VM (amd64\|arm64) | amd64 |
| **Flags for autoscaler** |
| `--max-nodes-total` | Maximum number of nodes in all node groups. Cluster autoscaler will not grow the cluster beyond this number. | 5 |
| `--cores-total` | Minimum and maximum number of cores in cluster, in the format < min >:< max >. Cluster autoscaler will not scale the cluster beyond these numbers. | 0:16 |
| `--memory-total` | Minimum and maximum number of gigabytes of memory in cluster, in the format < min >:< max >. Cluster autoscaler will not scale the cluster beyond these numbers. | 0:24 |
| `--max-autoprovisioned-node-group-count` | The maximum number of autoprovisioned groups in the cluster | 1 |
| `--scale-down-enabled` | Should CA scale down the cluster | true |
| `--scale-down-delay-after-add` | How long after scale up that scale down evaluation resumes | 1 minutes |
| `--scale-down-delay-after-delete` | How long after node deletion that scale down evaluation resumes, defaults to scan-interval | 1 minutes |
| `--scale-down-delay-after-failure` | How long after scale down failure that scale down evaluation resumes | 1 minutes |
| `--scale-down-unneeded-time` | How long a node should be unneeded before it is eligible for scale down | 1 minutes |
| `--scale-down-unready-time` | How long an unready node should be unneeded before it is eligible for scale down | 1 minutes |
| `--unremovable-node-recheck-timeout` | The timeout before we check again a node that couldn't be removed before | 1 minutes |

```bash
create-masterkube \
    --ha-cluster \
    --verbose \
    --worker-nodes=3
    --use-nlb \
    --internet-facing \
    --profile=awsprofile \
    --region=us-east-1 \
    --nodegroup=aws-my-k8s \
    --seed-image=ami-085925f297f89fce1 \
    --seed-user=ubuntu \
    --public-subnet-id=subnet-123,subnet-456,subnet-789 \
    --public-sg-id=sg-1234 \
    --private-subnet-id=subnet-ABC,subnet-DEF,subnet-GHI \
    --private-sg-id=sg-5678 \
    --arch=arm64 \
    --cni-plugin=calico \
    --no-cloud-provider
```

## Machine type

If you want to use another machine type rather t3a or t4g class, you must edit definition files [amd64](./templates/machines/amd64.json) [arm64](./templates/machines/arm64.json)

## Raise autoscaling

To scale up or down the cluster, just play with `kubectl scale`

To scale fresh masterkube `kubectl scale --replicas=2 deploy/helloworld -n kube-public`

## Delete master kube and worker nodes

To delete the master kube and associated worker nodes, just run the command [delete-masterkube.sh](./bin/delete-masterkube.sh)
If the create process fail for any reason, you can use flag **--force**
#!/bin/bash

set -e

export DEBIAN_FRONTEND=noninteractive

CONTROL_PLANE_ENDPOINT=
MASTER_NODES=
NET_IP=0.0.0.0
APISERVER_ADVERTISE_PORT=6443

TEMP=$(getopt -o l:p:n: --long listen-ip:,master-nodes:,control-plane-endpoint: -n "$0" -- "$@")

eval set -- "${TEMP}"

# extract options and their arguments into variables.
while true; do
    case "$1" in
    -p | --control-plane-endpoint)
        CONTROL_PLANE_ENDPOINT="$2"
        shift 2
        ;;
    -n | --master-nodes)
        MASTER_NODES="$2"
        shift 2
        ;;
    -l | --listen-ip)
        NET_IP="$2"
        shift 2
        ;;
    --)
        shift
        break
        ;;

    *)
        echo "$1 - Internal error!"
        exit 1
        ;;
    esac
done

echo "127.0.0.1 ${CONTROL_PLANE_ENDPOINT}" >> /etc/hosts

apt update
apt dist-upgrade -y
apt install nginx -y || echo "Need to reconfigure NGINX"

# Remove http default listening
rm -rf /etc/nginx/sites-enabled/*

if [ -z "$(grep tcpconf /etc/nginx/nginx.conf)" ]; then
    echo "include /etc/nginx/tcpconf.conf;" >> /etc/nginx/nginx.conf
fi

cat > /etc/nginx/tcpconf.conf <<EOF
stream {
    include /etc/nginx/tcpconf.d/*.conf;
}
EOF

# Buod stream TCP
IFS=, read -a MASTER_NODES <<< "$MASTER_NODES"

mkdir -p /etc/nginx/tcpconf.d

function create_tcp_stream() {
    local STREAM_NAME=$1
    local TCP_PORT=$2
    local NGINX_CONF=$3

    cat > $NGINX_CONF <<EOF
    upstream $STREAM_NAME {
        least_conn;
EOF

    for CLUSTER_NODE in ${MASTER_NODES[*]}
    do
        IFS=: read HOST IP <<< "$CLUSTER_NODE"

        if [ "x${HOST}" != "x" ]; then
            echo "        server ${IP}:${TCP_PORT} max_fails=3 fail_timeout=30s;" >> $NGINX_CONF
        fi
    done

    cat >> $NGINX_CONF <<EOF
    }

    server {
        listen $NET_IP:${TCP_PORT};

        proxy_pass $STREAM_NAME;
    }
EOF
}

create_tcp_stream kubernetes_apiserver_lb ${APISERVER_ADVERTISE_PORT} /etc/nginx/tcpconf.d/apiserver.conf
create_tcp_stream https_lb 443 /etc/nginx/tcpconf.d/https.conf
create_tcp_stream http_lb 80 /etc/nginx/tcpconf.d/http.conf

apt install --fix-broken

systemctl restart nginx

if [ -f /etc/systemd/system/kubelet.service ]; then
    systemctl disable kubelet
fi
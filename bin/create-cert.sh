#!/bin/bash
CURDIR=$(dirname $0)

source ${CURDIR}/common.sh

function usage() {
cat <<EOF
$0 create an autosigned certificat with own CA
Options are:
--help | -h                            # Display usage
--ssl-location | -l                    # Where to store cert
--cert-email | -m                      # Email used in cert
--domain | -d                          # Domain used for cert
EOF
}

TEMP=$(getopt -o hl:d:m: --long help,ssl-location:,domain:,cert-email: -n "$0" -- "$@")

eval set -- "${TEMP}"

while true; do
    case "$1" in
    -h|--help)
        usage
        exit
        shift 1
        ;;
    -l|--ssl-location)
        SSL_LOCATION=$2
        shift 2
        ;;
    -m|--cert-email)
        CERT_EMAIL=$2
        shift 2
        ;;
    -d|--domain)
        ACM_DOMAIN_NAME=$2
        shift 2
        ;;
    --)
        shift
        break
        ;;
    *)
        echo_red "$1 - Internal error!"
        usage
        exit 1
        ;;
    esac
done

if [ -z "${SSL_LOCATION}" ]; then
    echo_red_bold "SSL_LOCATION is not defined, exit"
    exit 1
fi

if [ -z "${ACM_DOMAIN_NAME}" ]; then
    echo_red_bold "ACM_DOMAIN_NAME is not defined, exit"
    exit 1
fi

if [ -z "${CERT_EMAIL}" ]; then
    echo_red_bold "CERT_EMAIL is not defined, exit"
    exit 1
fi

mkdir -p ${SSL_LOCATION}/

WILDCARD="*.${ACM_DOMAIN_NAME}"

pushd ${SSL_LOCATION}

cat > csr.conf <<EOF
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[ dn ]
C = US
ST = California
L = San Francisco
O = GitHub
OU = Fred78290
CN = ${WILDCARD}
emailAddress = ${CERT_EMAIL}

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${ACM_DOMAIN_NAME}
EOF

cat > csr.conf <<EOF
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[ dn ]
CN = ${WILDCARD}

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${ACM_DOMAIN_NAME}
EOF

# Generate a self signed CA
openssl req -x509 -sha256 -days 3650 -nodes -newkey rsa:2048 \
    -subj "/C=US/ST=California/L=San Francisco/O=GitHub/OU=Fred78290/CN=${ACM_DOMAIN_NAME}/emailAddress=${CERT_EMAIL}" \
    -keyout ca.key \
    -out ca.pem

openssl genrsa -out privkey.pem 2048
openssl req -new -key privkey.pem -out server.csr -config csr.conf

cat > cert.conf <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${WILDCARD}
DNS.2 = ${ACM_DOMAIN_NAME}
EOF

openssl x509 -req -in server.csr \
    -CA ca.pem \
    -CAkey ca.key \
    -CAcreateserial \
    -out cert.pem \
    -days 3650 \
    -sha256 \
    -extfile cert.conf

cat cert.pem ca.pem > chain.pem
cat cert.pem ca.pem privkey.pem > fullchain.pem
chmod 644 *

popd
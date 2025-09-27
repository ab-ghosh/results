set -e

export KO_DOCKER_REPO=${KO_DOCKER_REPO:-"kind.local"}
export KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME:-"tekton-results"}
export SA_TOKEN_PATH=${SA_TOKEN_PATH:-"/tmp/tekton-results/tokens"}
export SSL_CERT_PATH=${SSL_CERT_PATH:="/tmp/tekton-results/ssl"}
echo "Generating TLS key pair..."
set +e
mkdir -p "${SSL_CERT_PATH}"

SSL_INCLUDE_LOCALHOST=${SSL_INCLUDE_LOCALHOST:-"false"}
altNames="DNS:tekton-results-api-service.tekton-pipelines.svc.cluster.local"
if [ "$SSL_INCLUDE_LOCALHOST" = "true" ] ; then
    altNames+=",DNS:localhost"
fi

openssl req -x509 \
        -newkey rsa:4096 \
        -keyout "${SSL_CERT_PATH}/tekton-results-key.pem" \
        -out "${SSL_CERT_PATH}/tekton-results-cert.pem" \
        -days 365 \
        -nodes \
        -subj "/CN=tekton-results-api-service.tekton-pipelines.svc.cluster.local" \
        -addext "subjectAltName = ${altNames}"

if [ $? -ne 0 ] ; then
    # LibreSSL didn't support the -addext flag until version 3.1.0 but
    # version 2.8.3 ships with MacOS Big Sur. So let's try a different way...
    echo "Falling back to legacy libressl cert generation"
    openssl req -x509 \
            -verbose \
            -config <(cat /etc/ssl/openssl.cnf <(printf "[SAN]\nsubjectAltName = %s" ${altNames})) \
            -extensions SAN \
            -newkey rsa:4096 \
            -keyout "${SSL_CERT_PATH}/tekton-results-key.pem" \
            -out "${SSL_CERT_PATH}/tekton-results-cert.pem" \
            -days 365 \
            -nodes \
            -subj "/CN=tekton-results-api-service.tekton-pipelines.svc.cluster.local"

    if [ $? -ne 0 ] ; then
        echo "There was an error generating certificates"
        exit 1
    fi
fi
set -e
kubectl create secret tls -n tekton-pipelines tekton-results-tls --cert="${SSL_CERT_PATH}/tekton-results-cert.pem" --key="${SSL_CERT_PATH}/tekton-results-key.pem" || true

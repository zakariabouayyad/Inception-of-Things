#!/bin/sh
set -e
SERVER_IP="$1"

apk update --quiet
apk add --quiet --no-progress curl net-tools

IFACE=$(ip -o -4 addr show | grep "${SERVER_IP}" | awk '{print $2}')
if [ -z "$IFACE" ]; then
    echo "no interface found for ${SERVER_IP}"
    exit 1
fi

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server" sh -s - \
    --write-kubeconfig-mode 644 \
    --node-ip "${SERVER_IP}" \
    --flannel-iface "${IFACE}"

TIMEOUT=120
ELAPSED=0
while ! kubectl get nodes > /dev/null 2>&1; do
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo "timeout waiting for k3s"
        exit 1
    fi
done

mkdir -p /root/.kube
cp /etc/rancher/k3s/k3s.yaml /root/.kube/config

# wait for coredns / traefik before deploying
ELAPSED=0
TIMEOUT=300
while true; do
    TOTAL=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | wc -l)
    READY=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -c "Running" || true)
    echo "kube-system: ${READY}/${TOTAL} running"

    if [ "$TOTAL" -gt 0 ] && [ "$READY" -eq "$TOTAL" ]; then
        break
    fi

    sleep 10
    ELAPSED=$((ELAPSED + 10))
    if [ $ELAPSED -ge $TIMEOUT ]; then
        kubectl get pods -n kube-system
        break
    fi
done

kubectl apply -f /vagrant/confs/

kubectl wait --for=condition=ready pod -l app=app-one --timeout=120s 2>/dev/null || true
kubectl wait --for=condition=ready pod -l app=app-two --timeout=120s 2>/dev/null || true
kubectl wait --for=condition=ready pod -l app=app-three --timeout=120s 2>/dev/null || true

kubectl get pods
kubectl get svc
kubectl get ingress

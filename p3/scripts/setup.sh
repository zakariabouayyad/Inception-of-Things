#!/bin/bash
set -e

CLUSTER_NAME="iot"
ARGOCD_NS="argocd"
DEV_NS="dev"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFS_DIR="$SCRIPT_DIR/../confs"
PID_FILE="/tmp/iot-port-forward.pids"

install_docker() {
    if command -v docker &> /dev/null; then
        echo "docker already installed"
        return
    fi

    sudo apt-get update -y
    sudo apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        apt-transport-https \
        software-properties-common

    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -y
    sudo apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-compose-plugin

    sudo usermod -aG docker "$USER"
}

install_kubectl() {
    if command -v kubectl &> /dev/null; then
        echo "kubectl already installed"
        return
    fi

    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl
}

install_k3d() {
    if command -v k3d &> /dev/null; then
        echo "k3d already installed"
        return
    fi

    curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
}

create_cluster() {
    if k3d cluster list 2>/dev/null | grep -q "$CLUSTER_NAME"; then
        k3d cluster delete "$CLUSTER_NAME"
    fi

    k3d cluster create "$CLUSTER_NAME" \
        --port "8888:8888@loadbalancer" \
        --port "8080:80@loadbalancer" \
        --wait

    kubectl wait --for=condition=Ready nodes --all --timeout=120s
    kubectl get nodes -o wide
}

create_namespaces() {
    kubectl create namespace "$ARGOCD_NS" --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace "$DEV_NS" --dry-run=client -o yaml | kubectl apply -f -
    kubectl get namespaces
}

install_argocd() {
    # --server-side: the argocd CRDs are too big for client-side apply
    kubectl apply -n "$ARGOCD_NS" \
        -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
        --server-side

    kubectl -n "$ARGOCD_NS" rollout status deployment/argocd-server --timeout=300s
    kubectl -n "$ARGOCD_NS" rollout status deployment/argocd-repo-server --timeout=300s
    kubectl get pods -n "$ARGOCD_NS"
}

configure_argocd_app() {
    if [ ! -f "$CONFS_DIR/argocd-app.yaml" ]; then
        echo "missing $CONFS_DIR/argocd-app.yaml"
        exit 1
    fi

    kubectl apply -f "$CONFS_DIR/argocd-app.yaml"
    sleep 15
    kubectl get applications -n "$ARGOCD_NS"
}

wait_for_app() {
    RETRIES=30
    COUNT=0
    while [ $COUNT -lt $RETRIES ]; do
        POD_COUNT=$(kubectl get pods -n "$DEV_NS" --no-headers 2>/dev/null | wc -l)
        if [ "$POD_COUNT" -gt 0 ]; then
            break
        fi
        COUNT=$((COUNT + 1))
        echo "waiting for pods in $DEV_NS ($COUNT/$RETRIES)"
        sleep 10
    done

    if [ "$POD_COUNT" -eq 0 ]; then
        echo "no pods in $DEV_NS yet, check: kubectl get applications -n argocd"
    else
        kubectl wait --for=condition=Ready pods --all -n "$DEV_NS" --timeout=120s
        kubectl get pods -n "$DEV_NS"
    fi
}

start_port_forwards() {
    if [ -f "$PID_FILE" ]; then
        while read -r pid; do
            kill "$pid" 2>/dev/null || true
        done < "$PID_FILE"
        rm -f "$PID_FILE"
    fi

    fuser -k 8443/tcp 2>/dev/null || true
    fuser -k 8888/tcp 2>/dev/null || true
    sleep 1

    kubectl port-forward svc/argocd-server -n "$ARGOCD_NS" 8443:443 > /dev/null 2>&1 &
    echo $! > "$PID_FILE"

    kubectl port-forward svc/playground-service -n "$DEV_NS" 8888:8888 > /dev/null 2>&1 &
    echo $! >> "$PID_FILE"

    sleep 3
}

print_access_info() {
    ARGOCD_PWD=$(kubectl -n "$ARGOCD_NS" get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" | base64 -d)

    echo
    echo "argocd: https://localhost:8443 (admin / $ARGOCD_PWD)"
    echo "app:    http://localhost:8888"
    echo "stop port-forwards: kill \$(cat $PID_FILE)"
    echo
    curl -s http://localhost:8888 || echo "app not responding yet"
    echo
}

install_docker
install_kubectl
install_k3d
create_cluster
create_namespaces
install_argocd
configure_argocd_app
wait_for_app
start_port_forwards
print_access_info

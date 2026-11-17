#!/bin/bash
set -e

CLUSTER_NAME="iot-bonus"
ARGOCD_NS="argocd"
DEV_NS="dev"
GITLAB_NS="gitlab"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFS_DIR="$SCRIPT_DIR/../confs"

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
    # delete every existing k3d cluster so the ports are free
    k3d cluster list 2>/dev/null | tail -n +2 | awk '{print $1}' | while read c; do
        k3d cluster delete "$c" 2>/dev/null || true
    done
    sleep 3

    # 8888 app, 8082 ingress, 8181 -> gitlab nodeport
    k3d cluster create "$CLUSTER_NAME" \
        --port "8888:8888@loadbalancer" \
        --port "8082:80@loadbalancer" \
        --port "8181:30080@server:0" \
        --wait

    kubectl wait --for=condition=Ready nodes --all --timeout=120s
    kubectl get nodes -o wide
}

create_namespaces() {
    # gitlab namespace comes from gitlab.yaml
    kubectl create namespace "$ARGOCD_NS" --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace "$DEV_NS"    --dry-run=client -o yaml | kubectl apply -f -
    kubectl get namespaces
}

deploy_gitlab() {
    if [ ! -f "$CONFS_DIR/gitlab.yaml" ]; then
        echo "missing $CONFS_DIR/gitlab.yaml"
        exit 1
    fi

    kubectl apply -f "$CONFS_DIR/gitlab.yaml"

    RETRIES=40
    COUNT=0
    while [ $COUNT -lt $RETRIES ]; do
        POD_COUNT=$(kubectl get pods -n "$GITLAB_NS" --no-headers 2>/dev/null | wc -l)
        if [ "$POD_COUNT" -gt 0 ]; then
            break
        fi
        COUNT=$((COUNT + 1))
        sleep 10
    done

    # gitlab takes a long time on first boot, a few restarts are expected
    echo "waiting for gitlab (logs: kubectl logs -n gitlab -l app=gitlab -f)"
    RETRIES=100
    COUNT=0
    while [ $COUNT -lt $RETRIES ]; do
        POD_STATUS=$(kubectl get pods -n "$GITLAB_NS" -l app=gitlab -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
        if [ "$POD_STATUS" = "true" ]; then
            break
        fi

        PHASE=$(kubectl get pods -n "$GITLAB_NS" -l app=gitlab -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
        RESTARTS=$(kubectl get pods -n "$GITLAB_NS" -l app=gitlab -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null)
        REASON=$(kubectl get pods -n "$GITLAB_NS" -l app=gitlab -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null)
        COUNT=$((COUNT + 1))
        echo "[$COUNT/$RETRIES] phase=$PHASE ready=$POD_STATUS restarts=$RESTARTS last=$REASON"

        if [ "${RESTARTS:-0}" -gt 15 ]; then
            echo "gitlab restarted $RESTARTS times, probably not enough ram"
            exit 1
        fi

        sleep 15
    done

    if [ "$POD_STATUS" != "true" ]; then
        echo "gitlab not ready, check: kubectl logs -n gitlab -l app=gitlab --tail=100"
        exit 1
    fi

    kubectl get pods -n "$GITLAB_NS"
}

install_argocd() {
    kubectl apply -n "$ARGOCD_NS" \
        -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side

    kubectl -n "$ARGOCD_NS" rollout status deployment/argocd-server --timeout=300s
    kubectl -n "$ARGOCD_NS" rollout status deployment/argocd-repo-server --timeout=300s
    kubectl get pods -n "$ARGOCD_NS"
}

init_gitlab_repo() {
    if [ ! -f "$SCRIPT_DIR/init-gitlab.sh" ]; then
        echo "missing $SCRIPT_DIR/init-gitlab.sh"
        exit 1
    fi

    bash "$SCRIPT_DIR/init-gitlab.sh"
}

configure_argocd_app() {
    if [ ! -f "$CONFS_DIR/argocd-app.yaml" ]; then
        echo "missing $CONFS_DIR/argocd-app.yaml"
        exit 1
    fi

    # local gitlab is plain http
    kubectl -n "$ARGOCD_NS" patch configmap argocd-cm --type merge \
        -p '{"data":{"repositories":"- url: http://gitlab-ce.gitlab.svc.cluster.local/root/iot-zakaria.git\n  insecure: \"true\"\n  type: git\n"}}'

    kubectl -n "$ARGOCD_NS" rollout restart deployment argocd-repo-server
    kubectl -n "$ARGOCD_NS" rollout status deployment/argocd-repo-server --timeout=120s

    kubectl apply -f "$CONFS_DIR/argocd-app.yaml"
    sleep 20
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

print_access_info() {
    ARGOCD_PWD=$(kubectl -n "$ARGOCD_NS" get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" | base64 -d)

    echo
    kubectl get ns argocd dev gitlab
    echo
    echo "gitlab: http://localhost:8181 (root / password42), repo root/iot-zakaria"
    echo "argocd: kubectl port-forward svc/argocd-server -n argocd 8443:443"
    echo "        https://localhost:8443 (admin / $ARGOCD_PWD)"
    echo "app:    kubectl port-forward svc/wil-playground -n dev 8888:8888"
    echo "        curl http://localhost:8888"
    echo "switch v1/v2: bash $SCRIPT_DIR/update-app.sh"
}

install_docker
install_kubectl
install_k3d
create_cluster
create_namespaces
deploy_gitlab
install_argocd
init_gitlab_repo
configure_argocd_app
wait_for_app
print_access_info

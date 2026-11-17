#!/bin/bash
set -e

SERVER_IP="$1"
WORKER_IP="$2"
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq curl net-tools > /dev/null 2>&1

TIMEOUT=120
ELAPSED=0
while [ ! -f /vagrant/confs/node-token ]; do
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    [ $ELAPSED -ge $TIMEOUT ] && echo "token not found" && exit 1
done
TOKEN=$(cat /vagrant/confs/node-token)

IFACE=$(ip -o -4 addr show | grep "${WORKER_IP}" | awk '{print $2}')
if [ -z "$IFACE" ]; then
    echo "no interface found for ${WORKER_IP}"
    exit 1
fi

# don't start the agent here, vagrant ssh hangs otherwise
curl -sfL https://get.k3s.io | \
    K3S_URL="https://${SERVER_IP}:6443" \
    K3S_TOKEN="${TOKEN}" \
    INSTALL_K3S_EXEC="agent" \
    INSTALL_K3S_SKIP_START=true \
    sh -s - \
    --node-ip "${WORKER_IP}" \
    --flannel-iface "${IFACE}"

nohup systemctl start k3s-agent > /dev/null 2>&1 &
sleep 2

echo "agent installed"

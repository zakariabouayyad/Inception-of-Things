#!/bin/bash
set -e

SERVER_IP="$1"
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq curl net-tools > /dev/null 2>&1

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
while [ ! -f /var/lib/rancher/k3s/server/node-token ]; do
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    [ $ELAPSED -ge $TIMEOUT ] && echo "timeout waiting for k3s" && exit 1
done

# the worker reads the token from the synced folder
mkdir -p /vagrant/confs
cp /var/lib/rancher/k3s/server/node-token /vagrant/confs/node-token
chmod 644 /vagrant/confs/node-token

mkdir -p /home/vagrant/.kube
cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

echo "server ready"

#!/bin/bash
set -e

GITLAB_NS="gitlab"
GITLAB_SVC="http://gitlab-ce.gitlab.svc.cluster.local"
PROJECT_NAME="iot-zakaria"
GITLAB_TOKEN="glpat-iot42bonustoken1"

GITLAB_POD=$(kubectl get pods -n "$GITLAB_NS" -l app=gitlab -o jsonpath='{.items[0].metadata.name}')

CURRENT=$(kubectl exec -n "$GITLAB_NS" "$GITLAB_POD" -- \
    curl -s \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "$GITLAB_SVC/api/v4/projects/root%2F$PROJECT_NAME/repository/files/dev%2Fdeployment.yaml/raw?ref=main" \
    2>/dev/null)

echo "$CURRENT"
echo

if echo "$CURRENT" | grep -q "playground:v1"; then
    OLD_VERSION="v1"
    NEW_VERSION="v2"
elif echo "$CURRENT" | grep -q "playground:v2"; then
    OLD_VERSION="v2"
    NEW_VERSION="v1"
else
    OLD_VERSION="v1"
    NEW_VERSION="v2"
fi

echo "playground:$OLD_VERSION -> playground:$NEW_VERSION"

NEW_CONTENT=$(echo "$CURRENT" | sed "s/playground:$OLD_VERSION/playground:$NEW_VERSION/g")
ENCODED_CONTENT=$(echo "$NEW_CONTENT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
PAYLOAD="{\"branch\":\"main\",\"content\":$ENCODED_CONTENT,\"commit_message\":\"Update app to $NEW_VERSION\"}"

TMPFILE=$(mktemp)
echo "$PAYLOAD" > "$TMPFILE"
kubectl cp "$TMPFILE" "$GITLAB_NS/$GITLAB_POD:/tmp/update.json"
rm -f "$TMPFILE"

RESPONSE=$(kubectl exec -n "$GITLAB_NS" "$GITLAB_POD" -- \
    curl -s -o /dev/null -w "%{http_code}" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -X PUT "$GITLAB_SVC/api/v4/projects/root%2F$PROJECT_NAME/repository/files/dev%2Fdeployment.yaml" \
    -d @/tmp/update.json \
    2>/dev/null)

if [ "$RESPONSE" = "200" ]; then
    echo "updated to $NEW_VERSION"
else
    echo "update failed: HTTP $RESPONSE"
fi

# argocd polls every ~3 min, to force a sync:
# kubectl -n argocd patch application wil-playground --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'

sleep 10
kubectl get applications -n argocd
kubectl get pods -n dev

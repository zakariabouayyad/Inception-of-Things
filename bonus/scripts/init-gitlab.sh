#!/bin/bash
set -e

GITLAB_NS="gitlab"
GITLAB_SVC="http://gitlab-ce.gitlab.svc.cluster.local"
PROJECT_NAME="iot-zakaria"
GITLAB_TOKEN="glpat-iot42bonustoken1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFS_DIR="$SCRIPT_DIR/../confs"

wait_for_gitlab_api() {
    RETRIES=60
    COUNT=0

    # curl from a throwaway pod since the service is cluster-internal
    while [ $COUNT -lt $RETRIES ]; do
        STATUS=$(kubectl run --rm -i --restart=Never --image=curlimages/curl \
            curl-test-$RANDOM -n "$GITLAB_NS" -- \
            -s -o /dev/null -w "%{http_code}" \
            "$GITLAB_SVC/-/readiness" 2>/dev/null || echo "000")

        if [ "$STATUS" = "200" ]; then
            return 0
        fi

        COUNT=$((COUNT + 1))
        echo "gitlab api not ready (HTTP $STATUS), $COUNT/$RETRIES"
        sleep 15
    done

    echo "gitlab api never came up"
    exit 1
}

create_access_token() {
    GITLAB_POD=$(kubectl get pods -n "$GITLAB_NS" -l app=gitlab -o jsonpath='{.items[0].metadata.name}')

    if [ -z "$GITLAB_POD" ]; then
        echo "gitlab pod not found"
        exit 1
    fi

    kubectl exec -n "$GITLAB_NS" "$GITLAB_POD" -- \
        gitlab-rails runner "
            user = User.find_by_username('root')
            PersonalAccessToken.where(user: user, name: 'iot-bonus-token').destroy_all
            token = user.personal_access_tokens.create!(
                name: 'iot-bonus-token',
                scopes: [:api, :read_repository, :write_repository],
                expires_at: 365.days.from_now
            )
            token.set_token('$GITLAB_TOKEN')
            token.save!
        " > /dev/null 2>&1
}

create_project() {
    GITLAB_POD=$(kubectl get pods -n "$GITLAB_NS" -l app=gitlab -o jsonpath='{.items[0].metadata.name}')

    RESPONSE=$(kubectl exec -n "$GITLAB_NS" "$GITLAB_POD" -- \
        curl -s -o /dev/null -w "%{http_code}" \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        -X POST "$GITLAB_SVC/api/v4/projects" \
        -d "name=$PROJECT_NAME&visibility=public&initialize_with_readme=true&default_branch=main" \
        2>/dev/null)

    if [ "$RESPONSE" = "201" ]; then
        echo "project $PROJECT_NAME created"
    elif [ "$RESPONSE" = "400" ]; then
        echo "project $PROJECT_NAME probably exists already"
    else
        echo "create project: HTTP $RESPONSE"
    fi
}

push_manifests() {
    GITLAB_POD=$(kubectl get pods -n "$GITLAB_NS" -l app=gitlab -o jsonpath='{.items[0].metadata.name}')

    # one commit with both files through the api, no git needed on the host
    COMMIT_PAYLOAD=$(cat <<EOF
{
    "branch": "main",
    "commit_message": "Add dev application manifests (v1)",
    "actions": [
        {
            "action": "create",
            "file_path": "dev/deployment.yaml",
            "content": $(cat "$CONFS_DIR/app-deployment.yaml" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
        },
        {
            "action": "create",
            "file_path": "dev/service.yaml",
            "content": $(cat "$CONFS_DIR/app-service.yaml" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
        }
    ]
}
EOF
)

    TMPFILE=$(mktemp)
    echo "$COMMIT_PAYLOAD" > "$TMPFILE"
    kubectl cp "$TMPFILE" "$GITLAB_NS/$GITLAB_POD:/tmp/commit.json"
    rm -f "$TMPFILE"

    RESPONSE=$(kubectl exec -n "$GITLAB_NS" "$GITLAB_POD" -- \
        curl -s -o /dev/null -w "%{http_code}" \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        -H "Content-Type: application/json" \
        -X POST "$GITLAB_SVC/api/v4/projects/root%2F$PROJECT_NAME/repository/commits" \
        -d @/tmp/commit.json \
        2>/dev/null)

    if [ "$RESPONSE" = "201" ]; then
        echo "manifests pushed"
    else
        echo "commit failed (HTTP $RESPONSE), pushing files one by one"
        push_manifests_individually
    fi
}

push_manifests_individually() {
    GITLAB_POD=$(kubectl get pods -n "$GITLAB_NS" -l app=gitlab -o jsonpath='{.items[0].metadata.name}')

    DEPLOY_CONTENT=$(cat "$CONFS_DIR/app-deployment.yaml" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
    kubectl exec -n "$GITLAB_NS" "$GITLAB_POD" -- \
        curl -s -X POST \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        -H "Content-Type: application/json" \
        "$GITLAB_SVC/api/v4/projects/root%2F$PROJECT_NAME/repository/files/dev%2Fdeployment.yaml" \
        -d "{\"branch\":\"main\",\"content\":$(echo $DEPLOY_CONTENT),\"commit_message\":\"Add deployment.yaml\"}" \
        > /dev/null 2>&1

    SVC_CONTENT=$(cat "$CONFS_DIR/app-service.yaml" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
    kubectl exec -n "$GITLAB_NS" "$GITLAB_POD" -- \
        curl -s -X POST \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        -H "Content-Type: application/json" \
        "$GITLAB_SVC/api/v4/projects/root%2F$PROJECT_NAME/repository/files/dev%2Fservice.yaml" \
        -d "{\"branch\":\"main\",\"content\":$(echo $SVC_CONTENT),\"commit_message\":\"Add service.yaml\"}" \
        > /dev/null 2>&1
}

verify_repo() {
    GITLAB_POD=$(kubectl get pods -n "$GITLAB_NS" -l app=gitlab -o jsonpath='{.items[0].metadata.name}')

    FILES=$(kubectl exec -n "$GITLAB_NS" "$GITLAB_POD" -- \
        curl -s \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "$GITLAB_SVC/api/v4/projects/root%2F$PROJECT_NAME/repository/tree?path=dev&ref=main" \
        2>/dev/null)

    echo "$FILES" | python3 -m json.tool 2>/dev/null || echo "$FILES"
}

wait_for_gitlab_api
create_access_token
create_project
sleep 5
push_manifests
verify_repo

echo "repo: $GITLAB_SVC/root/$PROJECT_NAME.git"

#!/bin/bash
# Test webhook trigger locally

set -e

REPO_NAME="${1:-uxie-chat-api}"
BRANCH="${2:-develop}"
NAMESPACE="uxie-cicd"

# Determine webhook URL
if [ -n "$WEBHOOK_URL" ]; then
    URL="$WEBHOOK_URL"
else
    # Try to get from route
    URL=$(oc get route webhook-github -n $NAMESPACE -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -z "$URL" ]; then
        echo "ERROR: Cannot determine webhook URL"
        echo "Either set WEBHOOK_URL environment variable or ensure route exists"
        exit 1
    fi
    URL="https://$URL"
fi

# Get webhook secret
SECRET=$(oc get secret github-webhook-secret -n $NAMESPACE -o jsonpath='{.data.secret}' 2>/dev/null | base64 -d || echo "uxie-webhook-secret-2025")

echo "=== Webhook Test ==="
echo "URL: $URL"
echo "Repository: $REPO_NAME"
echo "Branch: $BRANCH"
echo ""

# Build payload
PAYLOAD=$(cat << EOF
{
  "ref": "refs/heads/$BRANCH",
  "repository": {
    "name": "$REPO_NAME",
    "ssh_url": "git@github.com:Nousie-AI/$REPO_NAME.git"
  },
  "after": "$(date +%s | sha256sum | head -c 40)",
  "pusher": {
    "name": "test-user"
  },
  "head_commit": {
    "message": "Test webhook trigger"
  }
}
EOF
)

# Calculate signature
SIGNATURE=$(echo -n "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | cut -d' ' -f2)

echo "Sending webhook..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$URL" \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Event: push" \
    -H "X-Hub-Signature-256: sha256=$SIGNATURE" \
    -d "$PAYLOAD" \
    --insecure)

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

echo ""
echo "Response code: $HTTP_CODE"
echo "Response body: $BODY"
echo ""

if [ "$HTTP_CODE" == "202" ] || [ "$HTTP_CODE" == "201" ]; then
    echo "SUCCESS: Webhook accepted"
    echo ""
    echo "Check PipelineRun:"
    echo "  oc get pipelinerun -n $NAMESPACE | grep $REPO_NAME"
    echo "  tkn pipelinerun logs -f -n $NAMESPACE"
else
    echo "FAILED: Webhook not accepted"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check EventListener: oc get pods -l eventlistener=github-listener -n $NAMESPACE"
    echo "  2. Check logs: oc logs -l eventlistener=github-listener -n $NAMESPACE"
fi

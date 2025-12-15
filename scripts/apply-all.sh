#!/bin/bash
# Apply all UXIE CI/CD resources to OpenShift cluster

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="uxie-cicd"

echo "=== UXIE CI/CD Deployment ==="
echo "Namespace: $NAMESPACE"
echo ""

# Check if logged in
if ! oc whoami &>/dev/null; then
    echo "ERROR: Not logged in to OpenShift cluster"
    echo "Run: oc login <cluster-url>"
    exit 1
fi

# Create namespace if needed
echo "Creating namespace $NAMESPACE..."
oc create namespace $NAMESPACE --dry-run=client -o yaml | oc apply -f -

# Apply tasks
echo ""
echo "=== Applying Tasks ==="
oc apply -f "$ROOT_DIR/tasks/" -n $NAMESPACE

# Apply triggers
echo ""
echo "=== Applying Triggers ==="
oc apply -f "$ROOT_DIR/triggers/" -n $NAMESPACE

# Apply pipelines
echo ""
echo "=== Applying Pipelines ==="
oc apply -f "$ROOT_DIR/pipelines/" -n $NAMESPACE

# Apply GitOps (ArgoCD)
echo ""
echo "=== Applying GitOps Configuration ==="
oc apply -f "$ROOT_DIR/gitops/argocd-projects/" -n openshift-gitops
oc apply -f "$ROOT_DIR/gitops/argocd-apps/" -n openshift-gitops

# Create secrets if they don't exist
echo ""
echo "=== Checking Secrets ==="

if ! oc get secret git-ssh-credentials -n $NAMESPACE &>/dev/null; then
    echo "WARNING: git-ssh-credentials secret not found"
    echo "Create it with:"
    echo "  oc create secret generic git-ssh-credentials \\"
    echo "    --from-file=ssh-privatekey=~/.ssh/id_ed25519 \\"
    echo "    --from-file=known_hosts=~/.ssh/known_hosts \\"
    echo "    --type=kubernetes.io/ssh-auth \\"
    echo "    -n $NAMESPACE"
fi

if ! oc get secret sonarqube-credentials -n $NAMESPACE &>/dev/null; then
    echo "WARNING: sonarqube-credentials secret not found"
    echo "Create it with:"
    echo "  oc create secret generic sonarqube-credentials \\"
    echo "    --from-literal=token=\$SONAR_TOKEN \\"
    echo "    --from-literal=url=http://sonarqube.sonarqube.svc.cluster.local:9000 \\"
    echo "    -n $NAMESPACE"
fi

# Configure RBAC for target namespaces
echo ""
echo "=== Configuring RBAC ==="
for ns in uxie-dev uxie-qa uxie-uat uxie-prod; do
    oc create namespace $ns --dry-run=client -o yaml | oc apply -f - 2>/dev/null || true
    oc policy add-role-to-user system:image-builder system:serviceaccount:$NAMESPACE:pipeline -n $ns 2>/dev/null || true
    oc policy add-role-to-user edit system:serviceaccount:$NAMESPACE:pipeline -n $ns 2>/dev/null || true
    echo "  Configured RBAC for $ns"
done

# Get webhook URL
echo ""
echo "=== Webhook URL ==="
WEBHOOK_URL=$(oc get route webhook-github -n $NAMESPACE -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "$WEBHOOK_URL" ]; then
    echo "Webhook URL: https://$WEBHOOK_URL"
else
    echo "Route not created yet. Waiting..."
    sleep 5
    WEBHOOK_URL=$(oc get route webhook-github -n $NAMESPACE -o jsonpath='{.spec.host}' 2>/dev/null || echo "not available")
    echo "Webhook URL: https://$WEBHOOK_URL"
fi

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Next steps:"
echo "1. Create required secrets (see warnings above)"
echo "2. Configure GitHub webhooks for each repository"
echo "3. Push to develop branch to trigger dev deployment"
echo "4. Merge to main branch to trigger qa deployment with tagging"

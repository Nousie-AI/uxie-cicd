# uxie-cicd - CI/CD Automation

**Organization**: [Nousie-AI](https://github.com/Nousie-AI)
**Tech**: Tekton Pipelines + ArgoCD GitOps
**Namespace**: uxie-cicd (OpenShift)

## Current State

**Triggers**: NOT deployed (webhooks not configured)
**Promotion**: Manual via `oc` commands
**Nexus Registry**: Docker connector requires configuration (see Known Issues)

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        SOURCE REPOS                                  │
│  Nousie-AI/uxie-chat-api, uxie-admin-api, uxie-rag-api, etc.        │
└───────────────────────────┬─────────────────────────────────────────┘
                            │
                    Manual Pipeline Start
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      MAIN-PIPELINE                                   │
│  1. git-clone → reads ocp-config.yaml                               │
│  2. Detects pipelineRef (java/python/react)                         │
│  3. Spawns child pipeline with correct params                       │
└───────────────────────────┬─────────────────────────────────────────┘
                            │
              ┌─────────────┼─────────────┐
              ▼             ▼             ▼
        java-pipeline  python-pipeline  react-pipeline
              │             │             │
              └─────────────┼─────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    BUILD OUTPUTS                                     │
│                                                                      │
│  DEV: Internal Registry only                                        │
│       image-registry.../uxie-dev/<app>:latest                       │
│                                                                      │
│  QA:  Internal Registry + Nexus                                     │
│       image-registry.../uxie-qa/<app>:latest                        │
│       nxrm-ha-nexus-repo-docker-service:5000/<app>:<tag>            │
│                                                                      │
│  UAT/PROD: oc tag (no rebuild - same bytes as QA)                   │
│       image-registry.../uxie/<app>:latest                           │
└─────────────────────────────────────────────────────────────────────┘
```

## Manual Build Commands

### Build for DEV Environment

```bash
# Java application (e.g., chat-api)
cat << 'EOF' | oc create -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: uxie-chat-api-dev-
  namespace: uxie-cicd
spec:
  pipelineRef:
    name: main-pipeline
  params:
    - name: applicationName
      value: uxie-chat-api
    - name: gitRepoUrl
      value: git@github.com:Nousie-AI/uxie-chat-api.git
    - name: gitRevision
      value: refs/heads/develop
    - name: environment
      value: dev
    - name: enabledLintSonar
      value: "false"
    - name: ignoreLinterFailures
      value: "true"
    - name: ignoreTestFailures
      value: "true"
  workspaces:
    - name: data
      volumeClaimTemplate:
        spec:
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 1Gi
    - name: ssh-creds
      secret:
        secretName: git-ssh-credentials
EOF
```

### Build for QA Environment (with Nexus push)

```bash
# Java application (e.g., chat-api)
cat << 'EOF' | oc create -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: uxie-chat-api-qa-
  namespace: uxie-cicd
spec:
  pipelineRef:
    name: main-pipeline
  params:
    - name: applicationName
      value: uxie-chat-api
    - name: gitRepoUrl
      value: git@github.com:Nousie-AI/uxie-chat-api.git
    - name: gitRevision
      value: refs/heads/main
    - name: environment
      value: qa
    - name: enabledLintSonar
      value: "true"
  workspaces:
    - name: data
      volumeClaimTemplate:
        spec:
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 1Gi
    - name: ssh-creds
      secret:
        secretName: git-ssh-credentials
EOF
```

## Environment Promotion

### DEV → QA (using oc tag)

```bash
# Promote single image
oc tag uxie-dev/chat-api:latest uxie-qa/chat-api:latest

# Promote all working images
for app in chat-api admin-api chat-web enterprise-rag-api documents-api rag-api; do
  echo "Promoting $app from DEV to QA..."
  oc tag uxie-dev/${app}:latest uxie-qa/${app}:latest
done
```

### QA → PROD (using oc tag)

```bash
# Promote single image
oc tag uxie-qa/chat-api:latest uxie/chat-api:latest

# Promote all working images
for app in chat-api admin-api chat-web enterprise-rag-api documents-api; do
  echo "Promoting $app from QA to PROD..."
  oc tag uxie-qa/${app}:latest uxie/${app}:latest
done

# Scale up PROD deployments
for app in uxie-chat-api uxie-admin-api uxie-chat-web uxie-enterprise-rag-api uxie-documents-api; do
  oc scale deployment/$app -n uxie --replicas=1
done
```

## Nexus Registry (Cross-Environment Sharing)

### Registry Details

| Service | Internal URL | Port | Purpose |
|---------|--------------|------|---------|
| Docker Registry | nxrm-ha-nexus-repo-docker-service.nexus.svc.cluster.local | 5000 | Container images |
| Maven Repository | nxrm-ha-nexus-repo-service.nexus.svc.cluster.local | 80 | Maven artifacts |

### External Access

```
Web UI: http://nxrm-ha-nexus-repo-service-nexus.apps-crc.testing/
Docker: nexus-docker-local-nexus.apps-crc.testing
User: admin
Password: nexusabc
```

### Manual Push to Nexus (if pipeline doesn't run)

```bash
# Login to internal registry
oc whoami -t | podman login -u $(oc whoami) --password-stdin image-registry.openshift-image-registry.svc:5000

# Login to Nexus
podman login nxrm-ha-nexus-repo-docker-service.nexus.svc.cluster.local:5000 -u admin -p nexusabc

# Pull from internal, push to Nexus
IMAGE=chat-api
TAG=2025-12-16-01-00-00

skopeo copy \
  --src-tls-verify=false \
  --dest-tls-verify=false \
  docker://image-registry.openshift-image-registry.svc:5000/uxie-qa/${IMAGE}:latest \
  docker://nxrm-ha-nexus-repo-docker-service.nexus.svc.cluster.local:5000/${IMAGE}:${TAG}
```

### Pull from Nexus (for external environments)

```bash
# From external environment
podman pull nexus-docker-local-nexus.apps-crc.testing/chat-api:2025-12-16-01-00-00
```

## Quick Reference

### Monitor Pipeline

```bash
# List running pipelines
oc get pipelinerun -n uxie-cicd --sort-by=.metadata.creationTimestamp | tail -10

# Watch logs
tkn pipelinerun logs -f <pipelinerun-name> -n uxie-cicd

# Check tasks
oc get taskrun -n uxie-cicd -l tekton.dev/pipelineRun=<pipelinerun-name>
```

### Check Deployments

```bash
# DEV
oc get pods -n uxie-dev

# QA
oc get pods -n uxie-qa

# PROD
oc get pods -n uxie
```

### Force Deployment Update

```bash
# Restart deployment to pull new image
oc rollout restart deployment/uxie-chat-api -n uxie-dev

# Scale down/up
oc scale deployment/uxie-chat-api -n uxie-dev --replicas=0
oc scale deployment/uxie-chat-api -n uxie-dev --replicas=1
```

## ocp-config.yaml (Required in Source Repos)

Each source repository must have this file in root:

```yaml
# ocp-config.yaml
projectName: uxie
applicationName: chat-api
pipelineRef: java-pipeline           # java-pipeline | python-pipeline | react-pipeline
manifestGitUrl: git@github.com:Nousie-AI/uxie-chat-api-manifests.git
imageName: chat-api
internalRegistryURL: image-registry.openshift-image-registry.svc:5000
```

## Pipeline Comparison by Environment

| Aspect | DEV | QA | UAT/PROD |
|--------|-----|----|----|
| **Trigger** | Manual PipelineRun | Manual PipelineRun | oc tag |
| **Branch** | develop | main | N/A |
| **Build** | Yes | Yes | No (copy) |
| **Tests** | Skip | Run | N/A |
| **Tag Generated** | No | Yes (YYYY-MM-DD-HH-MM-SS) | No |
| **Nexus Push** | No | Yes | No |
| **Manifest Update** | Yes (latest) | Yes (latest) | Manual |
| **ArgoCD Sync** | Auto | Auto | Manual |

## Secrets Required

```bash
# Git SSH (for cloning and manifest updates)
oc create secret generic git-ssh-credentials \
  --from-file=ssh-privatekey=~/.ssh/id_ed25519 \
  --from-file=known_hosts=~/.ssh/known_hosts \
  --type=kubernetes.io/ssh-auth \
  -n uxie-cicd

# SonarQube (for code analysis)
oc create secret generic sonarqube-credentials \
  --from-literal=token=squ_a75c0342557a19b64a132e6f6ba553f85cbe1ba2 \
  --from-literal=url=http://sonarqube.sonarqube.svc.cluster.local:9000 \
  -n uxie-cicd

# Registry credentials (for Nexus)
oc create secret docker-registry registry-credentials \
  --docker-server=nxrm-ha-nexus-repo-docker-service.nexus.svc.cluster.local:5000 \
  --docker-username=admin \
  --docker-password=nexusabc \
  -n uxie-cicd
```

## Troubleshooting

### Pipeline fails at build-image

```bash
# Check buildah logs
oc logs <taskrun-pod> -c step-build -n uxie-cicd

# Common issues:
# - Dockerfile not found: Check dockerfilePath param
# - Permission denied: Check RBAC for pipeline SA
```

### Pipeline fails at push-to-nexus

```bash
# Check skopeo logs
oc logs <taskrun-pod> -c step-copy -n uxie-cicd

# Common issues:
# - Auth failed: Check registry-credentials secret
# - Network: Verify Nexus service is running
oc get pods -n nexus
```

### Image not appearing in Nexus

1. Verify QA environment pipeline completed
2. Check skopeo-copy task logs
3. Manually verify with:
```bash
curl -u admin:nexusabc http://nxrm-ha-nexus-repo-service-nexus.apps-crc.testing/v2/_catalog
```

### Pods stuck in ImagePullBackOff

```bash
# Check if image exists
oc get imagestream -n uxie-dev

# Force pull new image
oc rollout restart deployment/<app> -n uxie-dev
```

## File Structure

```
nousie-uxie-cicd/
├── pipelines/
│   ├── main-pipeline.yaml      # Orchestrator
│   ├── java-pipeline.yaml      # Java/Quarkus
│   ├── python-pipeline.yaml    # Python/FastAPI
│   └── react-pipeline.yaml     # React/Vite
├── tasks/
│   ├── git-clone.yaml
│   ├── generate-tag-custom.yaml
│   ├── maven-custom.yaml
│   ├── python-custom.yaml
│   ├── nodejs-custom.yaml
│   ├── buildah-simple.yaml
│   ├── skopeo-copy.yaml        # Nexus push
│   ├── update-manifest-custom.yaml
│   └── send-to-slack-custom.yaml
├── triggers/                   # NOT DEPLOYED (future)
│   ├── event-listener.yaml
│   ├── github-trigger-*.yaml
│   └── github-triggertemplate-*.yaml
└── CLAUDE.md                   # This file
```

## Components Status

| Component | Java | Python | React |
|-----------|------|--------|-------|
| chat-api | ✅ | - | - |
| admin-api | ✅ | - | - |
| documents-api | ✅ | - | - |
| rag-api | - | ⚠️ | - |
| enterprise-rag-api | - | ✅ | - |
| intent-api | - | ❌ | - |
| chat-web | - | - | ✅ |
| documents-web | - | - | ❌ |

**Legend**: ✅ Working | ⚠️ Build issue | ❌ Base image missing

## Known Issues

### Nexus Docker Registry Connector (Port 5000)

**Status**: NOT WORKING - Requires Nexus HA Operator configuration

**Problem**: The Nexus HA Operator manages the Nexus deployment. The Docker HTTP connector
on port 5000 is not bound because:
1. The `docker-hosted` repository has `httpPort: 5000` configured
2. But the Jetty HTTP connector itself is not created by the operator

**Workaround** (Current): Use `oc tag` for internal OpenShift image promotion. This works
for DEV → QA → PROD within the same cluster.

**To Fix** (When needed for cross-cluster sharing):

1. Edit the NexusRepo CR to configure dockerIngress:
```bash
oc edit nexusrepos.sonatype.com nexus-uxie -n nexus
```

2. Add dockerIngress configuration in spec:
```yaml
spec:
  ingress:
    dockerIngress:
      enabled: true
      host: docker-registry-nexus.apps-crc.testing
```

3. Delete StatefulSet to apply changes:
```bash
oc delete statefulset nxrm-ha-84-0-0-nexusrepo-statefulset -n nexus
```

4. Verify port 5000 is listening:
```bash
oc exec -n nexus nxrm-ha-84-0-0-nexusrepo-statefulset-0 -- curl localhost:5000/v2/
```

**Reference**: /home/darkdragonel/workspaceReferenciaCICD/entrega/entrega/bitbucket/devops/cicd/

### Maven Test Failures Block Pipeline

**Status**: Pipeline stops when maven-test fails in QA

**Problem**: The `ignoreTestFailures` parameter is not properly implemented in java-pipeline.
When tests fail, downstream tasks (push-to-nexus, update-manifest) are skipped.

**Workaround**: Skip tests in QA by setting `enabledLintSonar: "false"` or fix the tests.

### Python Build Missing Dependencies

**Status**: rag-api fails due to missing uvicorn

**Problem**: The Python pipeline doesn't properly install all dependencies in some cases.

**Workaround**: Fix the requirements.txt or Dockerfile to ensure all dependencies are installed.

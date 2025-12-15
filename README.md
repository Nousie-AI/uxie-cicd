# UXIE CI/CD - Tekton Pipelines + ArgoCD GitOps

Multi-environment CI/CD platform for UXIE services using Tekton Pipelines and ArgoCD GitOps.

## Architecture

```
GitHub (source repos)
    │
    ├─ Push to develop ──────────────────────────────────────────┐
    │                                                            │
    └─ Merge to main ────────────────────────────────────────────┤
                                                                 ▼
                                                    Tekton EventListener
                                                             │
                    ┌────────────────────────────────────────┴──────────────────────────────────────┐
                    │                                                                               │
                    ▼                                                                               ▼
            Branch: develop                                                                 Branch: main
                    │                                                                               │
                    ▼                                                                               ▼
           main-pipeline                                                                   main-pipeline
        (reads ocp-config.yaml)                                                         (reads ocp-config.yaml)
                    │                                                                               │
                    ▼                                                                               ▼
       Tech-Specific Pipeline                                                          Tech-Specific Pipeline
       (java/python/react)                                                             (java/python/react)
                    │                                                                               │
        ┌───────────┴───────────┐                                                      ┌───────────┴───────────┐
        │                       │                                                      │                       │
        ▼                       ▼                                                      ▼                       ▼
    git-clone               build/test                                             git-clone              build/test
        │                       │                                                      │                       │
        ▼                       ▼                                                      ▼                       ▼
    NO TAG               build-image                                             generate-tag           build-image
        │                       │                                                      │                       │
        ▼                       ▼                                                      ▼                       ▼
   push to                update-manifest                                         tag-repo              push to Nexus
internal registry             (dev)                                                    │                       │
        │                       │                                                      ▼                       ▼
        ▼                       ▼                                                 update-manifest         ArgoCD sync
   ArgoCD auto-sync       DEV DEPLOYED                                                (qa)                    (QA)
        │                                                                              │
        ▼                                                                              ▼
   DEV DEPLOYED                                                                   QA DEPLOYED


                    ┌──────────────────────────────────────────────────────────────────┐
                    │                          UAT / PROD                              │
                    │                                                                  │
                    │   Manual manifest update (overlays/uat/ or overlays/prod/)       │
                    │                              │                                   │
                    │                              ▼                                   │
                    │                     cd-pipeline                                  │
                    │                              │                                   │
                    │               ┌──────────────┴──────────────┐                    │
                    │               │                             │                    │
                    │               ▼                             ▼                    │
                    │        get-image-tag                   tag-image                 │
                    │        (from QA manifest)           (oc tag - NO REBUILD)        │
                    │                                            │                     │
                    │                                            ▼                     │
                    │                                    Manual ArgoCD sync            │
                    │                                            │                     │
                    │                                            ▼                     │
                    │                                    UAT/PROD DEPLOYED             │
                    └──────────────────────────────────────────────────────────────────┘
```

## Environments

| Environment | Trigger | Tag | Image Build | ArgoCD Sync |
|-------------|---------|-----|-------------|-------------|
| **dev** | Push to `develop` | No | Yes (internal) | Auto |
| **qa** | Merge to `main` | Yes (YYYY-MM-DD-HH-MM-SS) | Yes (internal + Nexus) | Auto |
| **uat** | Manual manifest update | No (uses QA tag) | No (oc tag copy) | Manual |
| **prod** | Manual manifest update | No (uses QA tag) | No (oc tag copy) | Manual |

## Directory Structure

```
uxie-cicd/
├── pipelines/
│   ├── main-pipeline.yaml           # Orchestrator (detects tech, routes)
│   ├── cd-pipeline.yaml             # Promotion without rebuild
│   ├── java-pipeline.yaml           # Java/Quarkus CI
│   ├── python-pipeline.yaml         # Python/FastAPI CI
│   └── react-pipeline.yaml          # React/Vite CI
├── triggers/
│   ├── event-listener.yaml          # Central webhook hub
│   ├── github-trigger-dev.yaml      # Branch: develop
│   ├── github-trigger-qa.yaml       # Branch: main (CI)
│   ├── github-trigger-cd-uat.yaml   # Manifest: overlays/uat/
│   ├── github-trigger-cd-prod.yaml  # Manifest: overlays/prod/
│   ├── github-triggertemplate-dev.yaml
│   ├── github-triggertemplate-qa.yaml
│   └── github-triggerbinding.yaml
├── tasks/
│   ├── git-clone.yaml
│   ├── generate-tag-custom.yaml
│   ├── tag-repo-custom.yaml
│   ├── maven-custom.yaml
│   ├── python-custom.yaml
│   ├── nodejs-custom.yaml
│   ├── sonarqube-scanner-custom.yaml
│   ├── buildah-simple.yaml
│   ├── oc-tag-custom.yaml
│   ├── skopeo-copy.yaml
│   ├── update-manifest-custom.yaml
│   ├── get-image-tag-custom.yaml
│   └── send-to-slack-custom.yaml
├── gitops/
│   ├── argocd-projects/
│   │   └── uxie-project.yaml
│   └── argocd-apps/
│       ├── uxie-dev.yaml            # auto-sync
│       ├── uxie-qa.yaml             # auto-sync
│       ├── uxie-uat.yaml            # manual sync
│       └── uxie-prod.yaml           # manual sync
└── scripts/
    ├── apply-all.sh
    └── test-webhook.sh
```

## Quick Start

### 1. Deploy to OpenShift

```bash
# Apply all resources
./scripts/apply-all.sh

# Or manually
oc apply -f tasks/
oc apply -f triggers/
oc apply -f pipelines/
oc apply -f gitops/
```

### 2. Configure GitHub Webhooks

For each source repository, add a webhook:
- **Payload URL**: `https://webhook-github-uxie-cicd.apps-crc.testing`
- **Content type**: `application/json`
- **Secret**: (from `github-webhook-secret` secret)
- **Events**: `push`

### 3. Test Pipeline

```bash
# Manual trigger for testing
./scripts/test-webhook.sh uxie-chat-api main
```

## ocp-config.yaml

Each source repository must have an `ocp-config.yaml` file in its root:

```yaml
# ocp-config.yaml - Required in each source repo
projectName: uxie
applicationName: chat-api
pipelineRef: java-pipeline           # java-pipeline | python-pipeline | react-pipeline
manifestGitUrl: git@github.com:Nousie-AI/uxie-chat-api-manifests.git
imageName: chat-api
internalRegistryURL: image-registry.openshift-image-registry.svc:5000
```

## Services

| Service | Tech | Pipeline | Manifest Repo |
|---------|------|----------|---------------|
| uxie-chat-api | Java/Quarkus | java-pipeline | uxie-chat-api-manifests |
| uxie-admin-api | Java/Quarkus | java-pipeline | uxie-admin-api-manifests |
| uxie-documents-api | Java/Quarkus | java-pipeline | uxie-documents-api-manifests |
| uxie-rag-api | Python/FastAPI | python-pipeline | uxie-rag-api-manifests |
| uxie-enterprise-rag-api | Python/FastAPI | python-pipeline | uxie-enterprise-rag-api-manifests |
| uxie-intent-api | Python/Flask | python-pipeline | uxie-intent-api-manifests |
| uxie-chat-web | React/TS | react-pipeline | uxie-chat-web-manifests |
| uxie-documents-web | React/Vite | react-pipeline | uxie-documents-web-manifests |

## Prerequisites

### Secrets

```bash
# Git SSH credentials
oc create secret generic git-ssh-credentials \
  --from-file=ssh-privatekey=~/.ssh/id_ed25519 \
  --from-file=known_hosts=~/.ssh/known_hosts \
  --type=kubernetes.io/ssh-auth \
  -n uxie-cicd

# SonarQube credentials
oc create secret generic sonarqube-credentials \
  --from-literal=token=${SONAR_TOKEN} \
  --from-literal=url=http://sonarqube.sonarqube.svc.cluster.local:9000 \
  -n uxie-cicd

# GitHub webhook secret
oc create secret generic github-webhook-secret \
  --from-literal=secret=${WEBHOOK_SECRET} \
  -n uxie-cicd

# Nexus credentials
oc create secret generic nexus-credentials \
  --from-literal=username=admin \
  --from-literal=password=${NEXUS_PASSWORD} \
  -n uxie-cicd
```

### RBAC

```bash
# Grant image-builder to target namespaces
for ns in uxie-dev uxie-qa uxie-uat uxie-prod; do
  oc policy add-role-to-user system:image-builder \
    system:serviceaccount:uxie-cicd:pipeline -n $ns
  oc policy add-role-to-user edit \
    system:serviceaccount:uxie-cicd:pipeline -n $ns
done
```

## Monitoring

```bash
# List PipelineRuns
oc get pipelinerun -n uxie-cicd

# Watch logs
tkn pipelinerun logs -f -n uxie-cicd

# Check EventListener
oc logs -f -l eventlistener=github-listener -n uxie-cicd
```

## Organization

**GitHub Organization**: [Nousie-AI](https://github.com/Nousie-AI)

All UXIE repositories are hosted under this organization:
- Source code repos (8)
- Manifest repos (8)
- Infrastructure repos (6)

## References

- [Tekton Pipelines](https://tekton.dev/docs/pipelines/)
- [Tekton Triggers](https://tekton.dev/docs/triggers/)
- [ArgoCD](https://argo-cd.readthedocs.io/)
- [Kustomize](https://kustomize.io/)

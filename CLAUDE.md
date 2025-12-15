# uxie-cicd - CI/CD Automation

**Organization**: [Nousie-AI](https://github.com/Nousie-AI)
**Tech**: Tekton Pipelines + ArgoCD GitOps
**Namespace**: uxie-cicd (OpenShift)

## Purpose

Multi-environment CI/CD for UXIE Platform with proper Gitflow and GitOps.

## Architecture Summary

```
Source Repos (Nousie-AI/uxie-*)
    │
    ├─ Push to develop ─────→ github-trigger-dev ─────→ main-pipeline ─────→ tech-pipeline ─────→ DEV
    │                                                       │                    │
    │                                                       └─ reads ────────────┘
    │                                                          ocp-config.yaml
    │
    └─ Merge to main ───────→ github-trigger-qa ──────→ main-pipeline ─────→ tech-pipeline ─────→ QA
                                                                                  │
                                                                                  ├─ generate-tag
                                                                                  ├─ tag-repo
                                                                                  └─ push-to-nexus

Manifest Repos (Nousie-AI/uxie-*-manifests)
    │
    ├─ Edit overlays/uat/ ──→ github-trigger-cd-uat ──→ cd-pipeline ─────→ oc-tag (NO REBUILD) ─→ UAT
    │
    └─ Edit overlays/prod/ ─→ github-trigger-cd-prod ─→ cd-pipeline ─────→ oc-tag (NO REBUILD) ─→ PROD
```

## Key Design Decisions

### 1. Branch-Based Triggers
- `develop` → dev environment (no tag, relaxed quality gates)
- `main` → qa environment (tag generated, strict quality gates)

### 2. Orchestrator Pattern
`main-pipeline` reads `ocp-config.yaml` from source repo to determine:
- `pipelineRef`: java-pipeline | python-pipeline | react-pipeline
- `manifestGitUrl`: Where to update after build
- `imageName`: Image name in registry

### 3. Conditional Tasks
Tech pipelines use `when` blocks:
```yaml
- name: generate-tag
  when:
    - input: $(params.environment)
      operator: in
      values: ["qa"]  # Only runs for QA!
```

### 4. CD Pipeline (No Rebuild)
UAT/PROD use `oc tag` to copy images from QA namespace:
- No rebuild = same exact bytes as tested in QA
- Triggered by manifest repo changes (overlays/uat/, overlays/prod/)

### 5. ArgoCD Sync Policies
- dev/qa: `automated: { prune: true, selfHeal: true }`
- uat/prod: `automated: null` (manual sync required)

## File Structure

```
uxie-cicd/
├── pipelines/
│   ├── main-pipeline.yaml      # Orchestrator
│   ├── cd-pipeline.yaml        # Promotion (no rebuild)
│   ├── java-pipeline.yaml      # Java/Quarkus
│   ├── python-pipeline.yaml    # Python/FastAPI
│   └── react-pipeline.yaml     # React/Vite
├── triggers/
│   ├── event-listener.yaml
│   ├── github-trigger-dev.yaml
│   ├── github-trigger-qa.yaml
│   ├── github-trigger-cd-uat.yaml
│   ├── github-trigger-cd-prod.yaml
│   ├── github-triggertemplate-*.yaml
│   └── github-triggerbinding.yaml
├── tasks/
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
│   └── argocd-apps/
└── scripts/
    ├── apply-all.sh
    └── test-webhook.sh
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

## Quick Commands

```bash
# Deploy all resources
./scripts/apply-all.sh

# Test webhook locally
./scripts/test-webhook.sh uxie-chat-api develop

# Watch pipeline logs
tkn pipelinerun logs -f -n uxie-cicd

# List pipelines
oc get pipeline -n uxie-cicd

# List triggers
oc get trigger -n uxie-cicd

# Check EventListener
oc get pods -l eventlistener=github-listener -n uxie-cicd
oc logs -f -l eventlistener=github-listener -n uxie-cicd
```

## Environment Comparison

| Aspect | dev | qa | uat | prod |
|--------|-----|----|----|------|
| Branch | develop | main | N/A | N/A |
| Trigger | Push | Merge | Manifest edit | Manifest edit |
| Tag Generated | No | Yes | No | No |
| Image Build | Yes | Yes | No (oc tag) | No (oc tag) |
| Nexus Push | No | Yes | No | No |
| Quality Gates | Relaxed | Strict | N/A | N/A |
| ArgoCD Sync | Auto | Auto | Manual | Manual |

## Secrets Required

```bash
# Git SSH
oc create secret generic git-ssh-credentials \
  --from-file=ssh-privatekey=~/.ssh/id_ed25519 \
  --from-file=known_hosts=~/.ssh/known_hosts \
  --type=kubernetes.io/ssh-auth \
  -n uxie-cicd

# SonarQube
oc create secret generic sonarqube-credentials \
  --from-literal=token=$SONAR_TOKEN \
  --from-literal=url=http://sonarqube.sonarqube.svc.cluster.local:9000 \
  -n uxie-cicd

# GitHub Webhook
oc create secret generic github-webhook-secret \
  --from-literal=secret=uxie-webhook-secret-2025 \
  -n uxie-cicd
```

## Troubleshooting

### Pipeline not triggered
1. Check EventListener pod: `oc get pods -l eventlistener=github-listener -n uxie-cicd`
2. Check logs: `oc logs -f -l eventlistener=github-listener -n uxie-cicd`
3. Verify webhook signature matches secret

### Build fails
1. Check TaskRun logs: `tkn taskrun logs -f -n uxie-cicd`
2. Verify RBAC: `oc policy who-can push imagestreams -n uxie-dev`

### Manifest update fails
1. Verify SSH credentials: `oc get secret git-ssh-credentials -n uxie-cicd`
2. Check manifest repo structure (must have overlays/<env>/)

## References

| Resource | Location |
|----------|----------|
| This repo | https://github.com/Nousie-AI/uxie-cicd |
| Tekton Docs | https://tekton.dev/docs/ |
| ArgoCD Docs | https://argo-cd.readthedocs.io/ |

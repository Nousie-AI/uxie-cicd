# Tekton Triggers

GitHub webhook triggers for UXIE CI/CD pipelines.

## Trigger Types

### CI Triggers (Source Code Repos)

| Trigger | Branch | Environment | Pipeline |
|---------|--------|-------------|----------|
| `github-trigger-dev` | develop | dev | main-pipeline → tech-pipeline |
| `github-trigger-qa` | main | qa | main-pipeline → tech-pipeline |

### CD Triggers (Manifest Repos)

| Trigger | Path | Environment | Pipeline |
|---------|------|-------------|----------|
| `github-trigger-cd-uat` | overlays/uat/ | uat | cd-pipeline |
| `github-trigger-cd-prod` | overlays/prod/ | prod | cd-pipeline |

## CEL Filters

### Branch Detection
```yaml
# develop branch only
filter: 'body.ref == "refs/heads/develop"'

# main branch only
filter: 'body.ref == "refs/heads/main"'
```

### Path Detection (Manifest Repos)
```yaml
# UAT overlay changes
filter: |
  body.ref == "refs/heads/main" &&
  body.commits.exists(c, c.modified.exists(f, f.startsWith("overlays/uat/")))
```

## GitHub Webhook Setup

For each source repository:

1. Go to **Settings** → **Webhooks** → **Add webhook**

2. Configure:
   - **Payload URL**: `https://webhook-github-uxie-cicd.apps-crc.testing`
   - **Content type**: `application/json`
   - **Secret**: `uxie-webhook-secret-2025`
   - **Events**: Just the `push` event
   - **Active**: ✅

3. For manifest repositories, same setup but webhook triggers CD pipeline

## Testing

```bash
# Test dev trigger
./scripts/test-webhook.sh uxie-chat-api develop

# Test qa trigger
./scripts/test-webhook.sh uxie-chat-api main

# Watch EventListener logs
oc logs -f -l eventlistener=github-listener -n uxie-cicd
```

## Webhook URL

```bash
oc get route webhook-github -n uxie-cicd -o jsonpath='{.spec.host}'
```

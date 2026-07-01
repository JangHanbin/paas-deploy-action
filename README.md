# paas-deploy-action

GitHub Action that deploys a prebuilt image to PaaS. GitHub resolves `uses:` only
from **GitHub** repositories, so this is the GitHub-published copy of the deploy
helper. The PaaS platform source stays private on GitLab — only this thin wrapper
(`action.yml` + `paas-deploy.sh`, a curl/jq POST helper with no secrets) lives here.

## Publish (public, for external users)

External GitHub accounts can only `uses:` an action from a **public** repo, so
publish this as public. Only the wrapper is published — the PaaS platform source
stays private on GitLab.

```bash
# 1) Create an empty PUBLIC GitHub repo: github.com/JangHanbin/paas-deploy-action
#    (no README/license — the publish script provides the contents)

# 2) From the PaaS repo, run the publish script with the new repo's remote URL:
deploy/github-action/publish.sh git@github.com:JangHanbin/paas-deploy-action.git v1
#    (HTTPS works too: https://github.com/JangHanbin/paas-deploy-action.git)
```

The script assembles `action.yml` + `paas-deploy.sh` (+ this README) into a clean
repo and pushes `main` plus the `v1` tag. Re-run it after editing
`deploy/paas-deploy.sh` to refresh the copy and move `v1` forward.

(Internal-only alternative: keep the repo private and enable Settings → Actions →
General → Access → "Accessible from repositories owned by <owner>". This works
only for repos under the same account/org — external users still need public.)

## Use (in a deploying repo's workflow)

```yaml
- uses: actions/checkout@v4                 # to read deploy YAML
- uses: JangHanbin/paas-deploy-action@v1
  with:
    app: my-app
    token: ${{ secrets.PAAS_DEPLOY_TOKEN }}
    deploy-yaml: docker-compose.yml          # your committed compose, used as-is
    images: '{"web":"${{ needs.build.outputs.IMAGE_DIGEST }}"}'
    # http-port: "3000"                      # only to override the default route
    # health-path: /healthz                  # only if not /health
    # --- ${VAR} interpolation: pass secrets so the committed compose works as-is ---
    env: |
      {
        "DATABASE_URL": ${{ toJSON(secrets.DATABASE_URL) }},
        "JWT_SECRET":   ${{ toJSON(secrets.JWT_SECRET) }}
      }
    # --- private app images only ---
    registry-host: ghcr.io
    registry-username: ${{ secrets.GHCR_PULL_USERNAME }} # PAT owner username
    registry-password: ${{ secrets.GHCR_PULL_TOKEN }}    # classic PAT(read:packages)
```

`env` is a JSON object of variables/secrets. The agent injects them into
`docker compose` so `${VAR}` in your compose interpolates natively (like a local
`.env`) — deploy your committed compose as-is instead of generating one. Use
`toJSON()` to safely escape quotes/newlines (multiline PEM keys work). Values are
encrypted at rest; the control plane must have `PAAS_SECRET_KEY` set.

For GHCR private images, `GHCR_PULL_USERNAME` must be the GitHub username that
owns the classic PAT in `GHCR_PULL_TOKEN`. Do not use `${{ github.actor }}` unless
the workflow actor is guaranteed to be that same PAT owner.

GitHub needs **no** `PAAS_HELPER_IMAGE` / `DOCKER_AUTH_CONFIG` (those are GitLab
runner concepts). The only operator-provided value is the deploy token.

## Versioning

Tag releases (`v1`, `v1.1`, …) and move a floating `v1` tag forward so callers
can pin `@v1`. Re-run the publish steps after updating `paas-deploy.sh` in the
PaaS repo to keep this copy in sync (the script is single-sourced there).

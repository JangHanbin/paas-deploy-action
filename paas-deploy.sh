#!/usr/bin/env sh
# paas-deploy — deploy a prebuilt image to PaaS from environment variables.
# Building/pushing the image is the user's responsibility; this only deploys.
#
# Required:  PAAS_APP, PAAS_DEPLOY_TOKEN
# Action:    PAAS_ACTION = deploy (default) | teardown | delete | rollback
#            - teardown: un-deploy (stop serving; keep data volumes + app record)
#            - delete:   remove everything incl. data volumes, then purge the app
#            - rollback: re-deploy a past release; requires PAAS_RELEASE_ID
#                        (re-sends PAAS_REGISTRY_* as pull creds if set).
#            teardown/delete/rollback need only PAAS_APP + PAAS_DEPLOY_TOKEN
#            (rollback also PAAS_RELEASE_ID); no images/YAML.
# Optional:  PAAS_URL (default https://paas.free4me.cc), PAAS_DEPLOY_YAML
#            (default docker-compose.yml), PAAS_ENV_JSON (JSON object of
#            vars/secrets for ${VAR} interpolation in the compose),
#            PAAS_IMAGES,
#            PAAS_HTTP_SERVICE/PAAS_HTTP_PORT/PAAS_HEALTH_PATH,
#            PAAS_CUSTOM_DOMAINS (comma-separated custom domains, e.g.
#            "api.example.com,www.example.com"; each CNAME'd to the app),
#            PAAS_DEPLOY_TIMEOUT (e.g. "180s" — health/deploy timeout for slow
#            startups like DB init; agent default 90s),
#            PAAS_REGISTRY_HOST/USERNAME/PASSWORD (single registry) and/or
#            PAAS_REGISTRY_CREDENTIALS (JSON array for MULTIPLE registries, e.g.
#            '[{"host":"ghcr.io","username":"u","password":"t"},{"host":"registry.gitlab.com",...}]'),
#            PAAS_PROVIDER, PAAS_REPOSITORY, PAAS_COMMIT_SHA,
#            PAAS_POLL (default true), PAAS_POLL_TIMEOUT (default 120 s, auto-extends past PAAS_DEPLOY_TIMEOUT)
#
# PAAS_IMAGES is a JSON object ('{"web":"img@sha256:..."}') or a shorthand
# list ('web=img@sha256:...,worker=img@sha256:...'). If omitted, digest image
# values are inferred from PAAS_DEPLOY_YAML services.
set -eu

: "${PAAS_APP:?PAAS_APP is required}"
: "${PAAS_DEPLOY_TOKEN:?PAAS_DEPLOY_TOKEN is required}"

PAAS_URL="${PAAS_URL:-https://paas.free4me.cc}"
PAAS_DEPLOY_YAML="${PAAS_DEPLOY_YAML:-docker-compose.yml}"
PAAS_PROVIDER="${PAAS_PROVIDER:-ci}"
PAAS_REPOSITORY="${PAAS_REPOSITORY:-$PAAS_APP}"
PAAS_COMMIT_SHA="${PAAS_COMMIT_SHA:-manual}"
PAAS_ACTION="${PAAS_ACTION:-deploy}"

# track_deployment <response-json>: print the response and poll the deployment to
# completion (queued -> running -> succeeded/failed). Shared by deploy/teardown/delete.
track_deployment() {
  resp="$1"
  echo "$resp" | jq .
  dep_id=$(printf '%s' "$resp" | jq -r '.deploymentId // empty')
  app_url=$(printf '%s' "$resp" | jq -r '.appUrl // empty')
  [ -n "$app_url" ] && echo "endpoint: $app_url"

  poll_timeout="${PAAS_POLL_TIMEOUT:-}"
  if [ -z "$poll_timeout" ]; then
    poll_timeout=120
    dt="${PAAS_DEPLOY_TIMEOUT:-}"
    case "$dt" in
      *m) dt=$(( ${dt%m} * 60 )) ;;
      *s) dt="${dt%s}" ;;
    esac
    case "$dt" in
      ''|*[!0-9]*) : ;;
      *) [ "$dt" -gt 60 ] && poll_timeout=$(( dt + 60 )) ;;
    esac
  fi

  [ "${PAAS_POLL:-true}" = "true" ] && [ -n "$dep_id" ] || return 0
  echo "waiting for $dep_id (timeout ${poll_timeout}s) ..."
  elapsed=0
  while [ "$elapsed" -lt "$poll_timeout" ]; do
    poll_resp=$(curl -fsS "$PAAS_URL/v1/apps/$PAAS_APP/deployments/$dep_id" \
      -H "Authorization: Bearer $PAAS_DEPLOY_TOKEN")
    status=$(printf '%s' "$poll_resp" | jq -r '.status')
    echo "  status=$status"
    case "$status" in
      succeeded) [ -n "$app_url" ] && echo "done: $app_url" || echo "done"; exit 0 ;;
      failed)
        echo "operation failed. reason:" >&2
        printf '%s\n' "$poll_resp" | jq -r '.message // "(no message)"' >&2
        exit 1 ;;
    esac
    elapsed=$((elapsed + 3)); sleep 3
  done
  echo "timed out after ${poll_timeout}s waiting for $dep_id (operation may still be running)" >&2
  exit 1
}

# registry_creds: emit the registryCredentials JSON array. Combines the single
# PAAS_REGISTRY_* triple with PAAS_REGISTRY_CREDENTIALS (a JSON array), so multiple
# registries (different hosts) can be authenticated. Empty array if none.
# Note: docker keeps one credential per host, so use ONE token per registry host
# (for several packages on the same host, use a token that can read them all).
registry_creds() {
  creds='[]'
  if [ -n "${PAAS_REGISTRY_PASSWORD:-}" ] && [ -n "${PAAS_REGISTRY_USERNAME:-}" ]; then
    creds=$(printf '%s' "$creds" | jq \
      --arg host "${PAAS_REGISTRY_HOST:-}" --arg u "$PAAS_REGISTRY_USERNAME" --arg p "$PAAS_REGISTRY_PASSWORD" \
      '. + [{host:$host, username:$u, password:$p}]')
  fi
  if [ -n "${PAAS_REGISTRY_CREDENTIALS:-}" ]; then
    creds=$(printf '%s' "$creds" | jq --argjson extra "$PAAS_REGISTRY_CREDENTIALS" '. + $extra')
  fi
  printf '%s' "$creds"
}

# Lifecycle actions (un-deploy / delete) need only PAAS_APP + PAAS_DEPLOY_TOKEN.
if [ "$PAAS_ACTION" = "teardown" ]; then
  echo "Tearing down (un-deploy) '$PAAS_APP' on $PAAS_URL"
  track_deployment "$(curl -fsS -X POST "$PAAS_URL/v1/apps/$PAAS_APP/teardown" \
    -H "Authorization: Bearer $PAAS_DEPLOY_TOKEN")"
  exit 0
elif [ "$PAAS_ACTION" = "delete" ]; then
  echo "Deleting '$PAAS_APP' (incl. data volumes) on $PAAS_URL"
  track_deployment "$(curl -fsS -X DELETE "$PAAS_URL/v1/apps/$PAAS_APP" \
    -H "Authorization: Bearer $PAAS_DEPLOY_TOKEN")"
  exit 0
elif [ "$PAAS_ACTION" = "rollback" ]; then
  : "${PAAS_RELEASE_ID:?PAAS_RELEASE_ID is required for rollback}"
  # Re-send pull credentials so the agent can re-pull private images if needed.
  creds=$(registry_creds)
  body='{}'
  if [ "$(printf '%s' "$creds" | jq 'length')" -gt 0 ]; then
    body=$(printf '%s' "$creds" | jq '{registryCredentials: .}')
  fi
  echo "Rolling back '$PAAS_APP' to release $PAAS_RELEASE_ID on $PAAS_URL"
  track_deployment "$(printf '%s' "$body" | curl -fsS -X POST "$PAAS_URL/v1/apps/$PAAS_APP/releases/$PAAS_RELEASE_ID/rollback" \
    -H "Authorization: Bearer $PAAS_DEPLOY_TOKEN" -H "Content-Type: application/json" --data @-)"
  exit 0
elif [ "$PAAS_ACTION" != "deploy" ]; then
  echo "unknown PAAS_ACTION '$PAAS_ACTION' (expected deploy|teardown|delete|rollback)" >&2
  exit 1
fi

if [ -n "${PAAS_IMAGES:-}" ]; then
  case "$PAAS_IMAGES" in
    '{'*) images_json="$PAAS_IMAGES" ;;
    *)    images_json=$(printf '%s' "$PAAS_IMAGES" | jq -R 'split(",")|map(split("="))|map({(.[0]):.[1]})|add') ;;
  esac
elif [ -f "$PAAS_DEPLOY_YAML" ]; then
  images_json=$(awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function unquote(s) { if ((substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") || (substr(s, 1, 1) == sprintf("%c", 39) && substr(s, length(s), 1) == sprintf("%c", 39))) return substr(s, 2, length(s) - 2); return s }
    function emit() {
      if (service != "" && image != "" && index(image, "@sha256:") > 0) {
        gsub(/\\/, "\\\\", service); gsub(/"/, "\\\"", service)
        gsub(/\\/, "\\\\", image); gsub(/"/, "\\\"", image)
        printf "%s\"%s\":\"%s\"", sep, service, image
        sep=","
      }
    }
    BEGIN { print "{"; in_services=0; service=""; image=""; sep="" }
    /^[[:space:]]*services:[[:space:]]*$/ { in_services=1; next }
    in_services && /^[^[:space:]#][^:]*:/ { emit(); in_services=0; service=""; image=""; next }
    in_services && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { emit(); line=$0; sub(/^  /, "", line); sub(/:.*/, "", line); service=trim(line); image=""; next }
    in_services && service != "" && /^    image:[[:space:]]*/ { line=$0; sub(/^    image:[[:space:]]*/, "", line); image=unquote(trim(line)); next }
    END { emit(); print "}" }
  ' "$PAAS_DEPLOY_YAML")
else
  echo "PAAS_IMAGES is required when $PAAS_DEPLOY_YAML does not exist" >&2
  exit 1
fi

if [ "$(printf '%s' "$images_json" | jq 'length')" -eq 0 ]; then
  echo "No service images found. Set PAAS_IMAGES or add digest image: values to $PAAS_DEPLOY_YAML" >&2
  exit 1
fi
if ! printf '%s' "$images_json" | jq -e 'all(.[]; contains("@sha256:"))' >/dev/null; then
  echo "All service images must be immutable @sha256 digests" >&2
  exit 1
fi

payload=$(jq -n \
  --arg provider "$PAAS_PROVIDER" --arg repo "$PAAS_REPOSITORY" \
  --arg sha "$PAAS_COMMIT_SHA" --arg cf "$PAAS_DEPLOY_YAML" \
  --argjson images "$images_json" \
  '{provider:$provider, repository:$repo, commitSha:$sha, composeFile:$cf, images:$images}')

# Attach the deploy YAML as the run shape when present (multi-service).
if [ -n "$PAAS_DEPLOY_YAML" ] && [ -f "$PAAS_DEPLOY_YAML" ]; then
  payload=$(printf '%s' "$payload" | jq \
    --arg content "$(cat "$PAAS_DEPLOY_YAML")" --arg f "$PAAS_DEPLOY_YAML" \
    '. + {shape:{type:"compose", file:$f, content:$content}}')
fi

# Optional env/secrets for ${VAR} interpolation in the compose. The agent injects
# these into the `docker compose` process, so a committed compose using ${VAR}
# (like a local .env) works unchanged. PAAS_ENV_JSON must be a JSON object of
# string values; it is encrypted at rest by the control plane. Requires the
# control plane to have PAAS_SECRET_KEY set.
if [ -n "${PAAS_ENV_JSON:-}" ]; then
  if ! printf '%s' "$PAAS_ENV_JSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "PAAS_ENV_JSON must be a JSON object of string values" >&2
    exit 1
  fi
  payload=$(printf '%s' "$payload" | jq --argjson env "$PAAS_ENV_JSON" '. + {env:$env}')
fi

meta=$(jq -n \
  --arg s "${PAAS_HTTP_SERVICE:-}" --arg p "${PAAS_HTTP_PORT:-}" --arg h "${PAAS_HEALTH_PATH:-}" --arg dt "${PAAS_DEPLOY_TIMEOUT:-}" --arg cd "${PAAS_CUSTOM_DOMAINS:-}" \
  '{} + (if $s!="" then {httpService:$s} else {} end)
      + (if $p!="" then {httpPort:$p} else {} end)
      + (if $h!="" then {healthPath:$h} else {} end)
      + (if $dt!="" then {deployTimeout:$dt} else {} end)
      + (if $cd!="" then {customDomains:$cd} else {} end)')
payload=$(printf '%s' "$payload" | jq --argjson m "$meta" '. + (if ($m|length)>0 then {metadata:$m} else {} end)')

creds=$(registry_creds)
if [ "$(printf '%s' "$creds" | jq 'length')" -gt 0 ]; then
  payload=$(printf '%s' "$payload" | jq --argjson c "$creds" '. + {registryCredentials: $c}')
fi

echo "Deploying '$PAAS_APP' to $PAAS_URL"
resp=$(printf '%s' "$payload" | curl -fsS -X POST "$PAAS_URL/v1/apps/$PAAS_APP/deployments" \
  -H "Authorization: Bearer $PAAS_DEPLOY_TOKEN" -H "Content-Type: application/json" --data @-)
track_deployment "$resp"

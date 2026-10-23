#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ID="${PROJECT_ID:-}"
REGION="${REGION:-}"
ADDRESS_NAME="${ADDRESS_NAME:-}"
LB_SCOPE="${LB_SCOPE:-regional}"
NETWORK_TIER="${NETWORK_TIER:-}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

run() {
  log "+ $*"
  "$@"
}

resource_exists() {
  "$@" >/dev/null 2>&1
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    exit 1
  fi
}

lb_is_global() {
  [[ "$(printf '%s' "$LB_SCOPE" | tr '[:upper:]' '[:lower:]')" == "global" ]]
}

require_env PROJECT_ID
require_env ADDRESS_NAME

scope_lower="$(printf '%s' "$LB_SCOPE" | tr '[:upper:]' '[:lower:]')"
if [[ "$scope_lower" != "regional" && "$scope_lower" != "global" ]]; then
  echo "LB_SCOPE must be 'regional' or 'global' (got '$LB_SCOPE')." >&2
  exit 1
fi

if ! lb_is_global; then
  require_env REGION
fi

if [[ -z "$NETWORK_TIER" ]]; then
  if lb_is_global; then
    NETWORK_TIER="PREMIUM"
  else
    NETWORK_TIER="STANDARD"
  fi
fi
if lb_is_global && [[ "$NETWORK_TIER" != "PREMIUM" ]]; then
  echo "Global IP requires NETWORK_TIER=PREMIUM (got '$NETWORK_TIER')." >&2
  exit 1
fi

run gcloud config set project "$PROJECT_ID"
run gcloud services enable compute.googleapis.com

if lb_is_global; then
  if ! resource_exists gcloud compute addresses describe "$ADDRESS_NAME" \
    --project="$PROJECT_ID" --global; then
    run gcloud compute addresses create "$ADDRESS_NAME" \
      --project="$PROJECT_ID" \
      --global \
      --ip-version=IPV4
  else
    log "Global IP address $ADDRESS_NAME already exists"
  fi
  IP_ADDRESS="$(gcloud compute addresses describe "$ADDRESS_NAME" \
    --project="$PROJECT_ID" --global \
    --format='value(address)')"
  SCOPE_LABEL="Global"
  REGION_LINE=""
else
  if ! resource_exists gcloud compute addresses describe "$ADDRESS_NAME" \
    --project="$PROJECT_ID" --region="$REGION"; then
    run gcloud compute addresses create "$ADDRESS_NAME" \
      --project="$PROJECT_ID" \
      --region="$REGION" \
      --network-tier="$NETWORK_TIER"
  else
    log "Regional IP address $ADDRESS_NAME already exists"
  fi
  IP_ADDRESS="$(gcloud compute addresses describe "$ADDRESS_NAME" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --format='value(address)')"
  SCOPE_LABEL="Regional"
  REGION_LINE="Region:  $REGION"
fi

cat <<EOF

Static external IP is ready
---------------------------
Scope:   $SCOPE_LABEL
Project: $PROJECT_ID
${REGION_LINE:+${REGION_LINE}
}Name:    $ADDRESS_NAME
IP:      $IP_ADDRESS

Then wait for DNS propagation and run:
./02-finish-cloud-run-lb.sh
EOF

#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ID="${PROJECT_ID:-}"
REGION="${REGION:-}"
ADDRESS_NAME="${ADDRESS_NAME:-}"

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

require_env PROJECT_ID
require_env REGION
require_env ADDRESS_NAME

run gcloud config set project "$PROJECT_ID"
run gcloud services enable compute.googleapis.com

if ! resource_exists gcloud compute addresses describe "$ADDRESS_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION"; then
  run gcloud compute addresses create "$ADDRESS_NAME" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --network-tier=STANDARD
else
  log "Regional IP address $ADDRESS_NAME already exists"
fi

IP_ADDRESS="$(gcloud compute addresses describe "$ADDRESS_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --format='value(address)')"

cat <<EOF

Regional static external IP is ready
------------------------------------
Project: $PROJECT_ID
Region:  $REGION
Name:    $ADDRESS_NAME
IP:      $IP_ADDRESS

Then wait for DNS propagation and run:
./02-finish-regional-cloud-run-lb.sh
EOF

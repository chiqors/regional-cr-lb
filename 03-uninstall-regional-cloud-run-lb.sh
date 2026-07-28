#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ID="${PROJECT_ID:-}"
REGION="${REGION:-}"

SERVICE_MAPPINGS="${SERVICE_MAPPINGS:-}"

LB_NETWORK="${LB_NETWORK:-lb-network}"
PROXY_SUBNET="${PROXY_SUBNET:-lb-proxy-subnet}"

LB_NAME_PREFIX="${LB_NAME_PREFIX:-regional-serverless-lb}"
ADDRESS_NAME="${ADDRESS_NAME:-}"
URL_MAP_NAME="${URL_MAP_NAME:-${LB_NAME_PREFIX}-url-map}"
REDIRECT_URL_MAP_NAME="${REDIRECT_URL_MAP_NAME:-${LB_NAME_PREFIX}-redirect-url-map}"
HTTPS_PROXY_NAME="${HTTPS_PROXY_NAME:-${LB_NAME_PREFIX}-https-proxy}"
HTTP_PROXY_NAME="${HTTP_PROXY_NAME:-${LB_NAME_PREFIX}-http-proxy}"
HTTPS_FWD_RULE_NAME="${HTTPS_FWD_RULE_NAME:-${LB_NAME_PREFIX}-https-fr}"
HTTP_FWD_RULE_NAME="${HTTP_FWD_RULE_NAME:-${LB_NAME_PREFIX}-http-fr}"

DELETE_LB_CORE="${DELETE_LB_CORE:-true}"
DELETE_ADDRESS="${DELETE_ADDRESS:-false}"
DELETE_NETWORK="${DELETE_NETWORK:-false}"

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

bool_is_true() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$value" == "true" || "$value" == "1" || "$value" == "yes" ]]
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    exit 1
  fi
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/--+/-/g'
}

short_name() {
  local prefix="$1"
  local slug="$2"
  local suffix="$3"
  local max_len=63
  local reserved=$(( ${#prefix} + ${#suffix} + 2 ))
  local slug_max=$(( max_len - reserved ))

  if (( slug_max < 1 )); then
    echo "Name parts are too long: prefix='$prefix' suffix='$suffix'" >&2
    exit 1
  fi

  if (( ${#slug} > slug_max )); then
    slug="${slug:0:slug_max}"
    slug="${slug%-}"
    [[ -z "$slug" ]] && slug="x"
  fi

  printf '%s-%s-%s' "$prefix" "$slug" "$suffix"
}

parse_mappings() {
  local raw host service slug

  if [[ -z "$SERVICE_MAPPINGS" ]]; then
    HOSTS=()
    NEG_NAMES=()
    BACKEND_NAMES=()
    CERT_NAMES=()
    DNS_AUTH_NAMES=()
    return 0
  fi

  IFS=',' read -r -a RAW_MAPPINGS <<<"$SERVICE_MAPPINGS"

  HOSTS=()
  NEG_NAMES=()
  BACKEND_NAMES=()
  CERT_NAMES=()
  DNS_AUTH_NAMES=()

  for raw in "${RAW_MAPPINGS[@]}"; do
    raw="$(trim "$raw")"
    [[ -z "$raw" ]] && continue

    if [[ "$raw" != *=* ]]; then
      echo "Invalid mapping '$raw'. Expected host=cloud-run-service." >&2
      exit 1
    fi

    host="$(trim "${raw%%=*}")"
    service="$(trim "${raw#*=}")"
    slug="$(slugify "$host")"

    if [[ -z "$host" || -z "$service" ]]; then
      echo "Invalid mapping '$raw'. Host or service is blank." >&2
      exit 1
    fi

    HOSTS+=("$host")
    NEG_NAMES+=("$(short_name "$LB_NAME_PREFIX" "$slug" "neg")")
    BACKEND_NAMES+=("$(short_name "$LB_NAME_PREFIX" "$slug" "backend")")
    CERT_NAMES+=("$(short_name "$LB_NAME_PREFIX" "$slug" "cert")")
    DNS_AUTH_NAMES+=("$(short_name "$LB_NAME_PREFIX" "$slug" "dns-auth")")
  done
}

delete_if_exists() {
  local describe_cmd="$1"
  shift

  if eval "$describe_cmd" >/dev/null 2>&1; then
    run "$@"
  else
    log "Skipping missing resource: $*"
  fi
}

delete_mapping_resources() {
  local i
  for i in "${!HOSTS[@]}"; do
    delete_if_exists \
      "gcloud certificate-manager certificates describe '${CERT_NAMES[$i]}' --project='$PROJECT_ID' --location='$REGION'" \
      gcloud certificate-manager certificates delete "${CERT_NAMES[$i]}" \
        --project="$PROJECT_ID" \
        --location="$REGION" \
        --quiet

    delete_if_exists \
      "gcloud certificate-manager dns-authorizations describe '${DNS_AUTH_NAMES[$i]}' --project='$PROJECT_ID' --location='$REGION'" \
      gcloud certificate-manager dns-authorizations delete "${DNS_AUTH_NAMES[$i]}" \
        --project="$PROJECT_ID" \
        --location="$REGION" \
        --quiet

    delete_if_exists \
      "gcloud compute backend-services describe '${BACKEND_NAMES[$i]}' --project='$PROJECT_ID' --region='$REGION'" \
      gcloud compute backend-services delete "${BACKEND_NAMES[$i]}" \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --quiet

    delete_if_exists \
      "gcloud compute network-endpoint-groups describe '${NEG_NAMES[$i]}' --project='$PROJECT_ID' --region='$REGION'" \
      gcloud compute network-endpoint-groups delete "${NEG_NAMES[$i]}" \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --quiet
  done
}

delete_lb_core() {
  delete_if_exists \
    "gcloud compute forwarding-rules describe '$HTTP_FWD_RULE_NAME' --project='$PROJECT_ID' --region='$REGION'" \
    gcloud compute forwarding-rules delete "$HTTP_FWD_RULE_NAME" \
      --project="$PROJECT_ID" \
      --region="$REGION" \
      --quiet

  delete_if_exists \
    "gcloud compute forwarding-rules describe '$HTTPS_FWD_RULE_NAME' --project='$PROJECT_ID' --region='$REGION'" \
    gcloud compute forwarding-rules delete "$HTTPS_FWD_RULE_NAME" \
      --project="$PROJECT_ID" \
      --region="$REGION" \
      --quiet

  delete_if_exists \
    "gcloud compute target-http-proxies describe '$HTTP_PROXY_NAME' --project='$PROJECT_ID' --region='$REGION'" \
    gcloud compute target-http-proxies delete "$HTTP_PROXY_NAME" \
      --project="$PROJECT_ID" \
      --region="$REGION" \
      --quiet

  delete_if_exists \
    "gcloud compute target-https-proxies describe '$HTTPS_PROXY_NAME' --project='$PROJECT_ID' --region='$REGION'" \
    gcloud compute target-https-proxies delete "$HTTPS_PROXY_NAME" \
      --project="$PROJECT_ID" \
      --region="$REGION" \
      --quiet

  delete_if_exists \
    "gcloud compute url-maps describe '$REDIRECT_URL_MAP_NAME' --project='$PROJECT_ID' --region='$REGION'" \
    gcloud compute url-maps delete "$REDIRECT_URL_MAP_NAME" \
      --project="$PROJECT_ID" \
      --region="$REGION" \
      --quiet

  delete_if_exists \
    "gcloud compute url-maps describe '$URL_MAP_NAME' --project='$PROJECT_ID' --region='$REGION'" \
    gcloud compute url-maps delete "$URL_MAP_NAME" \
      --project="$PROJECT_ID" \
      --region="$REGION" \
      --quiet
}

delete_optional_foundation() {
  if bool_is_true "$DELETE_ADDRESS"; then
    delete_if_exists \
      "gcloud compute addresses describe '$ADDRESS_NAME' --project='$PROJECT_ID' --region='$REGION'" \
      gcloud compute addresses delete "$ADDRESS_NAME" \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --quiet
  fi

  if bool_is_true "$DELETE_NETWORK"; then
    delete_if_exists \
      "gcloud compute networks subnets describe '$PROXY_SUBNET' --project='$PROJECT_ID' --region='$REGION'" \
      gcloud compute networks subnets delete "$PROXY_SUBNET" \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --quiet

    delete_if_exists \
      "gcloud compute networks describe '$LB_NETWORK' --project='$PROJECT_ID'" \
      gcloud compute networks delete "$LB_NETWORK" \
        --project="$PROJECT_ID" \
        --quiet
  fi
}

print_summary() {
  cat <<EOF

Uninstall summary
-----------------
Project:         $PROJECT_ID
Region:          $REGION
LB core deleted: $DELETE_LB_CORE
Address deleted: $DELETE_ADDRESS
Network deleted: $DELETE_NETWORK
Mappings removed: ${#HOSTS[@]}
EOF

  if [[ "${#HOSTS[@]}" -gt 0 ]]; then
    local i
    printf '\nHosts processed:\n'
    for i in "${!HOSTS[@]}"; do
      printf '%s. %s\n' "$((i + 1))" "${HOSTS[$i]}"
    done
  fi
}

main() {
  require_env PROJECT_ID
  require_env REGION
  require_env ADDRESS_NAME
  run gcloud config set project "$PROJECT_ID"
  parse_mappings

  if bool_is_true "$DELETE_LB_CORE"; then
    delete_lb_core
  fi

  if [[ "${#HOSTS[@]}" -gt 0 ]]; then
    delete_mapping_resources
  fi

  delete_optional_foundation
  print_summary
}

main "$@"

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
DELETE_CLOUDFLARE_DNS="${DELETE_CLOUDFLARE_DNS:-false}"

CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"
CLOUDFLARE_ZONE_NAME="${CLOUDFLARE_ZONE_NAME:-}"

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

strip_trailing_dot() {
  local value="$1"
  value="$(trim "$value")"
  printf '%s' "${value%.}"
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

cloudflare_dns_delete_enabled() {
  bool_is_true "$DELETE_CLOUDFLARE_DNS"
}

require_cloudflare_cmds_if_enabled() {
  if cloudflare_dns_delete_enabled; then
    require_env CLOUDFLARE_API_TOKEN
    command -v curl >/dev/null 2>&1 || {
      echo "Missing required command: curl" >&2
      exit 1
    }
    command -v python3 >/dev/null 2>&1 || {
      echo "Missing required command: python3" >&2
      exit 1
    }
  fi
}

cloudflare_api() {
  local method="$1"
  local path="$2"
  local response errors

  response="$(curl -fsS -X "$method" "https://api.cloudflare.com/client/v4${path}" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN")"

  if [[ "$(printf '%s' "$response" | python3 -c 'import json,sys; print("true" if json.load(sys.stdin).get("success") else "false")')" != "true" ]]; then
    errors="$(printf '%s' "$response" | python3 -c 'import json,sys; data=json.load(sys.stdin); print("; ".join(f"{item.get(\"code\", \"unknown\")}: {item.get(\"message\", \"Unknown error\")}" for item in data.get("errors", [])) or "Unknown Cloudflare API error")')"
    echo "Cloudflare API error: $errors" >&2
    exit 1
  fi

  printf '%s' "$response"
}

CF_ZONE_CACHE_NAMES=()
CF_ZONE_CACHE_IDS=()

get_cached_cloudflare_zone_id() {
  local zone_name="$1"
  local i
  for i in "${!CF_ZONE_CACHE_NAMES[@]}"; do
    if [[ "${CF_ZONE_CACHE_NAMES[$i]}" == "$zone_name" ]]; then
      printf '%s' "${CF_ZONE_CACHE_IDS[$i]}"
      return 0
    fi
  done
  return 1
}

cache_cloudflare_zone_id() {
  local zone_name="$1"
  local zone_id="$2"
  CF_ZONE_CACHE_NAMES+=("$zone_name")
  CF_ZONE_CACHE_IDS+=("$zone_id")
}

get_first_result_id() {
  python3 -c 'import json,sys; data=json.load(sys.stdin); result=data.get("result") or []; print(result[0].get("id", "") if result else "")'
}

find_cloudflare_zone_for_host() {
  local host="$1"
  local candidate cached_zone_id response zone_id

  if [[ -n "$CLOUDFLARE_ZONE_ID" ]]; then
    CF_RESOLVED_ZONE_ID="$CLOUDFLARE_ZONE_ID"
    CF_RESOLVED_ZONE_NAME="${CLOUDFLARE_ZONE_NAME:-}"
    return 0
  fi

  if [[ -n "$CLOUDFLARE_ZONE_NAME" ]]; then
    candidate="$CLOUDFLARE_ZONE_NAME"
    cached_zone_id="$(get_cached_cloudflare_zone_id "$candidate" || true)"
    if [[ -n "$cached_zone_id" ]]; then
      CF_RESOLVED_ZONE_ID="$cached_zone_id"
      CF_RESOLVED_ZONE_NAME="$candidate"
      return 0
    fi

    response="$(cloudflare_api GET "/zones?name=${candidate}&status=active&match=all")"
    zone_id="$(printf '%s' "$response" | get_first_result_id)"
    if [[ -z "$zone_id" ]]; then
      echo "Unable to find Cloudflare zone '$candidate'." >&2
      exit 1
    fi
    cache_cloudflare_zone_id "$candidate" "$zone_id"
    CF_RESOLVED_ZONE_ID="$zone_id"
    CF_RESOLVED_ZONE_NAME="$candidate"
    return 0
  fi

  candidate="$host"
  while true; do
    cached_zone_id="$(get_cached_cloudflare_zone_id "$candidate" || true)"
    if [[ -n "$cached_zone_id" ]]; then
      CF_RESOLVED_ZONE_ID="$cached_zone_id"
      CF_RESOLVED_ZONE_NAME="$candidate"
      return 0
    fi

    response="$(cloudflare_api GET "/zones?name=${candidate}&status=active&match=all")"
    zone_id="$(printf '%s' "$response" | get_first_result_id)"
    if [[ -n "$zone_id" ]]; then
      cache_cloudflare_zone_id "$candidate" "$zone_id"
      CF_RESOLVED_ZONE_ID="$zone_id"
      CF_RESOLVED_ZONE_NAME="$candidate"
      return 0
    fi

    if [[ "$candidate" != *.* ]]; then
      break
    fi
    candidate="${candidate#*.}"
  done

  echo "Unable to find a Cloudflare zone for host '$host'. Set CLOUDFLARE_ZONE_ID or CLOUDFLARE_ZONE_NAME to skip discovery." >&2
  exit 1
}

get_cloudflare_record_ids() {
  python3 -c 'import json,sys; data=json.load(sys.stdin); [print(item.get("id", "")) for item in (data.get("result") or []) if item.get("id")]'
}

delete_cloudflare_dns_record_if_present() {
  local zone_id="$1"
  local type="$2"
  local name="$3"
  local response record_id

  response="$(cloudflare_api GET "/zones/${zone_id}/dns_records?type=${type}&name=${name}&match=all")"
  while IFS= read -r record_id; do
    [[ -z "$record_id" ]] && continue
    log "+ cloudflare_api DELETE /zones/${zone_id}/dns_records/${record_id}"
    cloudflare_api DELETE "/zones/${zone_id}/dns_records/${record_id}" >/dev/null
    log "Deleted Cloudflare DNS record: ${type} ${name}"
  done < <(printf '%s' "$response" | get_cloudflare_record_ids)
}

get_dns_auth_record_name_if_present() {
  local auth_name="$1"
  gcloud certificate-manager dns-authorizations describe "$auth_name" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --format='value(dnsResourceRecord.name)' 2>/dev/null || true
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

delete_cloudflare_dns_records() {
  local i auth_record_name

  for i in "${!HOSTS[@]}"; do
    find_cloudflare_zone_for_host "${HOSTS[$i]}"
    delete_cloudflare_dns_record_if_present "$CF_RESOLVED_ZONE_ID" "A" "${HOSTS[$i]}"

    auth_record_name="$(strip_trailing_dot "$(get_dns_auth_record_name_if_present "${DNS_AUTH_NAMES[$i]}")")"
    if [[ -n "$auth_record_name" ]]; then
      delete_cloudflare_dns_record_if_present "$CF_RESOLVED_ZONE_ID" "CNAME" "$auth_record_name"
    else
      log "Skipping missing DNS authorization lookup for ${HOSTS[$i]} when removing Cloudflare ACME CNAME"
    fi
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
Cloudflare DNS:  $DELETE_CLOUDFLARE_DNS
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
  require_cloudflare_cmds_if_enabled
  run gcloud config set project "$PROJECT_ID"
  parse_mappings

  if bool_is_true "$DELETE_LB_CORE"; then
    delete_lb_core
  fi

  if [[ "${#HOSTS[@]}" -gt 0 ]]; then
    if cloudflare_dns_delete_enabled; then
      delete_cloudflare_dns_records
    fi
    delete_mapping_resources
  fi

  delete_optional_foundation
  print_summary
}

main "$@"

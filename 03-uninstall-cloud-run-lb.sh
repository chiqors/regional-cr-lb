#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ID="${PROJECT_ID:-}"
REGION="${REGION:-}"

SERVICE_MAPPINGS="${SERVICE_MAPPINGS:-}"

LB_SCOPE="${LB_SCOPE:-regional}"

LB_NETWORK="${LB_NETWORK:-lb-network}"
PROXY_SUBNET="${PROXY_SUBNET:-lb-proxy-subnet}"

LB_NAME_PREFIX="${LB_NAME_PREFIX:-cloud-run-lb}"
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
WILDCARD_DOMAIN="${WILDCARD_DOMAIN:-}"

CERT_MODE="${CERT_MODE:-managed}"
CLASSIC_CERT_NAME="${CLASSIC_CERT_NAME:-${LB_NAME_PREFIX}-classic-cert}"

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

lb_is_global() {
  [[ "$(printf '%s' "$LB_SCOPE" | tr '[:upper:]' '[:lower:]')" == "global" ]]
}

cert_mode_is_classic_managed() {
  [[ "$(printf '%s' "$CERT_MODE" | tr '[:upper:]' '[:lower:]')" == "classic-managed" ]]
}

cert_location() {
  if lb_is_global; then
    printf 'global'
  else
    printf '%s' "$REGION"
  fi
}

validate_config() {
  local scope mode
  scope="$(printf '%s' "$LB_SCOPE" | tr '[:upper:]' '[:lower:]')"
  if [[ "$scope" != "regional" && "$scope" != "global" ]]; then
    echo "LB_SCOPE must be 'regional' or 'global' (got '$LB_SCOPE')." >&2
    exit 1
  fi
  mode="$(printf '%s' "$CERT_MODE" | tr '[:upper:]' '[:lower:]')"
  if [[ "$mode" != "managed" && "$mode" != "classic-managed" ]]; then
    echo "CERT_MODE must be 'managed' or 'classic-managed' (got '$CERT_MODE')." >&2
    exit 1
  fi
}

cloudflare_dns_delete_enabled() {
  bool_is_true "$DELETE_CLOUDFLARE_DNS"
}

require_cloudflare_cmds_if_enabled() {
  if cloudflare_dns_delete_enabled; then
    require_env CLOUDFLARE_API_TOKEN
    command -v curl >/dev/null 2>&1 || { echo "Missing required command: curl" >&2; exit 1; }
    command -v python3 >/dev/null 2>&1 || { echo "Missing required command: python3" >&2; exit 1; }
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
  CF_ZONE_CACHE_NAMES+=("$1")
  CF_ZONE_CACHE_IDS+=("$2")
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
    --location="$(cert_location)" \
    --format='value(dnsResourceRecord.name)' 2>/dev/null || true
}

parse_mappings() {
  local raw host service slug label

  WILDCARD_DOMAIN="$(strip_trailing_dot "$WILDCARD_DOMAIN")"
  if [[ -n "$WILDCARD_DOMAIN" && ! "$WILDCARD_DOMAIN" =~ ^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$ ]]; then
    echo "WILDCARD_DOMAIN must be a parent domain such as photon-indonesia.org." >&2
    exit 1
  fi

  HOSTS=()
  NEG_NAMES=()
  BACKEND_NAMES=()
  CERT_NAMES=()
  DNS_AUTH_NAMES=()

  RAW_MAPPINGS=("")
  if [[ -n "$SERVICE_MAPPINGS" ]]; then
    IFS=',' read -r -a RAW_MAPPINGS <<<"$SERVICE_MAPPINGS"
  fi
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

    if [[ -n "$WILDCARD_DOMAIN" ]]; then
      label="${host%."$WILDCARD_DOMAIN"}"
      if [[ "$host" != *."$WILDCARD_DOMAIN" || -z "$label" || "$label" == *.* ]]; then
        echo "Host '$host' is not covered by *.$WILDCARD_DOMAIN (one subdomain level only)." >&2
        exit 1
      fi
    fi

    HOSTS+=("$host")
    NEG_NAMES+=("$(short_name "$LB_NAME_PREFIX" "$slug" "neg")")
    BACKEND_NAMES+=("$(short_name "$LB_NAME_PREFIX" "$slug" "backend")")
    if ! cert_mode_is_classic_managed && [[ -z "$WILDCARD_DOMAIN" ]]; then
      CERT_NAMES+=("$(short_name "$LB_NAME_PREFIX" "$slug" "cert")")
      DNS_AUTH_NAMES+=("$(short_name "$LB_NAME_PREFIX" "$slug" "dns-auth")")
    fi
  done

  if ! cert_mode_is_classic_managed && [[ -n "$WILDCARD_DOMAIN" ]]; then
    slug="$(slugify "$WILDCARD_DOMAIN")"
    CERT_NAMES+=("$(short_name "$LB_NAME_PREFIX" "$slug" "wildcard-cert")")
    DNS_AUTH_NAMES+=("$(short_name "$LB_NAME_PREFIX" "$slug" "wildcard-dns-auth")")
  fi
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

scope_flag() {
  if lb_is_global; then
    printf -- '--global'
  else
    printf -- "--region=%s" "$REGION"
  fi
}

delete_backend_service() {
  local name="$1"
  if lb_is_global; then
    delete_if_exists \
      "gcloud compute backend-services describe '$name' --project='$PROJECT_ID' --global" \
      gcloud compute backend-services delete "$name" --project="$PROJECT_ID" --global --quiet
  else
    delete_if_exists \
      "gcloud compute backend-services describe '$name' --project='$PROJECT_ID' --region='$REGION'" \
      gcloud compute backend-services delete "$name" --project="$PROJECT_ID" --region="$REGION" --quiet
  fi
}

delete_mapping_resources() {
  local i
  for i in "${!HOSTS[@]}"; do
    if ! cert_mode_is_classic_managed && [[ -z "$WILDCARD_DOMAIN" ]]; then
      delete_certificate_resources "${CERT_NAMES[$i]}" "${DNS_AUTH_NAMES[$i]}"
    fi

    delete_backend_service "${BACKEND_NAMES[$i]}"

    delete_if_exists \
      "gcloud compute network-endpoint-groups describe '${NEG_NAMES[$i]}' --project='$PROJECT_ID' --region='$REGION'" \
      gcloud compute network-endpoint-groups delete "${NEG_NAMES[$i]}" \
        --project="$PROJECT_ID" --region="$REGION" --quiet
  done

  if ! cert_mode_is_classic_managed && [[ -n "$WILDCARD_DOMAIN" ]]; then
    delete_certificate_resources "${CERT_NAMES[0]}" "${DNS_AUTH_NAMES[0]}"
  fi

  if cert_mode_is_classic_managed; then
    delete_classic_managed_certificate
  fi
}

delete_classic_managed_certificate() {
  delete_if_exists \
    "gcloud compute ssl-certificates describe '$CLASSIC_CERT_NAME' --project='$PROJECT_ID' --global" \
    gcloud compute ssl-certificates delete "$CLASSIC_CERT_NAME" \
      --project="$PROJECT_ID" --global --quiet
}

delete_certificate_resources() {
  local cert_name="$1"
  local auth_name="$2"

  delete_if_exists \
    "gcloud certificate-manager certificates describe '$cert_name' --project='$PROJECT_ID' --location='$(cert_location)'" \
    gcloud certificate-manager certificates delete "$cert_name" \
      --project="$PROJECT_ID" --location="$(cert_location)" --quiet

  delete_if_exists \
    "gcloud certificate-manager dns-authorizations describe '$auth_name' --project='$PROJECT_ID' --location='$(cert_location)'" \
    gcloud certificate-manager dns-authorizations delete "$auth_name" \
      --project="$PROJECT_ID" --location="$(cert_location)" --quiet
}

delete_cloudflare_dns_records() {
  local i auth_record_name

  for i in "${!HOSTS[@]}"; do
    find_cloudflare_zone_for_host "${HOSTS[$i]}"
    delete_cloudflare_dns_record_if_present "$CF_RESOLVED_ZONE_ID" "A" "${HOSTS[$i]}"

    if ! cert_mode_is_classic_managed && [[ -z "$WILDCARD_DOMAIN" ]]; then
      auth_record_name="$(strip_trailing_dot "$(get_dns_auth_record_name_if_present "${DNS_AUTH_NAMES[$i]}")")"
      if [[ -n "$auth_record_name" ]]; then
        delete_cloudflare_dns_record_if_present "$CF_RESOLVED_ZONE_ID" "CNAME" "$auth_record_name"
      else
        log "Skipping missing DNS authorization lookup for ${HOSTS[$i]} when removing Cloudflare ACME CNAME"
      fi
    fi
  done

  if ! cert_mode_is_classic_managed && [[ -n "$WILDCARD_DOMAIN" ]]; then
    auth_record_name="$(strip_trailing_dot "$(get_dns_auth_record_name_if_present "${DNS_AUTH_NAMES[0]}")")"
    if [[ -n "$auth_record_name" ]]; then
      find_cloudflare_zone_for_host "$WILDCARD_DOMAIN"
      delete_cloudflare_dns_record_if_present "$CF_RESOLVED_ZONE_ID" "CNAME" "$auth_record_name"
    else
      log "Skipping missing DNS authorization lookup for $WILDCARD_DOMAIN when removing Cloudflare ACME CNAME"
    fi
  fi
}

delete_scoped() {
  local kind="$1" name="$2"
  if lb_is_global; then
    delete_if_exists \
      "gcloud compute $kind describe '$name' --project='$PROJECT_ID' --global" \
      gcloud compute "$kind" delete "$name" --project="$PROJECT_ID" --global --quiet
  else
    delete_if_exists \
      "gcloud compute $kind describe '$name' --project='$PROJECT_ID' --region='$REGION'" \
      gcloud compute "$kind" delete "$name" --project="$PROJECT_ID" --region="$REGION" --quiet
  fi
}

delete_lb_core() {
  delete_scoped forwarding-rules "$HTTP_FWD_RULE_NAME"
  delete_scoped forwarding-rules "$HTTPS_FWD_RULE_NAME"
  delete_scoped target-http-proxies "$HTTP_PROXY_NAME"
  delete_scoped target-https-proxies "$HTTPS_PROXY_NAME"
  delete_scoped url-maps "$REDIRECT_URL_MAP_NAME"
  delete_scoped url-maps "$URL_MAP_NAME"
}

delete_optional_foundation() {
  if bool_is_true "$DELETE_ADDRESS"; then
    if lb_is_global; then
      delete_if_exists \
        "gcloud compute addresses describe '$ADDRESS_NAME' --project='$PROJECT_ID' --global" \
        gcloud compute addresses delete "$ADDRESS_NAME" --project="$PROJECT_ID" --global --quiet
    else
      delete_if_exists \
        "gcloud compute addresses describe '$ADDRESS_NAME' --project='$PROJECT_ID' --region='$REGION'" \
        gcloud compute addresses delete "$ADDRESS_NAME" --project="$PROJECT_ID" --region="$REGION" --quiet
    fi
  fi

  if bool_is_true "$DELETE_NETWORK" && ! lb_is_global; then
    delete_if_exists \
      "gcloud compute networks subnets describe '$PROXY_SUBNET' --project='$PROJECT_ID' --region='$REGION'" \
      gcloud compute networks subnets delete "$PROXY_SUBNET" \
        --project="$PROJECT_ID" --region="$REGION" --quiet

    delete_if_exists \
      "gcloud compute networks describe '$LB_NETWORK' --project='$PROJECT_ID'" \
      gcloud compute networks delete "$LB_NETWORK" --project="$PROJECT_ID" --quiet
  fi
}

print_summary() {
  local scope_label
  if lb_is_global; then
    scope_label="Global"
  else
    scope_label="Regional ($REGION)"
  fi
  cat <<EOF

Uninstall summary
-----------------
Scope:            $scope_label
Project:          $PROJECT_ID
Cloud Run region: $REGION
LB core deleted:  $DELETE_LB_CORE
Address deleted:  $DELETE_ADDRESS
Network deleted:  $DELETE_NETWORK
Cloudflare DNS:   $DELETE_CLOUDFLARE_DNS
Mappings removed: ${#HOSTS[@]}
EOF

  if [[ "${#HOSTS[@]}" -gt 0 || -n "$WILDCARD_DOMAIN" ]]; then
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
  validate_config
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

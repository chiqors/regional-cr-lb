#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ID="${PROJECT_ID:-}"
REGION="${REGION:-}"
SERVICE_MAPPINGS="${SERVICE_MAPPINGS:-}"

LB_NETWORK="${LB_NETWORK:-lb-network}"
PROXY_SUBNET="${PROXY_SUBNET:-lb-proxy-subnet}"
PROXY_SUBNET_CIDR="${PROXY_SUBNET_CIDR:-10.129.0.0/23}"

LB_NAME_PREFIX="${LB_NAME_PREFIX:-regional-serverless-lb}"
ADDRESS_NAME="${ADDRESS_NAME:-}"
URL_MAP_NAME="${URL_MAP_NAME:-${LB_NAME_PREFIX}-url-map}"
REDIRECT_URL_MAP_NAME="${REDIRECT_URL_MAP_NAME:-${LB_NAME_PREFIX}-redirect-url-map}"
HTTPS_PROXY_NAME="${HTTPS_PROXY_NAME:-${LB_NAME_PREFIX}-https-proxy}"
HTTP_PROXY_NAME="${HTTP_PROXY_NAME:-${LB_NAME_PREFIX}-http-proxy}"
HTTPS_FWD_RULE_NAME="${HTTPS_FWD_RULE_NAME:-${LB_NAME_PREFIX}-https-fr}"
HTTP_FWD_RULE_NAME="${HTTP_FWD_RULE_NAME:-${LB_NAME_PREFIX}-http-fr}"

WAIT_FOR_CERT="${WAIT_FOR_CERT:-false}"
CERT_WAIT_TIMEOUT_SECONDS="${CERT_WAIT_TIMEOUT_SECONDS:-3600}"
CERT_POLL_SECONDS="${CERT_POLL_SECONDS:-30}"
SKIP_CERT_ATTACH="${SKIP_CERT_ATTACH:-false}"
WILDCARD_DOMAIN="${WILDCARD_DOMAIN:-}"

CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"
CLOUDFLARE_ZONE_NAME="${CLOUDFLARE_ZONE_NAME:-}"
CLOUDFLARE_TTL="${CLOUDFLARE_TTL:-1}"
CLOUDFLARE_A_PROXIED="${CLOUDFLARE_A_PROXIED:-false}"

SCRIPT_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$SCRIPT_TMP_DIR"' EXIT

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
  printf '[%s] WARNING: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
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

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
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

parse_mappings() {
  local raw host service slug neg_name backend_name cert_name auth_name label

  WILDCARD_DOMAIN="$(strip_trailing_dot "$WILDCARD_DOMAIN")"
  if [[ -n "$WILDCARD_DOMAIN" && ! "$WILDCARD_DOMAIN" =~ ^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$ ]]; then
    echo "WILDCARD_DOMAIN must be a parent domain such as photon-indonesia.org." >&2
    exit 1
  fi

  IFS=',' read -r -a RAW_MAPPINGS <<<"$SERVICE_MAPPINGS"
  if [[ "${#RAW_MAPPINGS[@]}" -eq 0 ]]; then
    echo "SERVICE_MAPPINGS is empty." >&2
    exit 1
  fi

  HOSTS=()
  SERVICES=()
  HOST_SLUGS=()
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

    if [[ -n "$WILDCARD_DOMAIN" ]]; then
      label="${host%."$WILDCARD_DOMAIN"}"
      if [[ "$host" != *."$WILDCARD_DOMAIN" || -z "$label" || "$label" == *.* ]]; then
        echo "Host '$host' is not covered by *.$WILDCARD_DOMAIN (one subdomain level only)." >&2
        exit 1
      fi
    fi

    neg_name="$(short_name "$LB_NAME_PREFIX" "$slug" "neg")"
    backend_name="$(short_name "$LB_NAME_PREFIX" "$slug" "backend")"
    cert_name="$(short_name "$LB_NAME_PREFIX" "$slug" "cert")"
    auth_name="$(short_name "$LB_NAME_PREFIX" "$slug" "dns-auth")"

    HOSTS+=("$host")
    SERVICES+=("$service")
    HOST_SLUGS+=("$slug")
    NEG_NAMES+=("$neg_name")
    BACKEND_NAMES+=("$backend_name")
    if [[ -z "$WILDCARD_DOMAIN" ]]; then
      CERT_NAMES+=("$cert_name")
      DNS_AUTH_NAMES+=("$auth_name")
    fi
  done

  if [[ "${#HOSTS[@]}" -eq 0 ]]; then
    echo "SERVICE_MAPPINGS did not produce any usable mappings." >&2
    exit 1
  fi

  if [[ -n "$WILDCARD_DOMAIN" ]]; then
    slug="$(slugify "$WILDCARD_DOMAIN")"
    CERT_NAMES+=("$(short_name "$LB_NAME_PREFIX" "$slug" "wildcard-cert")")
    DNS_AUTH_NAMES+=("$(short_name "$LB_NAME_PREFIX" "$slug" "wildcard-dns-auth")")
  fi
}

get_cert_scope() {
  local cert_name="$1"
  gcloud certificate-manager certificates describe "$cert_name" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --format='value(scope)' 2>/dev/null || true
}

get_cert_state() {
  local cert_name="$1"
  gcloud certificate-manager certificates describe "$cert_name" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --format='value(managed.state)' 2>/dev/null || true
}

get_lb_ip() {
  gcloud compute addresses describe "$ADDRESS_NAME" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --format='value(address)'
}

get_dns_auth_record_name() {
  local auth_name="$1"
  gcloud certificate-manager dns-authorizations describe "$auth_name" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --format='value(dnsResourceRecord.name)'
}

get_dns_auth_record_data() {
  local auth_name="$1"
  gcloud certificate-manager dns-authorizations describe "$auth_name" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --format='value(dnsResourceRecord.data)'
}

cloudflare_dns_enabled() {
  [[ -n "$CLOUDFLARE_API_TOKEN" ]]
}

require_cloudflare_cmds_if_enabled() {
  if cloudflare_dns_enabled; then
    require_cmd curl
    require_cmd python3
  fi
}

cloudflare_api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local response errors

  if [[ -n "$data" ]]; then
    response="$(curl -fsS -X "$method" "https://api.cloudflare.com/client/v4${path}" \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$data")"
  else
    response="$(curl -fsS -X "$method" "https://api.cloudflare.com/client/v4${path}" \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN")"
  fi

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

get_cloudflare_record_snapshot() {
  python3 -c 'import json,sys; data=json.load(sys.stdin); result=data.get("result") or []; record=result[0] if result else {}; print(f"{len(result)}\t{record.get(\"id\", \"\")}\t{record.get(\"content\", \"\")}\t{str(record.get(\"proxied\", False)).lower()}\t{record.get(\"ttl\", \"\")}")'
}

ensure_cloudflare_dns_record() {
  local zone_id="$1"
  local type="$2"
  local name="$3"
  local content="$4"
  local proxied="$5"
  local response snapshot record_count record_id record_content record_proxied record_ttl payload

  response="$(cloudflare_api GET "/zones/${zone_id}/dns_records?type=${type}&name=${name}&match=all")"
  snapshot="$(printf '%s' "$response" | get_cloudflare_record_snapshot)"
  IFS=$'\t' read -r record_count record_id record_content record_proxied record_ttl <<<"$snapshot"

  if (( record_count > 1 )); then
    echo "Multiple Cloudflare ${type} records already exist for '${name}'. Clean those up first so the script can manage that record safely." >&2
    exit 1
  fi

  payload="$(printf '{"type":"%s","name":"%s","content":"%s","ttl":%s,"proxied":%s,"comment":"Managed by regional-cloud-run-lb"}' \
    "$type" "$name" "$content" "$CLOUDFLARE_TTL" "$proxied")"

  if [[ -z "$record_id" ]]; then
    cloudflare_api POST "/zones/${zone_id}/dns_records" "$payload" >/dev/null
    log "Created Cloudflare DNS record: ${type} ${name} -> ${content}"
    return 0
  fi

  if [[ "$record_content" == "$content" && "$record_proxied" == "$proxied" && "$record_ttl" == "$CLOUDFLARE_TTL" ]]; then
    log "Cloudflare DNS record already up to date: ${type} ${name} -> ${content}"
    return 0
  fi

  cloudflare_api PATCH "/zones/${zone_id}/dns_records/${record_id}" "$payload" >/dev/null
  log "Updated Cloudflare DNS record: ${type} ${name} -> ${content}"
}

ensure_cloudflare_dns_authorization_record() {
  local auth_name="$1"
  local domain="$2"
  local acme_name acme_target

  find_cloudflare_zone_for_host "$domain"
  acme_name="$(strip_trailing_dot "$(get_dns_auth_record_name "$auth_name")")"
  acme_target="$(strip_trailing_dot "$(get_dns_auth_record_data "$auth_name")")"
  ensure_cloudflare_dns_record "$CF_RESOLVED_ZONE_ID" "CNAME" "$acme_name" "$acme_target" "false"
}

ensure_cloudflare_dns_records() {
  local lb_ip="$1"
  local host="$2"
  local auth_name="$3"

  find_cloudflare_zone_for_host "$host"
  ensure_cloudflare_dns_record "$CF_RESOLVED_ZONE_ID" "A" "$host" "$lb_ip" "$CLOUDFLARE_A_PROXIED"
  if [[ -n "$auth_name" ]]; then
    ensure_cloudflare_dns_authorization_record "$auth_name" "$host"
  fi
}

ensure_project() {
  run gcloud config set project "$PROJECT_ID"
  run gcloud services enable \
    run.googleapis.com \
    compute.googleapis.com \
    certificatemanager.googleapis.com
}

ensure_cloud_run_services() {
  local service
  for service in "${SERVICES[@]}"; do
    run gcloud run services describe "$service" --project="$PROJECT_ID" --region="$REGION" >/dev/null
  done
}

ensure_network() {
  if ! resource_exists gcloud compute networks describe "$LB_NETWORK" --project="$PROJECT_ID"; then
    run gcloud compute networks create "$LB_NETWORK" \
      --project="$PROJECT_ID" \
      --subnet-mode=custom
  else
    log "Network $LB_NETWORK already exists"
  fi
}

ensure_proxy_subnet() {
  if ! resource_exists gcloud compute networks subnets describe "$PROXY_SUBNET" \
    --project="$PROJECT_ID" \
    --region="$REGION"; then
    run gcloud compute networks subnets create "$PROXY_SUBNET" \
      --project="$PROJECT_ID" \
      --region="$REGION" \
      --network="$LB_NETWORK" \
      --range="$PROXY_SUBNET_CIDR" \
      --purpose=REGIONAL_MANAGED_PROXY \
      --role=ACTIVE
  else
    log "Proxy-only subnet $PROXY_SUBNET already exists"
  fi
}

ensure_address_exists() {
  if ! resource_exists gcloud compute addresses describe "$ADDRESS_NAME" \
    --project="$PROJECT_ID" \
    --region="$REGION"; then
    echo "Static IP $ADDRESS_NAME does not exist in region $REGION." >&2
    echo "Run ./01-create-ip-and-show-dns.sh first." >&2
    exit 1
  fi
}

ensure_serverless_neg() {
  local neg_name="$1"
  local service_name="$2"

  if ! resource_exists gcloud compute network-endpoint-groups describe "$neg_name" \
    --project="$PROJECT_ID" \
    --region="$REGION"; then
    run gcloud compute network-endpoint-groups create "$neg_name" \
      --project="$PROJECT_ID" \
      --region="$REGION" \
      --network-endpoint-type=serverless \
      --cloud-run-service="$service_name"
  else
    log "Serverless NEG $neg_name already exists"
  fi
}

ensure_backend_service() {
  local backend_name="$1"
  local neg_name="$2"

  if ! resource_exists gcloud compute backend-services describe "$backend_name" \
    --project="$PROJECT_ID" \
    --region="$REGION"; then
    run gcloud compute backend-services create "$backend_name" \
      --project="$PROJECT_ID" \
      --region="$REGION" \
      --load-balancing-scheme=EXTERNAL_MANAGED \
      --protocol=HTTP
  else
    log "Backend service $backend_name already exists"
  fi

  if ! gcloud compute backend-services describe "$backend_name" \
      --project="$PROJECT_ID" \
      --region="$REGION" \
      --format='json' | grep -q "\"group\": \".*/networkEndpointGroups/${neg_name}\""; then
    run gcloud compute backend-services add-backend "$backend_name" \
      --project="$PROJECT_ID" \
      --region="$REGION" \
      --network-endpoint-group="$neg_name" \
      --network-endpoint-group-region="$REGION"
  else
    log "Backend service $backend_name already points at NEG $neg_name"
  fi
}

render_main_url_map() {
  local file="$SCRIPT_TMP_DIR/url-map.yaml"
  local default_backend="${BACKEND_NAMES[0]}"
  local i

  {
    echo "name: ${URL_MAP_NAME}"
    echo "defaultService: regions/${REGION}/backendServices/${default_backend}"
    echo "hostRules:"
    for i in "${!HOSTS[@]}"; do
      cat <<EOF
- hosts:
  - ${HOSTS[$i]}
  pathMatcher: matcher-${HOST_SLUGS[$i]}
EOF
    done
    echo "pathMatchers:"
    for i in "${!HOSTS[@]}"; do
      cat <<EOF
- name: matcher-${HOST_SLUGS[$i]}
  defaultService: regions/${REGION}/backendServices/${BACKEND_NAMES[$i]}
EOF
    done
    echo "tests:"
    for i in "${!HOSTS[@]}"; do
      cat <<EOF
- host: ${HOSTS[$i]}
  path: /
  service: regions/${REGION}/backendServices/${BACKEND_NAMES[$i]}
EOF
    done
  } >"$file"

  printf '%s\n' "$file"
}

render_redirect_url_map() {
  local file="$SCRIPT_TMP_DIR/redirect-url-map.yaml"
  cat >"$file" <<EOF
name: ${REDIRECT_URL_MAP_NAME}
defaultUrlRedirect:
  httpsRedirect: true
  redirectResponseCode: MOVED_PERMANENTLY_DEFAULT
EOF
  printf '%s\n' "$file"
}

ensure_url_maps() {
  local main_map_file
  local redirect_map_file

  main_map_file="$(render_main_url_map)"
  redirect_map_file="$(render_redirect_url_map)"

  run gcloud compute url-maps import "$URL_MAP_NAME" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --source="$main_map_file" \
    --quiet

  run gcloud compute url-maps import "$REDIRECT_URL_MAP_NAME" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --source="$redirect_map_file" \
    --quiet
}

ensure_dns_authorization() {
  local auth_name="$1"
  local domain="$2"

  if ! resource_exists gcloud certificate-manager dns-authorizations describe "$auth_name" \
    --project="$PROJECT_ID" \
    --location="$REGION"; then
    run gcloud certificate-manager dns-authorizations create "$auth_name" \
      --project="$PROJECT_ID" \
      --location="$REGION" \
      --domain="$domain"
  else
    log "DNS authorization $auth_name already exists"
  fi
}

print_dns_authorization_records() {
  local auth_name="$1"

  gcloud certificate-manager dns-authorizations describe "$auth_name" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --format='yaml(dnsResourceRecord.name,dnsResourceRecord.type,dnsResourceRecord.data)'
}

ensure_certificate() {
  local cert_name="$1"
  local auth_name="$2"
  local domain="$3"
  local existing_scope

  existing_scope="$(get_cert_scope "$cert_name")"
  if [[ -n "$existing_scope" && "$existing_scope" != "DEFAULT" ]]; then
    echo "Existing certificate $cert_name has scope '$existing_scope'. Regional ALB requires scope 'DEFAULT'." >&2
    exit 1
  fi

  if ! resource_exists gcloud certificate-manager certificates describe "$cert_name" \
    --project="$PROJECT_ID" \
    --location="$REGION"; then
    run gcloud certificate-manager certificates create "$cert_name" \
      --project="$PROJECT_ID" \
      --location="$REGION" \
      --domains="$domain" \
      --dns-authorizations="$auth_name"
  else
    log "Certificate $cert_name already exists"
  fi
}

all_certificates_active() {
  local cert_name state
  for cert_name in "${CERT_NAMES[@]}"; do
    state="$(get_cert_state "$cert_name")"
    if [[ "$state" != "ACTIVE" ]]; then
      return 1
    fi
  done
  return 0
}

wait_for_active_certificates_if_requested() {
  local waited=0
  local cert_name state

  if all_certificates_active; then
    log "All certificates are ACTIVE"
    return 0
  fi

  if bool_is_true "$SKIP_CERT_ATTACH"; then
    warn "SKIP_CERT_ATTACH=true, so HTTPS proxy and redirect setup will be skipped for now."
    return 1
  fi

  if ! bool_is_true "$WAIT_FOR_CERT"; then
    warn "Not all certificates are ACTIVE yet."
    for cert_name in "${CERT_NAMES[@]}"; do
      state="$(get_cert_state "$cert_name")"
      warn "  $cert_name -> ${state:-UNKNOWN}"
    done
    warn "Add any missing Certificate Manager CNAME records, then rerun this script."
    return 1
  fi

  log "Waiting for all certificates to become ACTIVE"
  while (( waited < CERT_WAIT_TIMEOUT_SECONDS )); do
    sleep "$CERT_POLL_SECONDS"
    waited=$((waited + CERT_POLL_SECONDS))
    if all_certificates_active; then
      log "All certificates are ACTIVE"
      return 0
    fi
    for cert_name in "${CERT_NAMES[@]}"; do
      state="$(get_cert_state "$cert_name")"
      log "Certificate state: $cert_name -> ${state:-UNKNOWN} (${waited}s elapsed)"
    done
  done

  warn "Timed out waiting for certificate activation after ${CERT_WAIT_TIMEOUT_SECONDS}s."
  return 1
}

join_by_comma() {
  local result="" item
  for item in "$@"; do
    if [[ -z "$result" ]]; then
      result="$item"
    else
      result="${result},${item}"
    fi
  done
  printf '%s' "$result"
}

ensure_https_proxy() {
  local cert_list
  cert_list="$(join_by_comma "${CERT_NAMES[@]}")"

  if ! resource_exists gcloud compute target-https-proxies describe "$HTTPS_PROXY_NAME" \
    --project="$PROJECT_ID" \
    --region="$REGION"; then
    run gcloud compute target-https-proxies create "$HTTPS_PROXY_NAME" \
      --project="$PROJECT_ID" \
      --region="$REGION" \
      --url-map="$URL_MAP_NAME" \
      --certificate-manager-certificates="$cert_list"
  else
    run gcloud compute target-https-proxies update "$HTTPS_PROXY_NAME" \
      --project="$PROJECT_ID" \
      --region="$REGION" \
      --url-map="$URL_MAP_NAME" \
      --certificate-manager-certificates="$cert_list"
  fi
}

ensure_http_proxy() {
  if ! resource_exists gcloud compute target-http-proxies describe "$HTTP_PROXY_NAME" \
    --project="$PROJECT_ID" \
    --region="$REGION"; then
    run gcloud compute target-http-proxies create "$HTTP_PROXY_NAME" \
      --project="$PROJECT_ID" \
      --region="$REGION" \
      --url-map="$REDIRECT_URL_MAP_NAME"
  else
    run gcloud compute target-http-proxies update "$HTTP_PROXY_NAME" \
      --project="$PROJECT_ID" \
      --region="$REGION" \
      --url-map="$REDIRECT_URL_MAP_NAME"
  fi
}

ensure_https_forwarding_rule() {
  if ! resource_exists gcloud compute forwarding-rules describe "$HTTPS_FWD_RULE_NAME" \
    --project="$PROJECT_ID" \
    --region="$REGION"; then
    run gcloud compute forwarding-rules create "$HTTPS_FWD_RULE_NAME" \
      --project="$PROJECT_ID" \
      --region="$REGION" \
      --load-balancing-scheme=EXTERNAL_MANAGED \
      --network="$LB_NETWORK" \
      --address="$ADDRESS_NAME" \
      --target-https-proxy="$HTTPS_PROXY_NAME" \
      --target-https-proxy-region="$REGION" \
      --ports=443 \
      --network-tier=STANDARD
  else
    log "HTTPS forwarding rule $HTTPS_FWD_RULE_NAME already exists"
  fi
}

ensure_http_forwarding_rule() {
  if ! resource_exists gcloud compute forwarding-rules describe "$HTTP_FWD_RULE_NAME" \
    --project="$PROJECT_ID" \
    --region="$REGION"; then
    run gcloud compute forwarding-rules create "$HTTP_FWD_RULE_NAME" \
      --project="$PROJECT_ID" \
      --region="$REGION" \
      --load-balancing-scheme=EXTERNAL_MANAGED \
      --network="$LB_NETWORK" \
      --address="$ADDRESS_NAME" \
      --target-http-proxy="$HTTP_PROXY_NAME" \
      --target-http-proxy-region="$REGION" \
      --ports=80 \
      --network-tier=STANDARD
  else
    log "HTTP forwarding rule $HTTP_FWD_RULE_NAME already exists"
  fi
}

print_summary() {
  local ip cert_name state i
  ip="$(get_lb_ip)"

  cat <<EOF

Regional load balancer summary
------------------------------
Project:          $PROJECT_ID
Region:           $REGION
Load balancer IP: $ip
Cloudflare DNS:   $(cloudflare_dns_enabled && printf 'enabled' || printf 'manual')
Mappings:
EOF

  for i in "${!HOSTS[@]}"; do
    printf '%s. %s -> %s\n' "$((i + 1))" "${HOSTS[$i]}" "${SERVICES[$i]}"
  done

  cat <<EOF

DNS A records should point here:
EOF
  for i in "${!HOSTS[@]}"; do
    printf '%s. %s -> %s\n' "$((i + 1))" "${HOSTS[$i]}" "$ip"
  done

  printf '\nCertificate states:\n'
  for cert_name in "${CERT_NAMES[@]}"; do
    state="$(get_cert_state "$cert_name")"
    printf -- '- %s: %s\n' "$cert_name" "${state:-UNKNOWN}"
  done

  printf '\nCertificate Manager DNS authorization records:\n'
  for i in "${!DNS_AUTH_NAMES[@]}"; do
    printf '\n[%s]\n' "${WILDCARD_DOMAIN:-${HOSTS[$i]}}"
    print_dns_authorization_records "${DNS_AUTH_NAMES[$i]}"
  done
}

main() {
  require_env PROJECT_ID
  require_env REGION
  require_env ADDRESS_NAME
  require_env SERVICE_MAPPINGS
  require_cmd gcloud
  require_cloudflare_cmds_if_enabled
  parse_mappings

  ensure_project
  ensure_cloud_run_services
  ensure_network
  ensure_proxy_subnet
  ensure_address_exists

  local i
  local lb_ip
  lb_ip="$(get_lb_ip)"
  for i in "${!HOSTS[@]}"; do
    ensure_serverless_neg "${NEG_NAMES[$i]}" "${SERVICES[$i]}"
    ensure_backend_service "${BACKEND_NAMES[$i]}" "${NEG_NAMES[$i]}"
    if [[ -z "$WILDCARD_DOMAIN" ]]; then
      ensure_dns_authorization "${DNS_AUTH_NAMES[$i]}" "${HOSTS[$i]}"
    fi
    if cloudflare_dns_enabled; then
      if [[ -n "$WILDCARD_DOMAIN" ]]; then
        ensure_cloudflare_dns_records "$lb_ip" "${HOSTS[$i]}" ""
      else
        ensure_cloudflare_dns_records "$lb_ip" "${HOSTS[$i]}" "${DNS_AUTH_NAMES[$i]}"
      fi
    fi
    if [[ -z "$WILDCARD_DOMAIN" ]]; then
      ensure_certificate "${CERT_NAMES[$i]}" "${DNS_AUTH_NAMES[$i]}" "${HOSTS[$i]}"
    fi
  done

  if [[ -n "$WILDCARD_DOMAIN" ]]; then
    ensure_dns_authorization "${DNS_AUTH_NAMES[0]}" "$WILDCARD_DOMAIN"
    if cloudflare_dns_enabled; then
      ensure_cloudflare_dns_authorization_record "${DNS_AUTH_NAMES[0]}" "$WILDCARD_DOMAIN"
    fi
    ensure_certificate "${CERT_NAMES[0]}" "${DNS_AUTH_NAMES[0]}" "*.$WILDCARD_DOMAIN"
  fi

  ensure_url_maps

  if wait_for_active_certificates_if_requested; then
    ensure_https_proxy
    ensure_http_proxy
    ensure_https_forwarding_rule
    ensure_http_forwarding_rule
  fi

  print_summary
}

main "$@"

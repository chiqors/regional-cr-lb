# Cloud Run LB Usage

This setup puts a shared external Application Load Balancer in front of one or more Cloud Run services. You pick the scope — **regional** (default) or **global** — and the certificate strategy. HTTPS is enabled by default, with an HTTP-only option.

What you get:
- one shared external IP (regional or global)
- one shared load balancer
- one hostname per Cloud Run service
- HTTP to HTTPS redirect
- choice of certificate strategy (Certificate Manager / classic Google-managed)
- reusable add/remove flow for more services later

## Files

- [01-create-ip-and-show-dns.sh](./01-create-ip-and-show-dns.sh)
- [02-finish-cloud-run-lb.sh](./02-finish-cloud-run-lb.sh)
- [03-uninstall-cloud-run-lb.sh](./03-uninstall-cloud-run-lb.sh)

## Mental Model

Step 1 reserves the shared IP.

Step 2 creates or updates the shared load balancer and routes hostnames to Cloud Run services.

Step 3 removes the shared load balancer resources and optionally also removes the IP and (for regional) the network.

One IP is shared across multiple hostnames. Routing happens by hostname, not by separate IPs.

If you deploy multiple independent LBs in the same project and region, set a different `LB_NAME_PREFIX` for each deployment.

## Scope choice: regional vs global

| Aspect | `LB_SCOPE=regional` (default) | `LB_SCOPE=global` |
|---|---|---|
| IP | regional, `STANDARD` tier allowed | global, `PREMIUM` tier only |
| VPC + proxy-only subnet | created / required | not needed |
| LB blast radius | one region | anycast, worldwide |
| `CERT_MODE=managed` | ✅ Certificate Manager (regional) with DNS auth | ✅ Certificate Manager (global) with DNS auth |
| `CERT_MODE=classic-managed` | ❌ not supported by Google | ✅ Google-managed classic SSL cert (`--domains`) |

Cloud Run NEGs are always regional and bound to `REGION` regardless of scope.

## Inputs

### Common

- `PROJECT_ID`
- `REGION` (Cloud Run service region; still needed for global LB because NEGs bind here)
- `ADDRESS_NAME`
- `LB_SCOPE` (optional; `regional` (default) or `global`)
- `NETWORK_TIER` (optional; defaults to `STANDARD` for regional and `PREMIUM` for global; global must be `PREMIUM`)

### Step 2 and Step 3

- `SERVICE_MAPPINGS`
- `WILDCARD_DOMAIN` (optional; use one certificate for `*.example.com` instead of one per hostname)
- `ENABLE_HTTPS` (optional; defaults to `true`; set to `false` for an HTTP-only frontend on port 80)
- `LB_NAME_PREFIX` (optional; defaults to `cloud-run-lb`)
- `CERT_MODE` (optional; `managed` (default) uses Certificate Manager with Google-managed certs and DNS authorization; `classic-managed` uses a Google-managed classic SSL cert via `compute ssl-certificates --domains=...` — **requires `LB_SCOPE=global`**)
- `CLASSIC_CERT_NAME` (optional; defaults to `${LB_NAME_PREFIX}-classic-cert`; only used with `CERT_MODE=classic-managed`)

### Optional Cloudflare DNS Automation

- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ZONE_ID` or `CLOUDFLARE_ZONE_NAME` if you want to skip auto-discovery
- `CLOUDFLARE_TTL`
- `CLOUDFLARE_A_PROXIED`
- `DELETE_CLOUDFLARE_DNS` for uninstall cleanup

Format:

```bash
SERVICE_MAPPINGS='host1.example.com=cloud-run-service-1,host2.example.com=cloud-run-service-2'
```

## Step 1: Reserve The Shared IP

Regional (default):

```bash
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=my-lb-ip \
./01-create-ip-and-show-dns.sh
```

Global:

```bash
PROJECT_ID=my-gcp-project \
ADDRESS_NAME=my-global-lb-ip \
LB_SCOPE=global \
./01-create-ip-and-show-dns.sh
```

## Step 2: Create Or Update The Shared LB

Regional + managed certs (the default; same as the old regional-only setup):

```bash
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=my-lb-ip \
SERVICE_MAPPINGS='api.example.com=my-api,app.example.com=my-app' \
./02-finish-cloud-run-lb.sh
```

Global + managed certs (Certificate Manager, DNS-authorized):

```bash
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=my-global-lb-ip \
LB_SCOPE=global \
SERVICE_MAPPINGS='api.example.com=my-api,app.example.com=my-app' \
./02-finish-cloud-run-lb.sh
```

Global + classic Google-managed cert (`--domains`; the kind you see under "Classic certificates" in the Google Cloud console):

```bash
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=my-global-lb-ip \
LB_SCOPE=global \
CERT_MODE=classic-managed \
SERVICE_MAPPINGS='api.example.com=my-api,app.example.com=my-app' \
./02-finish-cloud-run-lb.sh
```

What step 2 does:
- creates or reuses a VPC and proxy-only subnet (regional only)
- creates or reuses one serverless NEG per hostname (always regional)
- creates or reuses one backend service per hostname
- creates or updates the shared URL maps (regional or global per `LB_SCOPE`)
- for `CERT_MODE=managed`: one DNS authorization and Certificate Manager certificate per hostname (or one wildcard set when `WILDCARD_DOMAIN` is set)
- for `CERT_MODE=classic-managed`: one classic Google-managed cert covering every host via `--domains`
- when certificates are usable, creates HTTPS and HTTP proxies plus forwarding rules
- enables HTTP to HTTPS redirect

By default, step 2 does not wait for certificates to become `ACTIVE`. If any are still provisioning, it prints the required DNS records and exits. Rerun step 2 after the certificates become active.

For `CERT_MODE=classic-managed`, the Google-managed cert can only reach `ACTIVE` after the forwarding rule exists AND DNS resolves to the LB IP, so step 2 creates the LB first and then (optionally with `WAIT_FOR_CERT=true`) polls for activation.

### HTTP-only mode

To expose the load balancer over plain HTTP only, set `ENABLE_HTTPS=false`. Certificate Manager resources are not created or required. Works for both scopes.

## DNS Records You Must Add

For each hostname in `SERVICE_MAPPINGS`, create:

- one `A` record pointing to the shared IP from step 1
- for `CERT_MODE=managed`, one `_acme-challenge...` `CNAME` record printed by step 2 (one per hostname, or one for the parent domain in wildcard mode)
- for `CERT_MODE=classic-managed`, no extra records — Google issues the cert after DNS points at the LB

## Optional: Share A Wildcard Certificate

Only applies to `CERT_MODE=managed`. For one-level subdomains under the same parent domain, use a single wildcard certificate:

```bash
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=my-lb-ip \
WILDCARD_DOMAIN=example.com \
SERVICE_MAPPINGS='api.example.com=my-api,app.example.com=my-app' \
./02-finish-cloud-run-lb.sh
```

Keep `WILDCARD_DOMAIN` set on subsequent step 2 runs and when uninstalling. `*.example.com` covers `api.example.com` and `app.example.com`, but not `example.com` or `x.api.example.com`.

## Optional: Create DNS Records In Cloudflare Automatically

If you use Cloudflare DNS, step 2 can create or update:

- one `A` record per hostname pointing to the shared load balancer IP
- for `CERT_MODE=managed`, one ACME `CNAME` record per hostname (or one for the parent domain in wildcard mode)

```bash
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=my-lb-ip \
SERVICE_MAPPINGS='api.example.com=my-api,app.example.com=my-app' \
CLOUDFLARE_API_TOKEN=your-cloudflare-api-token \
CLOUDFLARE_ZONE_NAME=example.com \
./02-finish-cloud-run-lb.sh
```

Notes:

- If `CLOUDFLARE_ZONE_ID` or `CLOUDFLARE_ZONE_NAME` is not set, the script tries to discover the zone from each hostname.
- `CLOUDFLARE_A_PROXIED` defaults to `false`, which is the safe default for Google-managed certificate validation.
- `CLOUDFLARE_TTL` defaults to `1`, which means Cloudflare automatic TTL.

## When Certificates Are Still Provisioning

This is normal on the first run.

For a single run, set `WAIT_FOR_CERT=true`. Step 2 prints the required DNS records before polling. The default wait timeout is one hour; set `CERT_WAIT_TIMEOUT_SECONDS` to change it.

## Add Another Service Later

1. Add a new `A` record for the new hostname pointing to the same shared IP.
2. Append the new mapping to `SERVICE_MAPPINGS`.
3. Rerun step 2.

For `CERT_MODE=classic-managed`, step 2 will not add new domains to an existing classic cert in place — delete the cert manually first, then rerun step 2 with the updated `SERVICE_MAPPINGS` so a new cert covering every host is created.

## Uninstall

Pass the same `LB_SCOPE` and `CERT_MODE` that you used in step 2. If you used `WILDCARD_DOMAIN`, pass that too.

Remove LB resources but keep the IP:

```bash
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=my-lb-ip \
SERVICE_MAPPINGS='api.example.com=my-api,app.example.com=my-app' \
./03-uninstall-cloud-run-lb.sh
```

Remove LB resources and Cloudflare DNS records:

```bash
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=my-lb-ip \
SERVICE_MAPPINGS='api.example.com=my-api,app.example.com=my-app' \
DELETE_CLOUDFLARE_DNS=true \
CLOUDFLARE_API_TOKEN=your-cloudflare-api-token \
CLOUDFLARE_ZONE_NAME=example.com \
./03-uninstall-cloud-run-lb.sh
```

Remove LB resources and the IP:

```bash
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=my-lb-ip \
DELETE_ADDRESS=true \
SERVICE_MAPPINGS='api.example.com=my-api,app.example.com=my-app' \
./03-uninstall-cloud-run-lb.sh
```

Remove LB resources, IP, and (regional only) the custom VPC + proxy subnet:

```bash
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=my-lb-ip \
DELETE_ADDRESS=true \
DELETE_NETWORK=true \
SERVICE_MAPPINGS='api.example.com=my-api,app.example.com=my-app' \
./03-uninstall-cloud-run-lb.sh
```

`DELETE_NETWORK=true` is ignored for `LB_SCOPE=global` because global LBs do not create a custom VPC.

## Notes

- The scripts are idempotent and intended for reruns.
- `PROJECT_ID`, `REGION`, and `ADDRESS_NAME` are required for all scripts (`REGION` is still used by Cloud Run NEGs when `LB_SCOPE=global`).
- `SERVICE_MAPPINGS` is required for step 2 and optional in step 3.
- Cloudflare automation in step 2 is enabled when `CLOUDFLARE_API_TOKEN` is set.
- Resource names are auto-generated from hostnames and truncated to fit GCP limits.
- The scripts are written to work with macOS system Bash.
- Cloudflare automation uses `curl` and `python3`.
- The setup assumes all mapped Cloud Run services are in the same region.

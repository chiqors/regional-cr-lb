# Regional Cloud Run LB Usage

This setup uses a shared `Regional external managed Load Balancer` in front of one or more Cloud Run services. HTTPS is enabled by default, with an HTTP-only option.

What you get:
- one shared regional static external IP
- one shared regional load balancer
- one hostname per Cloud Run service
- HTTP to HTTPS redirect
- Google-managed regional certificates
- reusable add/remove flow for more services later

## Files

- [01-create-ip-and-show-dns.sh](./01-create-ip-and-show-dns.sh)
- [02-finish-regional-cloud-run-lb.sh](./02-finish-regional-cloud-run-lb.sh)
- [03-uninstall-regional-cloud-run-lb.sh](./03-uninstall-regional-cloud-run-lb.sh)

## Mental Model

Step 1 only reserves the shared IP.

Step 2 creates or updates the shared load balancer and routes hostnames to Cloud Run services.

Step 3 removes the shared load balancer resources and optionally also removes the IP and network.

One IP is shared across multiple hostnames. Routing happens by hostname, not by separate IPs.

If you deploy multiple independent LBs in the same project and region, set a different `LB_NAME_PREFIX` for each deployment. The default resource names are shared, so omitting this would make later runs reuse the earlier LB's URL maps, proxies, and forwarding-rule names.

## Inputs

### Common

- `PROJECT_ID`
- `REGION`
- `ADDRESS_NAME`

### Step 2 and Step 3

- `SERVICE_MAPPINGS`
- `WILDCARD_DOMAIN` (optional; use one certificate for `*.example.com` instead of one per hostname)
- `ENABLE_HTTPS` (optional; defaults to `true`; set to `false` for an HTTP-only frontend on port 80)
- `LB_NAME_PREFIX` (optional; use a unique value when deploying more than one LB in the same project and region)

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

Example:

```bash
SERVICE_MAPPINGS='api.example.com=my-api-service,app.example.com=my-app-service'
```

## Step 1: Reserve The Shared IP

This script only creates the regional static external IP.

```bash
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=my-regional-lb-ip \
./01-create-ip-and-show-dns.sh
```

Expected result:
- a regional static external IP is created
- the script prints the IP address

If you only ran step 1 and want to undo it:

```bash
gcloud compute addresses delete my-regional-lb-ip \
  --project=my-gcp-project \
  --region=asia-southeast2
```

## Step 2: Create Or Update The Shared LB

Run step 2 after step 1.

```bash
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=cloud-run-reg-ext-lb-ip \
SERVICE_MAPPINGS='dashboard-management.c-grhen.org=photon-dashboard-management,dashboard-trial.c-grhen.org=photon-dashboard,prototype.c-grhen.org=photon-prototype' \
./02-finish-regional-cloud-run-lb.sh
```

What step 2 does:
- creates or reuses the VPC and proxy-only subnet
- creates or reuses one serverless NEG per hostname
- creates or reuses one backend service per hostname
- creates or updates the shared regional URL maps
- by default, creates one DNS authorization and one Google-managed regional certificate per hostname
- with `WILDCARD_DOMAIN`, creates one authorization for the parent domain and one shared wildcard certificate
- when certificates are active, creates HTTPS and HTTP proxies plus forwarding rules
- enables HTTP to HTTPS redirect

By default, step 2 does not wait for certificates. If any are still provisioning, it prints the required DNS records and exits without creating the frontends. Rerun step 2 after the certificates become active.

### HTTP-only mode

To expose the regional load balancer over plain HTTP, set `ENABLE_HTTPS=false`:

```bash
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=cloud-run-reg-ext-lb-ip \
SERVICE_MAPPINGS='api.example.com=my-api-service,app.example.com=my-app-service' \
ENABLE_HTTPS=false \
./02-finish-regional-cloud-run-lb.sh
```

This creates only the regional HTTP proxy and forwarding rule on port 80. The normal host-based URL map is attached directly, so requests with `Host: api.example.com` or `Host: app.example.com` route to their matching Cloud Run service. Certificate Manager resources are not created or required. The existing HTTPS behavior remains the default when `ENABLE_HTTPS` is omitted.

If you previously ran HTTPS mode, this updates the HTTP proxy to serve requests directly, but leaves existing HTTPS forwarding rules, proxies, certificates, and the redirect URL map in place. It does not delete existing resources.

## DNS Records You Must Add

For each hostname in `SERVICE_MAPPINGS`, create:

- one `A` record pointing to the shared IP from step 1
- in HTTPS mode, by default, one `_acme-challenge...` `CNAME` record printed by step 2
- in HTTPS mode with `WILDCARD_DOMAIN`, only the one `CNAME` record printed for the parent domain

HTTP-only mode does not need Certificate Manager DNS authorization records. Test a mapped hostname with its `Host` header, for example:

```bash
curl -i -H 'Host: api.example.com' http://35.219.10.153/
```

Opening `http://35.219.10.153/` without a hostname uses the URL map's default backend (`SERVICE_MAPPINGS`' first entry).

Example shape:

```dns
api.example.com.                       A      35.219.x.x
app.example.com.                       A      35.219.x.x

_acme-challenge_xxx.api.example.com.   CNAME  xxx.authorize.certificatemanager.goog.
_acme-challenge_xxx.app.example.com.   CNAME  xxx.authorize.certificatemanager.goog.
```

### Optional: Share A Wildcard Certificate

For one-level subdomains under the same parent domain, use a single wildcard certificate:

```bash
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=my-regional-lb-ip \
WILDCARD_DOMAIN=example.com \
SERVICE_MAPPINGS='api.example.com=my-api-service,app.example.com=my-app-service' \
./02-finish-regional-cloud-run-lb.sh
```

Add the single Certificate Manager `CNAME` printed for `example.com` to DNS and keep it for renewals. Each mapped hostname still needs an `A` record pointing to the shared IP; Cloudflare automation can create these records and the wildcard `CNAME` instead. `*.example.com` covers `api.example.com` and `app.example.com`, but not `example.com` or `x.api.example.com`. All mappings must be covered by the wildcard.

Keep `WILDCARD_DOMAIN` set on subsequent step 2 runs and when uninstalling. Switching an existing per-host setup to wildcard mode does not delete the old per-host certificates or DNS authorizations. Until the wildcard certificate is `ACTIVE`, step 2 leaves the existing HTTPS proxy unchanged; after it is active, step 2 attaches the wildcard certificate. Only then should you manually remove old per-host certificates and authorization CNAMEs if you no longer need them.

## Optional: Create DNS Records In Cloudflare Automatically

If you use Cloudflare DNS, step 2 can create or update:

- one `A` record per hostname pointing to the shared load balancer IP
- one ACME `CNAME` record per hostname, or one for the parent domain in wildcard mode

Example:

```bash
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=my-regional-lb-ip \
SERVICE_MAPPINGS='api.example.com=my-api-service,app.example.com=my-app-service' \
CLOUDFLARE_API_TOKEN=your-cloudflare-api-token \
CLOUDFLARE_ZONE_NAME=example.com \
./02-finish-regional-cloud-run-lb.sh
```

Notes:

- If `CLOUDFLARE_ZONE_ID` or `CLOUDFLARE_ZONE_NAME` is not set, the script tries to discover the zone from each hostname.
- `CLOUDFLARE_A_PROXIED` defaults to `false`, which is the safe default for Google-managed certificate validation.
- `CLOUDFLARE_TTL` defaults to `1`, which means Cloudflare automatic TTL.
- The token should be able to edit DNS records. If you rely on zone auto-discovery, it also needs permission to read zones.

## When Certificates Are Still Provisioning

This is normal on the first run. Certificate Manager DNS authorization can take several minutes to activate.

For a single run, set `WAIT_FOR_CERT=true`. Step 2 prints the required `A` and Certificate Manager `CNAME` records before polling. Add or verify those records in your DNS provider while the command remains running. Once all certificates are active, the script creates the proxies and forwarding rules automatically.

The default wait timeout is one hour. Set `CERT_WAIT_TIMEOUT_SECONDS` to change it. If the command times out, it exits with an error; after resolving any DNS issue, rerun step 2.

```bash
WAIT_FOR_CERT=true \
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=my-regional-lb-ip \
SERVICE_MAPPINGS='api.example.com=my-api-service,app.example.com=my-app-service' \
./02-finish-regional-cloud-run-lb.sh
```

## Add Another Service Later

This setup is designed for reuse.

To add another hostname and Cloud Run service later:

1. Add a new `A` record for the new hostname pointing to the same shared IP.
2. Append the new mapping to `SERVICE_MAPPINGS`.
3. Rerun step 2.

Example:

```bash
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=my-regional-lb-ip \
SERVICE_MAPPINGS='api.example.com=my-api-service,app.example.com=my-app-service,admin.example.com=my-admin-service' \
./02-finish-regional-cloud-run-lb.sh
```

## Uninstall

If you used `WILDCARD_DOMAIN` in step 2, set it to the same value when running step 3. Step 3 deletes the shared wildcard certificate and authorization once, even if `SERVICE_MAPPINGS` is empty; provide mappings to remove their backend services, NEGs, and optional Cloudflare `A` records. Per-host certificates created before switching to wildcard mode are not removed by wildcard uninstall.

### Remove LB Resources But Keep The IP

```bash
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=my-regional-lb-ip \
SERVICE_MAPPINGS='api.example.com=my-api-service,app.example.com=my-app-service' \
./03-uninstall-regional-cloud-run-lb.sh
```

### Remove LB Resources And Cloudflare DNS Records

```bash
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=my-regional-lb-ip \
SERVICE_MAPPINGS='api.example.com=my-api-service,app.example.com=my-app-service' \
DELETE_CLOUDFLARE_DNS=true \
CLOUDFLARE_API_TOKEN=your-cloudflare-api-token \
CLOUDFLARE_ZONE_NAME=example.com \
./03-uninstall-regional-cloud-run-lb.sh
```

### Remove LB Resources And The IP

```bash
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=my-regional-lb-ip \
DELETE_ADDRESS=true \
SERVICE_MAPPINGS='api.example.com=my-api-service,app.example.com=my-app-service' \
./03-uninstall-regional-cloud-run-lb.sh
```

### Remove LB Resources, IP, And Network

```bash
PROJECT_ID=my-gcp-project \
REGION=asia-southeast2 \
ADDRESS_NAME=my-regional-lb-ip \
DELETE_ADDRESS=true \
DELETE_NETWORK=true \
SERVICE_MAPPINGS='api.example.com=my-api-service,app.example.com=my-app-service' \
./03-uninstall-regional-cloud-run-lb.sh
```

If you do not use `DELETE_CLOUDFLARE_DNS=true`, remove the DNS records manually from your DNS provider:
- `A` records
- `_acme-challenge...` `CNAME` records

## Notes

- The scripts are idempotent and intended for reruns.
- `PROJECT_ID`, `REGION`, and `ADDRESS_NAME` are required for all scripts.
- `SERVICE_MAPPINGS` is required for step 2 and optional in step 3.
- Cloudflare automation in step 2 is enabled when `CLOUDFLARE_API_TOKEN` is set.
- Resource names are auto-generated from hostnames and truncated to fit GCP limits.
- The scripts are written to work with macOS system Bash.
- Cloudflare automation uses `curl` and `python3`.
- The setup assumes all mapped Cloud Run services are in the same region.
- The ADC quota-project warning from `gcloud` does not block this setup.
- The Python deprecation warning from `gcloud` does not block this setup.

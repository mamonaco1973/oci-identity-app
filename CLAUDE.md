# CLAUDE.md — oci-identity-app

A serverless notes CRUD API on OCI, secured with **OCI IAM Identity Domains**
(OAuth2 / OIDC, Authorization Code + PKCE). Five Functions handle one REST
operation each, OCI NoSQL Database stores the data, API Gateway validates the
caller's JWT and routes requests, and a static Object Storage site serves the
SPA. This is the authenticated sibling of `oci-crud-example` — the OCI analog of
`aws-cognito-app` (which adds Cognito auth to `aws-crud-example`).

`oci-identity-app ≈ oci-crud-example + Identity Domains auth + per-user notes.`

---

## What This Project Does

The browser runs a PKCE login against an Identity Domains app, gets an OIDC **ID
token**, and sends it to API Gateway. The gateway validates the token signature
against the domain's JWKS, then injects the verified `sub` claim as the
`X-User-Sub` header before invoking a Function. Each Function uses `sub` as the
NoSQL shard key, so users only ever see their own notes.

| Method | Path | Function | Auth | Owner |
|--------|------|----------|------|-------|
| POST | `/notes` | create-note | JWT required | `sub` claim |
| GET | `/notes` | list-notes | JWT required | `sub` claim |
| GET | `/notes/{id}` | get-note | JWT required | `sub` claim |
| PUT | `/notes/{id}` | update-note | JWT required | `sub` claim |
| DELETE | `/notes/{id}` | delete-note | JWT required | `sub` claim |

---

## Architecture

```
Browser (SPA on Object Storage)
   │  1. PKCE login  → Identity Domain /oauth2/v1/authorize
   │  2. callback.html exchanges code → tokens at /oauth2/v1/token
   │  3. stores id_token in sessionStorage
   ▼
API Gateway — notes-gateway (PUBLIC)
   │  authentication: JWT_AUTHENTICATION (REMOTE_JWKS = domain /admin/v1/SigningCert/jwk)
   │  each route: authorization = AUTHENTICATION_ONLY
   │  injects  X-User-Sub = ${request.auth[sub]}   (+ X-Note-Id for {id} routes)
   ▼
OCI Functions (one image, FUNCTION_TYPE dispatch, Resource Principal auth)
   ▼
OCI NoSQL Table: notes   PK: SHARD(owner=sub) + id(UUID4)
```

**Token choice:** the SPA sends the **ID token** (its `aud` is the app
client_id), so the gateway validates `audiences = [client_id]` with no custom
resource-app/scope plumbing. A later iteration could switch to access tokens
with a dedicated API scope.

---

## Repository Layout

```
01-ocir/        OCIR container repository (Terraform)
02-docker/      Docker image build + push (build.sh); code/func.py = all 5 handlers
03-functions/   Backend Terraform:
                  network.tf   VCN + public subnet + IGW + security list
                  nosql.tf     NoSQL table (SHARD(owner) + id)
                  functions.tf Functions Application + 5 Functions
                  identity.tf  Identity Domains app (SPA, PKCE, no secret) + domain lookup
                  api.tf       API Gateway + JWT auth + per-route authz + header inject
                  storage.tf   Web bucket (here so identity.tf can register its callback)
                  iam.tf       Dynamic Group + policies
                  outputs.tf   api endpoint, bucket, client_id, domain url, website url
04-webapp/      SPA upload only (bucket created in 03):
                  index.html.tmpl  SPA + PKCE login/logout (API_BASE injected)
                  callback.html    code→token exchange
                  storage.tf       uploads index/config/callback/favicon to the bucket
apply.sh / destroy.sh / check_env.sh / validate.sh
```

Phases are numbered by directory: **01-ocir → 02-docker → 03-functions →
04-webapp**. (Earlier docs referenced a 2-phase `01-functions`/`02-webapp`
layout; the real layout is these four.)

---

## Key Differences From oci-crud-example

1. **Identity Domains app** (`03-functions/identity.tf`) — public SPA client,
   Auth Code + PKCE, no secret. Looks up the domain via `oci_identity_domains` /
   `oci_identity_domain` data sources to get the `idcs_endpoint` (domain URL).
2. **API Gateway JWT auth** (`03-functions/api.tf`) — deployment-level
   `authentication { type = "JWT_AUTHENTICATION" ... }` with REMOTE_JWKS; every
   route opts in with `authorization { type = "AUTHENTICATION_ONLY" }`.
3. **Per-user owner** — `func.py` reads `X-User-Sub` (injected from
   `${request.auth[sub]}`) instead of the hardcoded `"global"`. Missing header →
   401. The list query filters on the caller's `sub` (single-quote escaped).
4. **Web bucket moved to phase 3** — so the app's OAuth redirect URI can point
   at the deterministic Object Storage callback URL. Phase 4 only uploads.
5. **SPA auth** — `index.html.tmpl` gains sign-in/out + PKCE; `callback.html` +
   generated `config.json` (domainUrl, clientId, redirectUri, apiBaseUrl).

---

## Prerequisites

- `oci`, `terraform`, `docker`, `jq`, `envsubst` in PATH
- OCI CLI configured (`~/.oci/config`, API key)
- The deploy principal needs **Identity Domain Administrator** on the target
  domain (the `oci_identity_domains_app` resource uses the domain SCIM API)
- An Identity Domains **user** to log in with during the manual test

---

## Deployment

```bash
./apply.sh      # 01-ocir → 02-docker → 03-functions → 04-webapp → validate
./destroy.sh    # reverse; purges OCIR images; deletes cached OCIR token
./validate.sh   # asserts unauthenticated calls are rejected; prints web URL
```

`apply.sh` reads Phase-3 outputs (API URL, bucket, client_id, domain URL),
generates `index.html` (envsubst `${API_BASE}`) and `config.json`, then uploads
via Phase 4 with `-var web_bucket_name=…`.

---

## VERIFY BEFORE SHIP (config-dependent, can't be confirmed offline)

These are flagged in `api.tf` and must be checked against a real token:

- **`issuers`** — set to `https://identity.oraclecloud.com/` (trailing slash).
  Some domains emit a domain-specific issuer; decode a live token's `iss` and
  match exactly, or the gateway returns 401 on every call.
- **`audiences`** — set to the app `client_id` because the SPA sends the ID
  token. If you switch to access tokens, change this to the API scope audience.
- **`oci_identity_domains_app` schema** — `allowed_grants`, `client_type =
  "public"`, and `based_on_template { value = "CustomWebAppTemplateId" }` are
  per the current provider; if `value` errors, try `well_known_id` instead.

---

## Modifying Function Code

1. Edit `02-docker/code/func.py`.
2. Re-run `./apply.sh` — `build.sh` content-hashes the source, producing a new
   image tag that forces the Functions to update.

Keep bytecode out of the tree: compile with `PYTHONDONTWRITEBYTECODE=1` and
never commit `__pycache__/` or `*.pyc`.

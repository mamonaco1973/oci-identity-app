# CLAUDE.md — oci-crud-example

A serverless notes CRUD API on OCI. Five Functions handle one REST operation each,
OCI NoSQL Database stores the data, API Gateway routes requests, and a static Object
Storage site provides a browser UI. This is the OCI port of aws-crud-example.

---

## What This Project Does

Clients hit an OCI API Gateway that routes each operation to a dedicated OCI Function.
OCI NoSQL Database persists the notes. A static HTML frontend served from Object Storage
makes API calls directly to the API Gateway endpoint.

**Base URL after deploy:**
```
https://{gateway-hostname}/
```

| Method | Path | Function | Operation |
|--------|------|----------|-----------|
| POST | `/notes` | create-note | Create note |
| GET | `/notes` | list-notes | List all notes |
| GET | `/notes/{id}` | get-note | Get single note |
| PUT | `/notes/{id}` | update-note | Update note |
| DELETE | `/notes/{id}` | delete-note | Delete note |

---

## Architecture

```
Browser / curl
     │
     ▼
OCI API Gateway — notes-gateway (PUBLIC)
     │  routes by method + path
     ├── POST   /notes        → Function: create-note
     ├── GET    /notes        → Function: list-notes
     ├── GET    /notes/{id}   → Function: get-note     ← injects X-Note-Id header
     ├── PUT    /notes/{id}   → Function: update-note  ← injects X-Note-Id header
     └── DELETE /notes/{id}  → Function: delete-note  ← injects X-Note-Id header
                │ (Resource Principal auth)
                ▼
          OCI NoSQL Table: notes
          Shard key: owner (string, always "global")
          Sort key:  id    (string, UUID4)
```

**One image, five functions:** All five OCI Functions share a single Docker image
in OCIR.  A `FUNCTION_TYPE` environment variable (set per-function in Terraform)
routes the FDK `handler()` entry point to the correct CRUD operation at runtime.

**Path parameters:** OCI API Gateway does not automatically forward URL path
parameters to function bodies.  For routes with `{id}`, the deployment spec
injects `${request.path[id]}` as the `X-Note-Id` request header before invoking
the function.  The function reads it from `ctx.Headers().get("x-note-id")`.

---

## Repository Layout

```
01-functions/
  code/
    func.py           All five CRUD handlers; dispatches via FUNCTION_TYPE env var
    requirements.txt  fdk + oci Python packages
    Dockerfile        fnproject/python:3.11 multi-stage build
  main.tf             OCI provider, variables
  network.tf          VCN, public subnet, internet gateway, security list
  nosql.tf            OCI NoSQL table (owner shard key + id sort key)
  registry.tf         OCIR repo; null_resource builds and pushes Docker image
  functions.tf        Functions Application + 5 Function resources
  api.tf              API Gateway + deployment (routes, CORS, header transforms)
  iam.tf              Dynamic Group + policies for Functions→NoSQL and API GW→Functions
  outputs.tf          api_gateway_endpoint, ocir_image_path
02-webapp/
  index.html.tmpl     Web UI template — API_BASE injected at deploy time
  favicon.ico
  main.tf             OCI provider, variables
  storage.tf          Object Storage bucket (public) + object uploads
check_env.sh          Pre-flight: verify tools, env vars, OCI CLI connection
apply.sh              Full deployment (both phases + validation)
destroy.sh            Teardown in reverse order; purges OCIR images first
validate.sh           End-to-end CRUD smoke test via curl
```

---

## Prerequisites

- `oci`, `terraform`, `docker`, `jq`, `envsubst` in PATH
- OCI CLI configured (`~/.oci/config` with API key)
- Docker daemon running (for local image build)
- OCI Auth Token created in Console: **Identity → Users → Auth Tokens**

---

## Setup

No environment variables are required.  Everything is derived automatically.

`apply.sh` reads `tenancy`, `region`, and `user` from `~/.oci/config`, fetches
the Object Storage namespace via `oci os ns get`, and creates an OCIR auth token
on the first run via `oci iam auth-token create`.  The token is cached at
`~/.oci/ocir_token` (mode 600) and reused on all subsequent runs.

```bash
# Optional: target a specific compartment (defaults to tenancy root)
export OCI_COMPARTMENT_ID="ocid1.compartment.oc1....."
```

If the cached token is lost or invalidated, delete `~/.oci/ocir_token` and
re-run `apply.sh`.  OCI allows a maximum of 2 auth tokens per user — if
creation fails, delete an old token in the Console under
**Identity → Users → Auth Tokens**.

---

## Deployment

```bash
# Full deploy
./apply.sh

# Teardown
./destroy.sh

# Smoke test only (after deploy)
./validate.sh
```

`apply.sh` runs in two phases:
1. **`check_env.sh`** → validates tools, env vars, OCI CLI credentials
2. **`01-functions`** → `terraform apply` creates VCN, NoSQL, OCIR repo, builds + pushes
   Docker image (via `null_resource`), creates Functions Application + 5 Functions,
   creates API Gateway + deployment, creates Dynamic Group + IAM policies
3. Reads `api_gateway_endpoint` from Terraform output, injects into `index.html.tmpl`
   via `envsubst`
4. **`02-webapp`** → `terraform apply` creates public Object Storage bucket, uploads
   `index.html` and `favicon.ico`
5. **`validate.sh`** → creates, lists, gets, updates, and deletes 5 test notes

---

## Terraform Modules

### 01-functions
- `oci_core_vcn` + `oci_core_subnet` + `oci_core_internet_gateway` — public VCN for Functions and API Gateway
- `oci_nosql_table` `notes` — composite PK: SHARD(owner) + id
- `oci_artifacts_container_repository` `notes-functions` — OCIR private repo
- `null_resource` `build_push` — `docker build + login + push` on code changes (content-hash tag)
- `oci_functions_application` `notes-app` — groups all functions under shared VCN subnet
- Five `oci_functions_function` resources — same image, different `FUNCTION_TYPE` config
- `oci_apigateway_gateway` `notes-gateway` — PUBLIC endpoint
- `oci_apigateway_deployment` `notes-api` — 5 routes, CORS, path-param header injection
- `oci_identity_dynamic_group` + two `oci_identity_policy` resources for IAM

### 02-webapp
- `oci_objectstorage_bucket` with `access_type = "ObjectRead"` — public web hosting
- `oci_objectstorage_object` uploads `index.html` (generated) and `favicon.ico`

---

## Function Code

All five handlers are in `01-functions/code/func.py`.  A single `handler()` entry
point dispatches based on `FUNCTION_TYPE`.  Each handler follows the same pattern:

- Read `FUNCTION_TYPE`, `NOSQL_TABLE_NAME`, `COMPARTMENT_ID` from environment
- Use `oci.auth.signers.get_resource_principals_signer()` for auth (no secrets)
- Instantiate `oci.nosql.NosqlClient` with the Resource Principal signer
- For path-param routes: read note ID from `ctx.Headers().get("x-note-id")`
- Perform OCI NoSQL operation (`put_row`, `get_row`, `delete_row`, `query`)
- Return `fdk.response.Response` with JSON body

**OCI NoSQL data model:**
- Table: `notes`
- Shard key: `owner` (always `"global"` — hardcoded, no auth)
- Sort key: `id` (UUID4)
- Fields: `owner`, `id`, `title`, `note`, `created_at`, `updated_at`

**OCI NoSQL key format for get_row / delete_row:**
```python
key = [f"owner:{OWNER}", f"id:{note_id}"]  # fieldname:value pairs
```

---

## Test Manually

```bash
BASE=$(cd 01-functions && terraform output -raw api_gateway_endpoint)

# Create
curl -X POST "$BASE/notes" -H "Content-Type: application/json" \
  -d '{"title":"Hello","note":"World"}'

# List
curl "$BASE/notes"

# Get / Update / Delete (replace {id})
curl "$BASE/notes/{id}"
curl -X PUT "$BASE/notes/{id}" -H "Content-Type: application/json" \
  -d '{"title":"Updated","note":"Body"}'
curl -X DELETE "$BASE/notes/{id}"
```

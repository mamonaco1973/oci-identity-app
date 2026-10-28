# Authenticated CRUD API on OCI: IAM Identity Domains, API Gateway, Functions and NoSQL

The [oci-crud-example](https://github.com/mamonaco1973/oci-crud-example)
notes API with sign-in added. Users sign in to an **OCI IAM identity
domain** (authorization code with PKCE), an **API Gateway** validates their
token on every route before any **OCI Function** runs, and each user's notes
are kept separate in **OCI NoSQL** by their user ID. A single-page web app on
a public **Object Storage** bucket handles the sign-in and calls the API.

| Piece | Where | Role |
|---|---|---|
| **notes-app** | IAM identity domain, External User tier | created by `setup_domain.sh`; public signing certificate for the JWKS; self-registration profile `spa-signup`; Terraform adds the public SPA app `notes-spa` (authorization code and refresh token grants) |
| **notes-gateway** / **notes-api** | API Gateway, public | `JWT_AUTHENTICATION` on every route, checked against the domain's `/admin/v1/SigningCert/jwk` keys (issuer `https://identity.oraclecloud.com/`, audience the SPA app); anonymous access off; forwards the `Authorization` header and passes `{id}` as `X-Note-Id` |
| **notes-app** | OCI Functions | `create-note`, `list-notes`, `get-note`, `update-note`, `delete-note`, all one image chosen by `FUNCTION_TYPE`; resource principal for NoSQL |
| **notes** | OCI NoSQL | table keyed on `SHARD(owner), id`, where `owner` is the token's `sub` |
| **notes-functions** | OCIR | private repository for the image |
| **notes-web-&lt;hex&gt;** | Object Storage | public-read bucket with `index.html`, `callback.html` and `favicon.ico` |
| **notes-vcn** | VCN | one public subnet for the gateway and functions |

## Architecture

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="architecture-dark.svg">
  <img alt="A browser loads the single-page app from a public Object Storage bucket and signs in to the notes-app OCI IAM identity domain with the authorization code flow and PKCE. It calls notes-gateway, an API Gateway that validates the ID token against the domain's JWKS on every route and forwards the Authorization header, from which the functions read the verified sub claim. Each of the five routes invokes its own OCI Function, all running the same image from the private OCIR repository, which use a resource principal to read and write the caller's rows in the notes NoSQL table, sharded on the owner." src="architecture-light.svg">
</picture>

Regenerate with `python3 make_diagram.py`.

- **`setup_domain.sh`** / **`delete_domain.sh`**: create and remove the
  identity domain, its signing certificate setting and sign-up profile,
  outside Terraform.
- **`01-ocir/`**: the container repository.
- **`02-docker/`**: `build.sh` and the functions code in `code/`.
- **`03-functions/`**: the network, functions, gateway (`api.tf`), table,
  web bucket, the SPA app in the domain (`identity.tf`), logging and IAM.
- **`04-webapp/`**: `index.html.tmpl` and `callback.html`.

## How a request is authorized

1. The page sends the user to the domain's sign-in page with a PKCE
   challenge; `callback.html` exchanges the code for tokens.
2. Every API call sends the ID token as `Authorization: Bearer <token>`.
3. The gateway checks its signature, issuer and audience against the
   domain's JWKS and rejects anything else with `401` before a function
   runs.
4. The gateway forwards the verified `Authorization` header; the function
   decodes the token's `sub` claim and uses it as the NoSQL shard key, so
   users only see their own notes. (Injecting `${request.auth[sub]}` as a
   header doesn't resolve under `JWT_AUTHENTICATION`, so it isn't used.)

## API

Every route needs a valid ID token from the domain.

| Method | Path | Function | Returns |
|---|---|---|---|
| POST | `/notes` | `create-note` | `201` `{id, title, note}`; `400` if `title` or `note` is missing |
| GET | `/notes` | `list-notes` | `{"items": [...]}` for this user |
| GET | `/notes/{id}` | `get-note` | the note, or `404` |
| PUT | `/notes/{id}` | `update-note` | the updated note, or `404` |
| DELETE | `/notes/{id}` | `delete-note` | `{"message": "Note deleted"}`, or `404` |

## Prerequisites

* [An OCI Account](https://cloud.oracle.com/)
* [Install OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm),
  configured with a `DEFAULT` profile in `~/.oci/config`
* [Install Terraform](https://developer.hashicorp.com/terraform/install)
* [Install Docker](https://docs.docker.com/engine/install/)
* [Install jq](https://jqlang.github.io/jq/download/) and `envsubst`

Your user needs to create identity domains, policies and dynamic groups.
Set `OCI_COMPARTMENT_ID` to deploy into a compartment; otherwise everything
goes into the root compartment.

## Deploy

```bash
git clone https://github.com/mamonaco1973/oci-identity-app.git
cd oci-identity-app
./apply.sh
```

`apply.sh` runs `check_env.sh`, then `setup_domain.sh`, which is idempotent
and needs no console clicks:

1. Creates the External User domain (`notes-app`) if it doesn't exist and
   waits for it to become active.
2. Turns on **Access Signing Certificate** so API Gateway can read the JWKS
   (without it every authenticated call fails with a 500).
3. Creates and activates the `spa-signup` self-registration profile.
4. Writes `env.sh` (`OCI_DOMAIN_NAME`, `OCI_SIGNUP_PROFILE_NAME`), which the
   scripts source. Set those variables first to use other names.

It then creates the OCIR repository, builds and pushes the image (with an
OCIR auth token cached in `~/.oci/ocir_token`), applies `03-functions`, and
uploads the web app. It ends by running `validate.sh`, which checks that
unauthenticated calls are rejected and prints the URLs.

## Try it

1. Open the web URL and choose **Sign in**; on the domain's sign-in page,
   create an account.
2. Add, edit and delete notes. Sign in as a second user to see that each
   account has its own notes.
3. Call the API without a token and the gateway returns `401`.

## Teardown

```bash
./destroy.sh          # 1. remove the Terraform resources and images
./delete_domain.sh    # 2. deactivate and delete the domain, remove env.sh
```

External User domains bill per monthly active user, so delete the domain
when you're done.

## Notes

- **Lab only.** Anyone can create an account through the sign-up profile.
- `destroy.sh` lists images with only `--compartment-id`, so it deletes
  **every** container image in the compartment, not just `notes-functions`.
- `out.log` is committed: a captured deploy log that includes the tenancy
  OCID and the identity domain URL. `02-docker/.build_output` is committed
  too, with an image path from an earlier build.
- `webapp.png` is the same screenshot as oci-crud-example's (no sign-in
  shown), so it isn't used here.

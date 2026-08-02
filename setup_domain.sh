#!/bin/bash
# ==============================================================================
# File: setup_domain.sh
#
# One-time bootstrap for the identity domain that backs the Notes SPA.  Terraform
# can't cleanly create/destroy identity domains, so this lives OUTSIDE apply.sh /
# destroy.sh and is run by hand once.  It is idempotent — re-running is safe.
#
# It performs everything the domain needs:
#   1. Create an External User domain (self-registration requires this tier) and
#      WAIT for it to become ACTIVE.  (Skipped if the domain already exists.)
#   2. Enable "Access Signing Certificate" so API Gateway can read the JWKS
#      anonymously — without this every authenticated call 500s.
#   3. Create + activate a self-registration profile (immediate sign-in, no email
#      activation) so users can create their own accounts.
#   4. Write env.sh so ./apply.sh targets this domain automatically.
#
# Overridable via env vars (or a pre-existing env.sh):
#   OCI_DOMAIN_NAME          domain display name          (default: notes-app)
#   OCI_SIGNUP_PROFILE_NAME  self-registration profile    (default: spa-signup)
#   OCI_LICENSE_TYPE         domain license type          (default: external-user)
#   OCI_COMPARTMENT_ID       target compartment           (default: tenancy root)
#
# Domain DELETION stays manual (deactivate + delete in the console) — by design.
# ==============================================================================

set -euo pipefail

# Allow a pre-existing env.sh to preseed the names (gitignored).
if [ -f env.sh ]; then source env.sh; fi

DOMAIN_NAME="${OCI_DOMAIN_NAME:-notes-app}"
PROFILE_NAME="${OCI_SIGNUP_PROFILE_NAME:-spa-signup}"
LICENSE_TYPE="${OCI_LICENSE_TYPE:-external-user}"
SIGNUP_LINK_TEXT="Create an account"

# ------------------------------------------------------------------------------
# Derive OCI identifiers from ~/.oci/config
# ------------------------------------------------------------------------------
TENANCY_OCID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
REGION=$(awk -F'=' '/^region[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
COMPARTMENT_ID="${OCI_COMPARTMENT_ID:-$TENANCY_OCID}"

echo "NOTE: Domain      - ${DOMAIN_NAME} (${LICENSE_TYPE})"
echo "NOTE: Region      - ${REGION}"
echo "NOTE: Compartment - ${COMPARTMENT_ID}"

# ------------------------------------------------------------------------------
# 1. Find or create the identity domain (wait for ACTIVE)
# ------------------------------------------------------------------------------
find_domain_id() {
  oci iam domain list \
    --compartment-id "${COMPARTMENT_ID}" \
    --all \
    --query "data[?\"display-name\"=='${DOMAIN_NAME}'].id | [0]" \
    --raw-output 2>/dev/null || echo ""
}

DOMAIN_ID="$(find_domain_id)"

if [ -n "${DOMAIN_ID}" ] && [ "${DOMAIN_ID}" != "null" ]; then
  echo "NOTE: Domain '${DOMAIN_NAME}' already exists — skipping create."
else
  echo "NOTE: Creating domain '${DOMAIN_NAME}' (this takes a few minutes)..."
  # No admin_* args => no admin user is created (the creating principal manages
  # it).  --wait-for-state blocks until the domain is ACTIVE.
  oci iam domain create \
    --compartment-id "${COMPARTMENT_ID}" \
    --display-name "${DOMAIN_NAME}" \
    --description "Self-service registration domain for the Notes SPA" \
    --home-region "${REGION}" \
    --license-type "${LICENSE_TYPE}" \
    --wait-for-state SUCCEEDED \
    --max-wait-seconds 1800 \
    < /dev/null

  DOMAIN_ID="$(find_domain_id)"
  if [ -z "${DOMAIN_ID}" ] || [ "${DOMAIN_ID}" = "null" ]; then
    echo "ERROR: Domain created but could not be looked up by name. Check the console."
    exit 1
  fi

  # Data-plane (SCIM /admin/v1) can lag a bit behind ACTIVE on a fresh domain.
  echo "NOTE: Waiting 30s for the domain data plane to settle..."
  sleep 30
fi

# The domain's URL is the idcs_endpoint for all SCIM calls; strip any :443 port.
DOMAIN_URL=$(oci iam domain get --domain-id "${DOMAIN_ID}" --query 'data.url' --raw-output)
ENDPOINT="${DOMAIN_URL/:443/}"
echo "NOTE: Domain URL  - ${ENDPOINT}"

# ------------------------------------------------------------------------------
# 2. Enable Access Signing Certificate (anonymous JWKS for API Gateway)
# ------------------------------------------------------------------------------
# Without this the gateway can't fetch signing keys and every authenticated
# request returns 500. Equivalent to the console's Settings -> Edit domain
# settings -> "Configure client access" toggle.
# ------------------------------------------------------------------------------
echo "NOTE: Enabling Access Signing Certificate (public JWKS)..."
# These identity-domains subcommands have no --force; pipe 'y' to auto-confirm
# any interactive prompt (harmless when there isn't one).
echo y | oci identity-domains setting patch \
  --endpoint "${ENDPOINT}" \
  --setting-id "Settings" \
  --schemas '["urn:ietf:params:scim:api:messages:2.0:PatchOp"]' \
  --operations '[{"op":"replace","path":"signingCertPublicAccess","value":true}]' \
  || echo "WARN: Could not set signingCertPublicAccess — enable it in the console if calls 500."

# ------------------------------------------------------------------------------
# 3. Find or create the self-registration profile
# ------------------------------------------------------------------------------
find_profile_id() {
  oci identity-domains self-registration-profiles list \
    --endpoint "${ENDPOINT}" \
    --filter "name eq \"${PROFILE_NAME}\"" \
    --query 'data.resources[0].id' --raw-output 2>/dev/null || echo ""
}

PROFILE_ID="$(find_profile_id)"

if [ -n "${PROFILE_ID}" ] && [ "${PROFILE_ID}" != "null" ]; then
  echo "NOTE: Self-registration profile '${PROFILE_NAME}' already exists."
else
  echo "NOTE: Creating self-registration profile '${PROFILE_NAME}'..."

  # The CLI requires --email-template even though activation email is off (so it
  # never actually sends). Reference any existing template in the domain: prefer
  # a registration-related one, else fall back to the first available.
  EMAIL_TEMPLATE_ID=$(oci identity-domains email-templates list \
    --endpoint "${ENDPOINT}" \
    --query "data.resources[?contains(id, 'egistration')].id | [0]" \
    --raw-output 2>/dev/null || echo "")
  if [ -z "${EMAIL_TEMPLATE_ID}" ] || [ "${EMAIL_TEMPLATE_ID}" = "null" ]; then
    EMAIL_TEMPLATE_ID=$(oci identity-domains email-templates list \
      --endpoint "${ENDPOINT}" \
      --query 'data.resources[0].id' --raw-output 2>/dev/null || echo "")
  fi
  echo "NOTE: Using email template - ${EMAIL_TEMPLATE_ID:-<none found>}"

  # Immediate sign-in (activation-email-required=false), no consent step, and the
  # default consumer attribute set (first/last/email/username/password).
  echo y | oci identity-domains self-registration-profile create \
    --endpoint "${ENDPOINT}" \
    --schemas '["urn:ietf:params:scim:schemas:oracle:idcs:SelfRegistrationProfile"]' \
    --name "${PROFILE_NAME}" \
    --display-name "[{\"value\":\"${SIGNUP_LINK_TEXT}\",\"locale\":\"en-US\",\"default\":true}]" \
    --email-template "{\"value\":\"${EMAIL_TEMPLATE_ID}\"}" \
    --activation-email-required false \
    --consent-text-present false \
    --show-on-login-page true \
    --number-of-days-redirect-url-is-valid 7 \
    --redirect-url "${ENDPOINT}/ui/v1/signin" \
    --user-attributes '[
      {"value":"name.givenName","seqNumber":1},
      {"value":"name.familyName","seqNumber":2},
      {"value":"emails.type","seqNumber":3},
      {"value":"emails.value","seqNumber":4},
      {"value":"emails.primary","seqNumber":5},
      {"value":"userName","seqNumber":6},
      {"value":"password","seqNumber":7}
    ]'

  PROFILE_ID="$(find_profile_id)"
fi

# Ensure it is ACTIVE and shown on the login page (idempotent belt-and-suspenders).
if [ -n "${PROFILE_ID}" ] && [ "${PROFILE_ID}" != "null" ]; then
  echo "NOTE: Activating profile ${PROFILE_ID}..."
  echo y | oci identity-domains self-registration-profile patch \
    --endpoint "${ENDPOINT}" \
    --self-registration-profile-id "${PROFILE_ID}" \
    --schemas '["urn:ietf:params:scim:api:messages:2.0:PatchOp"]' \
    --operations '[{"op":"replace","path":"active","value":true},{"op":"replace","path":"showOnLoginPage","value":true}]' \
    || echo "WARN: Could not patch profile active/showOnLoginPage — activate it in the console."
else
  echo "WARN: Self-registration profile not found after create — 'Create Account' will be hidden."
fi

# ------------------------------------------------------------------------------
# 4. Write env.sh so ./apply.sh targets this domain automatically
# ------------------------------------------------------------------------------
echo "NOTE: Writing env.sh..."
{
  echo "# Generated by setup_domain.sh — safe to edit; gitignored."
  echo "export OCI_DOMAIN_NAME=\"${DOMAIN_NAME}\""
  echo "export OCI_SIGNUP_PROFILE_NAME=\"${PROFILE_NAME}\""
  if [ -n "${OCI_COMPARTMENT_ID:-}" ]; then
    echo "export OCI_COMPARTMENT_ID=\"${OCI_COMPARTMENT_ID}\""
  fi
} > env.sh

echo ""
echo "================================================================================="
echo "  Domain '${DOMAIN_NAME}' is ready."
echo "================================================================================="
echo "  Domain URL : ${ENDPOINT}"
echo "  Profile    : ${PROFILE_NAME} (${PROFILE_ID:-not found})"
echo "  Wrote      : env.sh"
echo ""
echo "  Next:  ./apply.sh      (env.sh is sourced automatically)"
echo "================================================================================="

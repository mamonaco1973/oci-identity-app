#!/bin/bash
# ================================================================================
# File: check_env.sh
#
# Purpose:
#   Pre-flight validation.  Confirms required tools are available and the
#   OCI CLI is configured and reachable.
#
# Required tools: oci, terraform, docker, jq, envsubst
#
# Optional env var:
#   OCI_COMPARTMENT_ID  Defaults to tenancy OCID from ~/.oci/config when unset
# ================================================================================

set -euo pipefail

# Load local, uncommitted overrides (OCI_DOMAIN_NAME, OCI_SIGNUP_PROFILE_NAME,
# OCI_COMPARTMENT_ID, etc.) if an env.sh is present. Gitignored. This also lets
# check_env.sh validate the right domain when run standalone.
if [ -f env.sh ]; then source env.sh; fi

# ------------------------------------------------------------------------------
# Tool checks
# ------------------------------------------------------------------------------

echo "NOTE: Validating required commands in PATH."

commands=("oci" "terraform" "docker" "jq" "envsubst")

for cmd in "${commands[@]}"; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: ${cmd}"
    exit 1
  fi
  echo "NOTE: Found required command: ${cmd}"
done

echo "NOTE: All required commands are available."

# ------------------------------------------------------------------------------
# OCI CLI connectivity check
# ------------------------------------------------------------------------------

echo "NOTE: Checking OCI CLI connection."
if ! oci os ns get > /dev/null 2>&1; then
  echo "ERROR: Failed to connect to OCI. Check your ~/.oci/config."
  exit 1
fi

echo "NOTE: OCI CLI authentication successful."

# ------------------------------------------------------------------------------
# Identity domain check
# ------------------------------------------------------------------------------
# The SPA app + JWT validation target the domain named by OCI_DOMAIN_NAME
# (defaults to "Default").  Confirm that domain actually exists before Terraform
# tries to look it up — catches typos and the "forgot to export it" case, which
# would otherwise silently deploy into the wrong (Default) domain.
# ------------------------------------------------------------------------------

# OCI_DOMAIN_NAME is REQUIRED — no silent fallback to the Default domain, which
# would deploy into the wrong place (and can't do self-registration).
if [ -z "${OCI_DOMAIN_NAME:-}" ]; then
  echo "ERROR: OCI_DOMAIN_NAME is not set."
  echo "ERROR: Export the identity domain to deploy into, e.g.:"
  echo "ERROR:   export OCI_DOMAIN_NAME=notes-app"
  exit 1
fi

DOMAIN_NAME="${OCI_DOMAIN_NAME}"
echo "NOTE: Verifying identity domain '${DOMAIN_NAME}' exists..."

# Identity domains are looked up at the tenancy root (matches identity.tf, which
# uses var.tenancy_ocid for the domain data source).
TENANCY_OCID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)

DOMAIN_ID=$(oci iam domain list \
  --compartment-id "${TENANCY_OCID}" \
  --all \
  --query "data[?\"display-name\"=='${DOMAIN_NAME}'].id | [0]" \
  --raw-output 2>/dev/null || echo "")

if [ -z "${DOMAIN_ID}" ] || [ "${DOMAIN_ID}" = "null" ]; then
  echo "ERROR: Identity domain '${DOMAIN_NAME}' not found in the tenancy."
  echo "ERROR: Create it in the console, or set OCI_DOMAIN_NAME to an existing domain."
  exit 1
fi

echo "NOTE: Identity domain '${DOMAIN_NAME}' found (${DOMAIN_ID})."

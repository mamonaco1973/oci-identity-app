#!/bin/bash
# ================================================================================
# File: validate.sh
# ================================================================================
# Purpose:
#   Validates the Notes API by exercising all CRUD endpoints:
#     POST   /notes        (create 5 notes)
#     GET    /notes        (list notes)
#     GET    /notes/{id}   (get note)
#     PUT    /notes/{id}   (update note)
#     DELETE /notes/{id}   (delete note)
#
# Requirements:
#   - oci CLI configured
#   - curl, jq
#   - 01-functions terraform state accessible (for output)
#
# Notes:
#   - Discovers the API Gateway endpoint from Terraform output.
#   - Owner is hardcoded to "global" in function logic.
# ================================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Step 1: Discover API Gateway endpoint
# ------------------------------------------------------------------------------
echo "NOTE: Locating API Gateway endpoint..."

API_BASE=$(cd 03-functions && terraform output -raw api_gateway_endpoint)

echo "NOTE: API Gateway URL - ${API_BASE}"

# ------------------------------------------------------------------------------
# Step 2: Create 5 notes
# ------------------------------------------------------------------------------
echo "NOTE: Creating 5 test notes..."

NOTE_IDS=()

for i in {1..5}; do
  PAYLOAD=$(jq -n \
    --arg title "Test Note ${i}" \
    --arg note  "This is test note ${i}" \
    '{ title: $title, note: $note }')

  RESPONSE=$(curl -s -X POST "${API_BASE}/notes" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}")

  NOTE_ID=$(echo "${RESPONSE}" | jq -r '.id // empty')

  if [[ -z "${NOTE_ID}" ]]; then
    echo "ERROR: Failed to create note ${i}"
    echo "RESPONSE: ${RESPONSE}"
    exit 1
  fi

  NOTE_IDS+=("${NOTE_ID}")
  echo "NOTE: Created note ${i} (id=${NOTE_ID})"
done

# ------------------------------------------------------------------------------
# Step 3: List notes
# ------------------------------------------------------------------------------
echo "NOTE: Listing notes..."

LIST_RESPONSE=$(curl -s "${API_BASE}/notes")
NOTE_COUNT=$(echo "${LIST_RESPONSE}" | jq '.items | length')

if [[ "${NOTE_COUNT}" -lt 5 ]]; then
  echo "ERROR: Expected at least 5 notes, got ${NOTE_COUNT}"
  exit 1
fi

echo "NOTE: List endpoint returned ${NOTE_COUNT} notes"

# ------------------------------------------------------------------------------
# Step 4: Get each note by ID
# ------------------------------------------------------------------------------
echo "NOTE: Fetching each created note..."

for ID in "${NOTE_IDS[@]}"; do
  GET_RESPONSE=$(curl -s "${API_BASE}/notes/${ID}")
  TITLE=$(echo "${GET_RESPONSE}" | jq -r '.title // empty')

  if [[ -z "${TITLE}" ]]; then
    echo "ERROR: Failed to fetch note ${ID}"
    echo "RESPONSE: ${GET_RESPONSE}"
    exit 1
  fi

  echo "NOTE: Retrieved note ${ID} (${TITLE})"
done

# ------------------------------------------------------------------------------
# Step 5: Update each note
# ------------------------------------------------------------------------------
echo "NOTE: Updating each note..."

for ID in "${NOTE_IDS[@]}"; do
  CURRENT=$(curl -s "${API_BASE}/notes/${ID}")
  TITLE=$(echo "${CURRENT}" | jq -r '.title // empty')

  if [[ -z "${TITLE}" ]]; then
    echo "ERROR: Failed to fetch existing note ${ID}"
    exit 1
  fi

  UPDATE_PAYLOAD=$(jq -n \
    --arg title "${TITLE}" \
    --arg note  "Updated note for ${ID}" \
    '{ title: $title, note: $note }')

  UPDATE_RESPONSE=$(curl -s -X PUT "${API_BASE}/notes/${ID}" \
    -H "Content-Type: application/json" \
    -d "${UPDATE_PAYLOAD}")

  UPDATED_TITLE=$(echo "${UPDATE_RESPONSE}" | jq -r '.title // empty')

  if [[ -z "${UPDATED_TITLE}" ]]; then
    echo "ERROR: Failed to update note ${ID}"
    echo "RESPONSE: ${UPDATE_RESPONSE}"
    exit 1
  fi

  echo "NOTE: Updated note ${ID}"
done

# ------------------------------------------------------------------------------
# Step 6: Delete each note
# ------------------------------------------------------------------------------
echo "NOTE: Deleting each note..."

for ID in "${NOTE_IDS[@]}"; do
  curl -s -X DELETE "${API_BASE}/notes/${ID}" > /dev/null
  echo "NOTE: Deleted note ${ID}"
done

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------

WEBAPP_URL=$(cd 04-webapp && terraform output -raw website_url 2>/dev/null || echo "N/A")

echo ""
echo "================================================================================="
echo "  Deployment validated!"
echo "================================================================================="
echo "  API : ${API_BASE}"
echo "  Web : ${WEBAPP_URL}"
echo "================================================================================="

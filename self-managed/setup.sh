#!/usr/bin/env bash
#
# Blast Self-Managed Integration Setup
#
# This script creates a service principal in your Azure tenant with the
# permissions Blast needs for audit log collection and resource inventory.
#
# What it does:
#   1. Creates an App Registration in your Entra ID tenant
#   2. Creates a client secret (24-month expiration)
#   3. Grants Graph API permissions (AuditLog.Read.All + Directory.Read.All)
#   4. Grants admin consent for those permissions
#   5. Assigns the Reader role on your subscription(s) or management group
#
# Prerequisites:
#   - Azure CLI (az) installed and logged in
#   - You must be a Global Administrator or Privileged Role Administrator (for Graph API consent)
#   - You must be an Owner or User Access Administrator on the target scope (for RBAC)
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh
#
# The script will prompt you for the RBAC scope. At the end, it outputs
# the credentials to share with Blast.
#

set -euo pipefail

# --- Constants ---
APP_NAME="blast-collector"
SECRET_DESCRIPTION="blast-collector-secret"
SECRET_EXPIRY_YEARS=2
GRAPH_API_ID="00000003-0000-0000-c000-000000000000"  # Microsoft Graph
AUDIT_LOG_READ_ALL="b0afded3-3588-46d8-8b3d-9842eff778da"
DIRECTORY_READ_ALL="7ab1d382-f21e-4acd-a863-ba3e13f7da61"
READER_ROLE_ID="acdd72a7-3385-48ef-bd42-f606fba81ae7"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_step()  { echo -e "\n${CYAN}${BOLD}[$1/5]${NC} ${BOLD}$2${NC}"; }
print_ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
print_warn()  { echo -e "  ${YELLOW}!${NC} $1"; }
print_error() { echo -e "  ${RED}✗${NC} $1"; }
print_info()  { echo -e "  $1"; }

# --- Preflight checks ---
echo -e "${BOLD}Blast Self-Managed Integration Setup${NC}"
echo "────────────────────────────────────────────────"

# Check az CLI
if ! command -v az &> /dev/null; then
    print_error "Azure CLI (az) is not installed."
    echo "  Install it: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

# Check logged in
if ! az account show &> /dev/null 2>&1; then
    print_error "Not logged in to Azure CLI. Run 'az login' first."
    exit 1
fi

TENANT_ID=$(az account show --query tenantId -o tsv)
TENANT_NAME=$(az account show --query tenantDisplayName -o tsv 2>/dev/null || echo "unknown")
CURRENT_USER=$(az account show --query user.name -o tsv)

echo -e "\n  Tenant:  ${BOLD}${TENANT_NAME}${NC} (${TENANT_ID})"
echo -e "  User:    ${BOLD}${CURRENT_USER}${NC}"
echo ""

read -p "  Continue with this tenant? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

# --- Step 1: Create App Registration ---
print_step 1 "Creating App Registration"

# Check if app already exists
EXISTING_APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_APP_ID" && "$EXISTING_APP_ID" != "None" ]]; then
    print_warn "App registration '${APP_NAME}' already exists (Client ID: ${EXISTING_APP_ID})"
    read -p "  Use existing app? (y/n): " USE_EXISTING
    if [[ "$USE_EXISTING" == "y" || "$USE_EXISTING" == "Y" ]]; then
        CLIENT_ID="$EXISTING_APP_ID"
        print_ok "Using existing app registration: ${CLIENT_ID}"
    else
        print_error "Aborted. Delete the existing app first or choose a different name."
        exit 1
    fi
else
    CLIENT_ID=$(az ad app create \
        --display-name "$APP_NAME" \
        --sign-in-audience "AzureADMyOrg" \
        --query appId -o tsv)
    print_ok "Created app registration: ${CLIENT_ID}"
fi

# Ensure service principal exists
SP_OBJECT_ID=$(az ad sp show --id "$CLIENT_ID" --query id -o tsv 2>/dev/null || true)

if [[ -z "$SP_OBJECT_ID" || "$SP_OBJECT_ID" == "None" ]]; then
    SP_OBJECT_ID=$(az ad sp create --id "$CLIENT_ID" --query id -o tsv)
    print_ok "Created service principal: ${SP_OBJECT_ID}"
else
    print_ok "Service principal already exists: ${SP_OBJECT_ID}"
fi

# --- Step 2: Create Client Secret ---
print_step 2 "Creating Client Secret"

# Calculate expiry date
if date -v +${SECRET_EXPIRY_YEARS}y &> /dev/null 2>&1; then
    # macOS
    SECRET_END_DATE=$(date -v +${SECRET_EXPIRY_YEARS}y -u +"%Y-%m-%dT%H:%M:%SZ")
else
    # Linux / Cloud Shell
    SECRET_END_DATE=$(date -u -d "+${SECRET_EXPIRY_YEARS} years" +"%Y-%m-%dT%H:%M:%SZ")
fi

SECRET_JSON=$(az ad app credential reset \
    --id "$CLIENT_ID" \
    --display-name "$SECRET_DESCRIPTION" \
    --end-date "$SECRET_END_DATE" \
    --query "{password: password}" -o json)

CLIENT_SECRET=$(echo "$SECRET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])" 2>/dev/null \
    || echo "$SECRET_JSON" | jq -r '.password')

if [[ -z "$CLIENT_SECRET" || "$CLIENT_SECRET" == "null" ]]; then
    print_error "Failed to create client secret."
    exit 1
fi

print_ok "Created client secret (expires: ${SECRET_END_DATE})"

# --- Step 3: Grant Graph API Permissions ---
print_step 3 "Granting Graph API Permissions"

# Add AuditLog.Read.All
az ad app permission add \
    --id "$CLIENT_ID" \
    --api "$GRAPH_API_ID" \
    --api-permissions "${AUDIT_LOG_READ_ALL}=Role" \
    2>/dev/null || true
print_ok "Added AuditLog.Read.All"

# Add Directory.Read.All
az ad app permission add \
    --id "$CLIENT_ID" \
    --api "$GRAPH_API_ID" \
    --api-permissions "${DIRECTORY_READ_ALL}=Role" \
    2>/dev/null || true
print_ok "Added Directory.Read.All"

# --- Step 4: Grant Admin Consent ---
print_step 4 "Granting Admin Consent"

# Wait briefly for permissions to propagate
print_info "Waiting for permissions to propagate..."
sleep 5

# Grant admin consent
if az ad app permission admin-consent --id "$CLIENT_ID" 2>/dev/null; then
    print_ok "Admin consent granted"
else
    print_warn "Automatic admin consent failed. This can happen if permissions haven't propagated yet."
    print_info "Retrying in 10 seconds..."
    sleep 10
    if az ad app permission admin-consent --id "$CLIENT_ID" 2>/dev/null; then
        print_ok "Admin consent granted (retry succeeded)"
    else
        print_warn "Admin consent could not be granted automatically."
        print_info "Please grant consent manually:"
        print_info "  Azure Portal > Entra ID > App registrations > ${APP_NAME} > API permissions > Grant admin consent"
        print_info ""
        read -p "  Press Enter once you've granted consent manually (or 's' to skip)... " CONSENT_INPUT
        if [[ "$CONSENT_INPUT" == "s" || "$CONSENT_INPUT" == "S" ]]; then
            print_warn "Skipped admin consent — remember to grant it before using the integration"
        fi
    fi
fi

# --- Step 5: Assign Reader Role ---
print_step 5 "Assigning Reader Role (RBAC)"

echo ""
echo "  Choose the scope for the Reader role:"
echo ""
echo "  1) Management group (recommended — covers all child subscriptions)"
echo "  2) Specific subscription(s)"
echo "  3) Skip (assign later)"
echo ""
read -p "  Enter choice (1/2/3): " RBAC_CHOICE

case "$RBAC_CHOICE" in
    1)
        # List management groups
        echo ""
        print_info "Available management groups:"
        echo ""
        az account management-group list --query "[].{Name:name, DisplayName:displayName}" -o table 2>/dev/null || true
        echo ""
        read -p "  Enter Management Group ID (name column): " MG_ID

        if [[ -z "$MG_ID" ]]; then
            print_error "No management group ID provided."
            exit 1
        fi

        SCOPE="/providers/Microsoft.Management/managementGroups/${MG_ID}"
        az role assignment create \
            --assignee "$CLIENT_ID" \
            --role "$READER_ROLE_ID" \
            --scope "$SCOPE" \
            --output none 2>/dev/null

        print_ok "Reader role assigned on management group: ${MG_ID}"
        ;;
    2)
        # List subscriptions
        echo ""
        print_info "Available subscriptions:"
        echo ""
        az account list --query "[].{Name:name, SubscriptionId:id, State:state}" -o table
        echo ""
        read -p "  Enter subscription ID(s), comma-separated: " SUB_IDS_INPUT

        IFS=',' read -ra SUB_IDS <<< "$SUB_IDS_INPUT"
        for SUB_ID in "${SUB_IDS[@]}"; do
            SUB_ID=$(echo "$SUB_ID" | xargs)  # trim whitespace
            if [[ -z "$SUB_ID" ]]; then continue; fi

            az role assignment create \
                --assignee "$CLIENT_ID" \
                --role "$READER_ROLE_ID" \
                --subscription "$SUB_ID" \
                --output none 2>/dev/null

            print_ok "Reader role assigned on subscription: ${SUB_ID}"
        done
        ;;
    3)
        print_warn "Skipped RBAC assignment — remember to assign Reader role before using the integration"
        print_info "Command: az role assignment create --assignee ${CLIENT_ID} --role Reader --subscription <SUBSCRIPTION_ID>"
        ;;
    *)
        print_warn "Invalid choice — skipping RBAC assignment"
        ;;
esac

# --- Output ---
echo ""
echo "────────────────────────────────────────────────"
echo -e "${GREEN}${BOLD}Setup complete!${NC}"
echo "────────────────────────────────────────────────"
echo ""
echo -e "${BOLD}Share the following credentials with Blast:${NC}"
echo ""
echo "  Tenant ID:     ${TENANT_ID}"
echo "  Client ID:     ${CLIENT_ID}"
echo "  Client Secret: ${CLIENT_SECRET}"
echo ""
echo -e "${YELLOW}${BOLD}Important:${NC}"
echo "  - Save the Client Secret now — it cannot be retrieved later"
echo "  - The secret expires on ${SECRET_END_DATE}"
echo "  - Share these values securely (not via plain email)"
echo ""
echo -e "${BOLD}What was configured:${NC}"
echo "  App Registration:    ${APP_NAME}"
echo "  Graph API Permissions: AuditLog.Read.All, Directory.Read.All"
echo "  RBAC Role:           Reader"
echo ""
echo -e "${BOLD}To revoke access later:${NC}"
echo "  Delete the app:   az ad app delete --id ${CLIENT_ID}"
echo "  Remove RBAC only: az role assignment delete --assignee ${CLIENT_ID} --role Reader"
echo ""

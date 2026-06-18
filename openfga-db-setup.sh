#!/bin/bash
# Create the Postgres databases and Vault secrets for OpenFGA and authz-demo.
#
# OpenFGA (infra/openfga) and authz-demo (applications/authz-demo) each need a
# Postgres database on the shared instance running on the haproxy VM
# (192.168.50.10:5432). This script creates the roles + databases and stores
# the credentials in Vault, where External Secrets Operator syncs them into the
# Kubernetes Secrets that the two Deployments mount.
#
# The script is idempotent: re-running it reuses any password already stored in
# Vault (so the database role, the Vault secret, and the running pods stay in
# sync) and only generates a new one the first time.
#
# Prerequisites:
#   - Lab cluster running (haproxy VM with Postgres, Vault unsealed)
#   - multipass and kubectl available and pointed at the lab
#   - openssl, python3 available
#
# Usage:
#   chmod +x openfga-db-setup.sh
#   ./openfga-db-setup.sh

set -euo pipefail

VM="${VM:-haproxy}"

echo "=== Lecture 6: OpenFGA + authz-demo database setup ==="
echo ""

# ---------------------------------------------------------------------------
# Helper: run a SQL statement as the postgres superuser over the local socket
# (peer auth on the haproxy VM - no password needed). Apps connect over TCP
# with their own md5 credentials; admin work is done locally.
# ---------------------------------------------------------------------------
psql_admin() {
  multipass exec "$VM" -- sudo -u postgres psql -tAc "$1" </dev/null
}

# ---------------------------------------------------------------------------
# Helper: read the Vault root token from the unseal secret
# ---------------------------------------------------------------------------
ROOT_TOKEN=$(kubectl -n vault get secret vault-unseal-key \
  -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d 2>/dev/null || true)

if [ -z "$ROOT_TOKEN" ]; then
  echo "ERROR: Could not read the Vault root token."
  echo "  Try: kubectl -n vault get secret vault-unseal-key -o jsonpath='{.data.root-token}' | base64 -d"
  exit 1
fi

# Reuse an existing Vault password if one is already stored, otherwise generate.
vault_password() {
  local path="$1"
  kubectl exec -n vault vault-0 -- sh -c \
    "VAULT_TOKEN=$ROOT_TOKEN vault kv get -field=password $path" 2>/dev/null || true
}

gen_password() {
  openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 24
}

OPENFGA_PASS="${OPENFGA_PASS:-$(vault_password secret/api-security/openfga-db)}"
[ -z "$OPENFGA_PASS" ] && OPENFGA_PASS="$(gen_password)"

AUTHZ_DEMO_PASS="${AUTHZ_DEMO_PASS:-$(vault_password secret/api-security/authz-demo-db)}"
[ -z "$AUTHZ_DEMO_PASS" ] && AUTHZ_DEMO_PASS="$(gen_password)"

# ---------------------------------------------------------------------------
# Step 1: openfga role + database
# ---------------------------------------------------------------------------
echo "=== Step 1: openfga role + database ==="
psql_admin "CREATE ROLE openfga LOGIN PASSWORD '$OPENFGA_PASS';" 2>/dev/null \
  || psql_admin "ALTER ROLE openfga LOGIN PASSWORD '$OPENFGA_PASS';"
psql_admin "CREATE DATABASE openfga OWNER openfga;" 2>/dev/null \
  || echo "  database 'openfga' already exists"
echo "  openfga role + database ready."
echo ""

# ---------------------------------------------------------------------------
# Step 2: authz_demo role + database
# ---------------------------------------------------------------------------
echo "=== Step 2: authz_demo role + database ==="
psql_admin "CREATE ROLE authz_demo LOGIN PASSWORD '$AUTHZ_DEMO_PASS';" 2>/dev/null \
  || psql_admin "ALTER ROLE authz_demo LOGIN PASSWORD '$AUTHZ_DEMO_PASS';"
psql_admin "CREATE DATABASE authz_demo OWNER authz_demo;" 2>/dev/null \
  || echo "  database 'authz_demo' already exists"
echo "  authz_demo role + database ready."
echo ""

# ---------------------------------------------------------------------------
# Step 3: store credentials in Vault
# ---------------------------------------------------------------------------
echo "=== Step 3: store credentials in Vault ==="
kubectl exec -n vault vault-0 -- sh -c \
  "VAULT_TOKEN=$ROOT_TOKEN vault kv put secret/api-security/openfga-db \
   username=openfga password='$OPENFGA_PASS'" >/dev/null
echo "  wrote secret/api-security/openfga-db"

kubectl exec -n vault vault-0 -- sh -c \
  "VAULT_TOKEN=$ROOT_TOKEN vault kv put secret/api-security/authz-demo-db \
   username=authz_demo password='$AUTHZ_DEMO_PASS'" >/dev/null
echo "  wrote secret/api-security/authz-demo-db"
echo ""

# ---------------------------------------------------------------------------
# Step 4: force External Secrets Operator to resync
# ---------------------------------------------------------------------------
echo "=== Step 4: force External Secrets Operator to resync ==="
kubectl -n openfga annotate externalsecret openfga-db-credentials \
  force-sync="$(date +%s)" --overwrite 2>/dev/null \
  || echo "  ExternalSecret 'openfga-db-credentials' not found yet (ArgoCD will create it)"
kubectl -n applications annotate externalsecret authz-demo-db \
  force-sync="$(date +%s)" --overwrite 2>/dev/null \
  || echo "  ExternalSecret 'authz-demo-db' not found yet (ArgoCD will create it)"

echo ""
echo "=== Done ==="
echo ""
echo "If OpenFGA or authz-demo started before the Secret existed, restart them so"
echo "they pick up the database credentials:"
echo "  kubectl -n openfga rollout restart deployment/openfga"
echo "  kubectl -n applications rollout restart deployment/authz-demo"
echo ""
echo "Verify:"
echo "  kubectl -n openfga get pods"
echo "  curl -sk https://openfga.192.168.50.10.nip.io/stores | python3 -m json.tool"
echo "  curl -sk https://authz-demo.192.168.50.10.nip.io/api/health"

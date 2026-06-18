# authz-lab-setup

Setup scripts for the **Lecture 6 authorization lab** (API Security course).

The lecture adds two fine-grained authorization decision points and a demo
backend on top of the existing lab cluster:

- **Keycloak Authorization Services** - the `api-security` realm gets the
  `documents-api` client (resource `Document`, scopes view/edit/delete,
  role-based policies and permissions), the roles
  `document-viewer/editor/admin`, and users `alice`/`bob`.
- **OpenFGA** - a relationship-based (ReBAC) decision point, backed by Postgres.
- **authz-demo** - a Spring Boot service exposing the same documents API two
  ways: `/kc/**` decided by Keycloak, `/fga/**` decided by OpenFGA.

The manifests for OpenFGA and authz-demo ship in
[`kse-labs-deployment`](https://github.com/kse-bd8338bbe006/kse-labs-deployment)
(`infra/openfga/`, `applications/authz-demo/`) and are deployed by ArgoCD. This
repo only holds the two imperative steps that ArgoCD cannot do for you:
creating the Postgres databases and configuring Keycloak Authorization Services.

## Prerequisites

- Local Kubernetes lab running
  ([setup guide](https://github.com/kse-bd8338bbe006/lab-env-setup/blob/main/local-k8s/docs/setup-lab.md))
- `multipass` and `kubectl` available and pointed at the lab cluster
- `curl`, `python3`, `openssl` available
- Keycloak reachable at `https://keycloak.192.168.50.10.nip.io`

## What students need to do

Three steps, in order:

### 1. Sync the deployment repo

Pull the latest `kse-labs-deployment` (it must contain `infra/openfga/` and
`applications/authz-demo/`) and push to your org so ArgoCD deploys them:

```bash
cd kse-labs-deployment
git pull origin main          # or: git fetch upstream && git merge upstream/main
git push origin main
```

OpenFGA and authz-demo will start but stay `CrashLoopBackOff`/`Pending` until
their database credentials exist - that is the next step.

### 2. Create the databases

Creates the `openfga` and `authz_demo` Postgres roles + databases on the
haproxy VM, stores the credentials in Vault, and forces External Secrets
Operator to sync them into Kubernetes:

```bash
./openfga-db-setup.sh
```

If the pods started before the Secret existed, restart them so they pick up the
credentials:

```bash
kubectl -n openfga rollout restart deployment/openfga
kubectl -n applications rollout restart deployment/authz-demo
```

### 3. Configure Keycloak Authorization Services

Adds the realm roles, the `documents-api` client (Authorization Services
enabled), resources, scopes, policies, permissions, and the demo users
`alice`/`bob`. Non-destructive - it uses the Keycloak Admin API and leaves the
rest of the realm untouched:

```bash
./keycloak-authz-setup.sh
```

## Verify

```bash
# OpenFGA up, store reachable
kubectl -n openfga get pods
curl -sk https://openfga.192.168.50.10.nip.io/stores | python3 -m json.tool

# authz-demo healthy
curl -sk https://authz-demo.192.168.50.10.nip.io/api/health

# Keycloak authz configured
KC_URL="https://keycloak.192.168.50.10.nip.io"
ADMIN_TOKEN=$(curl -sk "$KC_URL/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli -d username=admin -d password=admin \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
curl -sk "$KC_URL/admin/realms/api-security/clients?clientId=documents-api" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  | python3 -c "import sys,json; c=json.load(sys.stdin)[0]; print('authz enabled:', c.get('authorizationServicesEnabled'))"
```

## Notes

- Both scripts are **idempotent**. `openfga-db-setup.sh` reuses any password
  already stored in Vault, so re-running keeps the database role, the Vault
  secret, and the running pods in sync. `keycloak-authz-setup.sh` skips objects
  that already exist.
- Admin Postgres work is done over the local socket on the haproxy VM (peer
  auth, no password). The applications connect over TCP (`192.168.50.10:5432`)
  with the generated md5 credentials.
- These scripts are referenced from the API Security course Lecture 6 practice
  (`api-security/lecture6-practice/lecture6-practice.md`).

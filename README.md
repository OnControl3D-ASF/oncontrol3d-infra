# oncontrol3d-infra

Local stack for OnControl 3D: PostgreSQL, Orthanc (PACS + VolView), imaging-service, auth-service and backend.

## Layout

Clone the service repos as siblings of this one:

```
Factories/
├── oncontrol3d-infra/             (this repo)
├── oncontrol3d-backend-clinical/
├── oncontrol3d-auth-service/
├── oncontrol3d-imaging-service/
└── oncontrol3d-frontend/
```

## Prerequisites

Docker (with Compose v2), Node 22, git and the GitHub CLI (`gh`).

```bash
mkdir -p ~/Factories && cd ~/Factories
gh repo clone OnControl3D-ASF/oncontrol3d-infra
gh repo clone OnControl3D-ASF/oncontrol3d-frontend
gh repo clone OnControl3D-ASF/oncontrol3d-backend-clinical
gh repo clone OnControl3D-ASF/oncontrol3d-imaging-service -- -b develop
```

The imaging-service must be on `develop` until release v0.1.0 is merged
into `main` (`main` still has unpinned dependencies).

## Run

```bash
cd ~/Factories/oncontrol3d-infra
printf 'DB_USERNAME=postgres\nDB_PASSWORD=%s\nJWT_SECRET=%s\nAUTH_INTERNAL_TOKEN=%s\nAPP_DATA_SEEDING_ENABLED=true\nSEED_USER_PASSWORD=%s\n' \
  "$(openssl rand -hex 16)" "$(openssl rand -base64 48 | tr -d '\n')" "$(openssl rand -base64 48 | tr -d '\n')" "$(openssl rand -hex 12)" > .env
docker compose up -d --build

cd ../oncontrol3d-frontend
npm ci && npm run dev              # http://localhost:3000
```

| Service         | URL                                   |
| --------------- | ------------------------------------- |
| Frontend        | http://localhost:3000                 |
| Backend API     | http://localhost:8081/swagger-ui.html |
| Auth service    | http://localhost:8082/health          |
| Imaging service | http://localhost:8001/docs            |
| Orthanc         | http://localhost:8042                 |

PostgreSQL and Orthanc are published on `127.0.0.1` only. If you already have a
`postgres-data` volume, it keeps its previous password: reuse that value in `.env`
or recreate the volume with `docker compose down -v`, which deletes its data.

## Auth service

`auth-service` (sibling repo `oncontrol3d-auth-service`, port 8082) is the identity
provider: login, JWT issuance, audit log and internal account provisioning. It uses the
same PostgreSQL server as the backend but its own database `oncontrol_auth`, created by
`postgres/init/10-auth-db.sql`.

| Variable                    | Used by           | Notes |
| --------------------------- | ----------------- | ----- |
| `JWT_SECRET`                | backend + auth    | MUST be identical in both; at least 32 bytes. Generate: `openssl rand -base64 48` |
| `AUTH_INTERNAL_TOKEN`       | backend + auth    | Shared token for `/internal/**` (provisioning); at least 32 bytes. Generate: `openssl rand -base64 48` |
| `AUTH_PROVISIONING_ENABLED` | backend           | Default `false`. Set `true` only when auth-service is healthy: clinical then creates credentials in auth |
| `AUTH_SERVICE_URL`          | backend           | Fixed by compose: `http://auth-service:8082` |

Never commit real values: `.env` is git-ignored. If your existing `.env` predates this
change, append `AUTH_INTERNAL_TOKEN` (compose refuses to start without it).

DB reset is REQUIRED: the init script only runs on a fresh `postgres-data` volume, so
run `docker compose down -v` before the first `up` with auth-service (and again when
the clinical service drops its password columns, change C3b). To keep an existing
volume instead, create the database once:
`docker compose exec postgres psql -U postgres -c 'CREATE DATABASE oncontrol_auth'`.

Verify after `docker compose up -d --build`:

```bash
docker compose ps                                  # auth-service "healthy"
docker compose exec postgres psql -U postgres -lqt | rg oncontrol_auth
curl -s http://localhost:8082/health
```

To route the frontend login through auth, set `AUTH_ORIGIN=http://localhost:8082` in the
frontend `.env.local` (frontend change F1); unset it to fall back to the backend.

## Demo: 3D lung reconstruction

1. Download a public chest CT series (anonymized, from the Orthanc demo server):

   ```bash
   mkdir -p demo-data
   curl -o demo-data/ct-chest-wb.zip \
     https://orthanc.uclouvain.be/demo/series/1de00990-03680ef4-0be6bd5b-73a7d350-fb46abfa/archive
   ```

   Upload a single CT series. The imaging-service segments the series with the
   most slices, so a study that also contains PET series may pick the wrong one.

2. Log in as `dr.garcia@hospital.com` with the `SEED_USER_PASSWORD` value from `.env` (seeded).
3. Pacientes → Juan Pérez → **Tomografía 3D** → **Subir tomografía** → `ct-chest-wb.zip`.
4. **Generar reconstrucción pulmonar 3D** (~30 s the first time, cached afterwards).

## Reset

```bash
docker compose down -v             # drops DB, Orthanc studies and derived volumes
```

## Azure infrastructure (Bicep)

`bicep/` defines the Azure environment as code: ACR, AKS, PostgreSQL Flexible Server,
Service Bus, Function App + Storage, Application Insights and Key Vault, with `dev` and
`prod` parameter files. The `IaC` workflow builds, lints and runs `what-if` on pull requests,
and deploys on `main` behind environment approvals, authenticating to Azure with OIDC.

- Architecture, environments and cost: [docs/iac.md](docs/iac.md)
- Public edge on AKS (Traefik, cert-manager, routing, Orthanc, smoke): [docs/edge.md](docs/edge.md)
- One-time Azure/GitHub setup (OIDC, environments, secrets): [docs/setup-azure-oidc.md](docs/setup-azure-oidc.md)

## Demo en AKS

Ver [deploy/README.md](deploy/README.md) para recrear desde cero el grupo Azure,
ACR y AKS, publicar la app, compartir una URL HTTPS temporal y eliminar los
recursos después de la demo.

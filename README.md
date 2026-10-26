# oncontrol3d-infra

Local stack for OnControl 3D: PostgreSQL, Orthanc (PACS + VolView), imaging-service and backend.

## Layout

Clone the service repos as siblings of this one:

```
Factories/
├── oncontrol3d-infra/             (this repo)
├── oncontrol3d-backend-clinical/
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
printf 'DB_USERNAME=postgres\nDB_PASSWORD=postgres\nJWT_SECRET=%s\n' "$(openssl rand -hex 32)" > .env
docker compose up -d --build

cd ../oncontrol3d-frontend
npm ci && npm run dev              # http://localhost:3000
```

| Service         | URL                                   |
| --------------- | ------------------------------------- |
| Frontend        | http://localhost:3000                 |
| Backend API     | http://localhost:8081/swagger-ui.html |
| Imaging service | http://localhost:8001/docs            |
| Orthanc         | http://localhost:8042                 |

## Demo: 3D lung reconstruction

1. Download a public chest CT series (anonymized, from the Orthanc demo server):

   ```bash
   mkdir -p demo-data
   curl -o demo-data/ct-chest-wb.zip \
     https://orthanc.uclouvain.be/demo/series/1de00990-03680ef4-0be6bd5b-73a7d350-fb46abfa/archive
   ```

   Upload a single CT series. The imaging-service segments the series with the
   most slices, so a study that also contains PET series may pick the wrong one.

2. Log in as `dr.garcia@hospital.com` / `password123` (seeded).
3. Pacientes → Juan Pérez → **Tomografía 3D** → **Subir tomografía** → `ct-chest-wb.zip`.
4. **Generar reconstrucción pulmonar 3D** (~30 s the first time, cached afterwards).

## Reset

```bash
docker compose down -v             # drops DB, Orthanc studies and derived volumes
```

# Terraform EKS + Portable Ingress (NGINX) — Fridge Sales Demo

This project is designed to be:
- **Idempotent**: Terraform creates/updates AWS infra safely (repeatable).
- **Portable**: ingress routing logic lives **inside Kubernetes** (NGINX Ingress), not in AWS ALB-specific config.
- **Easy to operate**: one `.env` file drives everything; one script (`run.sh`) runs infra, deploy, tests.

---

## What you get

A single public entry point (from an AWS LoadBalancer in front of NGINX Ingress):
- UI: `http://<lb-host>/`
- API: `http://<lb-host>/api/stats`

The API loads `data/raw/fridge_sales_with_rating.csv` into PostgreSQL (once) and returns:
- row count
- min/max/avg price
- min/max/avg rating
- sentiment breakdown
- top brands / top stores

---

## Identity: how resources are uniquely marked (IMPORTANT)

Before creating anything, you set:

- `PROJECT_ID` — a unique id like `fridge-stats-demo-001`

This value is used to **avoid name collisions** and to **make cleanup/cost tracking easy**:

### AWS (Terraform)
- All resources get AWS tags (e.g. `ProjectId=...`)
- The **EKS cluster name includes PROJECT_ID**:
  - `CLUSTER_FULL_NAME = <CLUSTER_NAME>-<PROJECT_ID>`

### Kubernetes
- All deployed K8s objects get labels:
  - `project-id=<PROJECT_ID>`
  - `app.kubernetes.io/part-of=fridge-stats`

---

## Prereqs

On your machine:
- `aws`
- `terraform`
- `kubectl`
- `docker`
- `helm`
- `curl`

AWS side:
- An IAM identity with permissions to create VPC/EKS/ECR/IAM resources.

---

## Configure

1) Copy env template:
```bash
cp .env.example .env
```

2) Edit `.env` (minimum required):
- `AWS_REGION`
- `PROJECT_ID`  ✅ (required)
- `CLUSTER_NAME`
- optionally `AWS_PROFILE`

Optional:
- node sizes: `EKS_NODE_*`
- tests timing: `TEST_WAIT_INTERVAL_SECONDS`, `TEST_TIMEOUT_SECONDS`
- force NLB: `INGRESS_NLB=true`

---

## Run commands

### 1) End-to-end (recommended)
Creates infra, deploys app, runs tests:
```bash
./run.sh all
```

### 2) Infra only
```bash
./run.sh infra
```

### 3) Deploy only
Build/push images, install ingress-nginx, apply manifests:
```bash
./run.sh deploy
```

### 4) Test only
Runs smoke tests (with wait/retry):
```bash
./run.sh test
```

### 5) Destroy everything
```bash
./run.sh down
```

---

## Smoke tests

The smoke tests are in:
- `run_scripts/smoke.sh`

They check:
- `GET /api/healthz` becomes ready (wait+retry)
- `GET /api/stats` returns expected keys
- `GET /` contains “Fridge Sales Stats”

Timing is controlled by env vars (defaults):
- `TEST_WAIT_INTERVAL_SECONDS=30`
- `TEST_TIMEOUT_SECONDS=300` (5 mins)

---

## Why this design stays portable (layman version)

- AWS provides a **front door** (a LoadBalancer).
- NGINX Ingress inside Kubernetes is the **traffic director**:
  - `/api/*` → FastAPI
  - `/` → React UI

If you move to GKE/AKS later:
- your app + ingress rules can stay the same
- only the cloud-specific “front door” changes.


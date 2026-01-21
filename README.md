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

---

## Optional: CloudFront + HTTPS (and hardening the public edge)

By default, this project exposes the app via an AWS Network Load Balancer (NLB) in front of ingress‑nginx:
- UI: `http://<nlb-host>/`
- API: `http://<nlb-host>/api/stats`

You can optionally put **CloudFront in front of the NLB** so that:
- Users hit **CloudFront over HTTPS**.
- CloudFront forwards HTTP traffic to the NLB (inside AWS).
- You get better TLS handling, caching, and an easy place to attach WAF.

How it works here:
- Set in `.env`:
  - `ENABLE_CLOUDFRONT=true`
- When you run:
  - `./run.sh deploy` or `./run.sh all`
- The deploy script will:
  - Look up the ingress‑nginx NLB hostname.
  - Ensure a CloudFront distribution exists with that NLB as its origin.
  - Print the CloudFront URL at the end of the deploy.
  - Use that CloudFront URL for smoke tests by default.

**Locking down the edge:**  
This repo does **not** try to fully automate AWS WAF configuration, because that’s usually environment‑specific. The intended pattern is:
- Use this project to create the CloudFront distribution in front of the NLB.
- Then attach a WAF Web ACL (managed rules, custom rules, IP filters, etc.) to the distribution via:
  - Terraform in your own IaC layer, or
  - The AWS Console.

That way:
- Kubernetes manifests and app code stay portable.
- The “public edge” hardening (CloudFront + WAF rules) stays in a small, AWS‑specific layer that you can adjust per environment.


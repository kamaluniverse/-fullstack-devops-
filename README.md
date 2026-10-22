# ProShop — Production-Minded MERN DevSecOps Stack

A full-stack e-commerce application vendored from
[`akx86/mern-ecommerce`](https://github.com/akx86/mern-ecommerce) (pinned at
`d6cf77d43554342a6f9e6993f1a99ed0163a9002`) and rebuilt into a deployable,
observable, CI/CD-driven system.

It runs locally with a single `docker compose up` and in AWS on a custom VPC with
three EC2 hosts, a private-subnet MongoDB, private ECR repositories and a Jenkins
pipeline that tests, builds, pushes and deploys every commit.

> **Live deployment (verified):** <http://100.62.16.189>
> `GET /api/health` → `{"status":"success","db":"connected", ...}`

---

## Table of contents

1. [What is in the box](#what-is-in-the-box)
2. [Architecture](#architecture)
3. [CI/CD pipeline](#cicd-pipeline)
4. [Tech stack](#tech-stack)
5. [Repository layout](#repository-layout)
6. [Quick start (local)](#quick-start-local)
7. [Configuration](#configuration)
8. [Testing and linting](#testing-and-linting)
9. [AWS infrastructure](#aws-infrastructure)
10. [Deploying to AWS](#deploying-to-aws)
11. [Jenkins setup](#jenkins-setup)
12. [Deploy and rollback](#deploy-and-rollback)
13. [DNS and HTTPS](#dns-and-https)
14. [Backups and recovery](#backups-and-recovery)
15. [Security model](#security-model)
16. [Troubleshooting](#troubleshooting)
17. [Cost and cleanup](#cost-and-cleanup)
18. [Known limitations](#known-limitations)

---

## What is in the box

**Application**

- React 19 + Vite SPA (Redux Toolkit, React Query, Tailwind CSS 4, Stripe Elements).
- Node 22 / Express 5 REST API with JWT auth, role-based admin routes, carts,
  orders, dashboard statistics and image uploads.
- MongoDB 7 with authentication enabled and no host-published port.
- Optional Stripe **and** optional Cloudinary. When either is unset the app stays
  fully usable:
  - **No Stripe key** → the backend returns a mock payment intent and the UI shows
    a demo checkout form that places the order without charging a card.
  - **No Cloudinary credentials** → uploads are written to a persistent Docker
    volume and served from `/uploads`.

**Delivery**

- Multi-stage Dockerfiles (non-root Node runtime, Nginx static image).
- Two Nginx layers: a public reverse proxy and an in-container static server.
- Docker Compose variants for local all-in-one and split production hosts.
- `scripts/deploy.sh` with pre-flight validation, health gating, diagnostics and
  image rollback. It never touches database volumes.
- Jenkins declarative pipeline: checkout → install → test → lint → build → push →
  deploy → health check.
- Raw, idempotent AWS CLI provisioning scripts (VPC, NAT, security groups, IAM,
  ECR, EC2) plus a one-command teardown.

**Hardening applied to the vendored code** (real bugs found and fixed, not just
configuration):

| Area | Fix |
| --- | --- |
| Cart | Missing `appError` import and missing `next` parameter caused a crash on out-of-stock; `product.stock` referenced a non-existent field (now `countInStock`); `removeFromCart`/`clearCart` hung when no cart existed |
| Categories | `req.file.path` leaked a container filesystem path into the database; `require('mongoose').mongoose.Types.ObjectId` threw on search |
| Products / users | Upload URLs normalised through a single `fileUrl()` helper for both Cloudinary and local disk |
| Orders | Stripe client constructed at import time crashed the whole API when `STRIPE_SECRET_KEY` was absent — now lazily initialised with a mock fallback |
| Frontend | `ProductCard` called a hook conditionally (React hooks violation); API base URL was hardcoded (now relative `/api`); broken refresh-token interceptor replaced with a correct logout-on-401 flow |
| Server | Bind address, graceful shutdown, `/api/health` with DB readiness, Helmet, rate limiting, 1 MB JSON limit, JSON 404/error handlers |
| Tests | Added Jest/Supertest API tests and Vitest/RTL frontend tests; both wired into CI |

---

## Architecture

### AWS topology

```mermaid
flowchart TB
    user([Internet users]) -->|HTTP :80| eip[Elastic IP<br/>100.62.16.189]

    subgraph vpc["VPC 10.0.0.0/16 (us-east-1)"]
        subgraph pub["Public subnet 10.0.1.0/24"]
            nat[NAT Gateway]
            app["App host (t3.small)<br/>Nginx + React + Express<br/>10.0.1.84"]
            jen["Jenkins host (t3.small)<br/>:8080 admin-only<br/>44.218.251.137"]
        end

        subgraph priv["Private subnet 10.0.2.0/24"]
            mongo[("MongoDB 7<br/>auth enabled<br/>10.0.2.103:27017")]
        end
    end

    eip --> app
    app -->|27017, SG-to-SG only| mongo
    app -->|egress via| nat
    mongo -->|egress via| nat
    jen -->|docker push| ecr[(Amazon ECR<br/>proshop/backend<br/>proshop/frontend)]
    jen -->|SSH deploy :22<br/>SG-to-SG only| app
    jen -->|aws ecr get-login-password| ecr
    iam[IAM: proshop-ec2-role<br/>proshop-jenkins-role] -.-> app
    iam -.-> jen
```

**Traffic rules**

| Path | Source | Destination | Port | Control |
| --- | --- | --- | --- | --- |
| Users → app | `0.0.0.0/0` | app SG | 80, 443 | Security group |
| Admin → app | `54.81.38.205/32` | app SG | 22 | Security group |
| Jenkins → app | Jenkins SG | app SG | 22 | **Source security group** |
| App → Mongo | app SG | Mongo SG | 27017 | **Source security group** |
| Admin → Jenkins | `54.81.38.205/32` | Jenkins SG | 8080, 22 | Security group |
| Mongo → internet | private subnet | NAT gateway | 443 | Route table |

MongoDB has **no public IP** and is unreachable from the internet (verified by a
direct TCP probe to `10.0.2.103:27017`, which fails off-VPC).

### Application request flow

```mermaid
sequenceDiagram
    participant B as Browser
    participant N as Nginx (public)
    participant F as React/Nginx container
    participant A as Express API
    participant M as MongoDB (private)

    B->>N: GET /shop
    N->>F: proxy_pass frontend:80
    F-->>B: index.html (SPA fallback)
    B->>N: GET /api/products
    N->>A: proxy_pass backend:5000
    A->>M: authenticated query
    M-->>A: documents
    A-->>B: JSON
    B->>N: GET /uploads/<file>
    N->>A: proxy_pass backend:5000
    A-->>B: image (local disk volume)
```

---

## CI/CD pipeline

```mermaid
flowchart LR
    dev[git push] --> scm["SCM checkout<br/>(GitHub in production,<br/>local mirror in this lab)"]
    scm --> inst["npm ci<br/>backend + frontend"]
    inst --> test["Jest/Supertest (13)<br/>Vitest/RTL (6)"]
    test --> lint["ESLint<br/>0 errors"]
    lint --> build["docker build<br/>tag = short SHA"]
    build --> push["docker push<br/>ECR private repos"]
    push --> deploy["scp compose files +<br/>ssh deploy.sh"]
    deploy --> health["curl /api/health<br/>db connected"]
    health -->|fail| diag["print container state<br/>+ last 80 log lines"]
    health -->|pass| live([Live])
```

Jenkins job: **`proshop-pipeline`**.

```
Started by user admin
[Checkout] [Install dependencies] [Test] [Lint] [Build images] [Push to ECR]
[Deploy to EC2] [Health check]
Finished: SUCCESS
```

Image tags are the short git SHA (`d316b58`), so every build is traceable to a
commit and every deploy is a specific, pullable artefact.

---

## Tech stack

| Layer | Technology |
| --- | --- |
| Frontend | React 19, Vite 7, Redux Toolkit, TanStack Query, Tailwind CSS 4, Stripe Elements |
| Backend | Node 22, Express 5, Mongoose 9, JWT, Multer, Helmet, express-rate-limit |
| Database | MongoDB 7 (root auth, private network) |
| Web server | Nginx 1.27 (public reverse proxy + static image) |
| Containers | Docker Engine 29, Docker Compose v5 |
| Registry | Amazon ECR (scan-on-push, AES-256) |
| CI/CD | Jenkins 2.580 LTS, declarative pipeline, SSH agent, credentials binding |
| Cloud | Custom VPC, NAT Gateway, 3 × EC2, EIPs, IAM roles, security groups |
| Testing | Jest, Supertest, mongodb-memory-server, Vitest, Testing Library |

---

## Repository layout

```
.
├── backend/                  Express API
│   ├── config/db.js          MONGO_URI / MONGO_URL resolution
│   ├── controllers/          products, categories, cart, orders, users
│   ├── middlewares/          auth, uploads (Cloudinary or local disk), validation
│   ├── scripts/seedAdmin.js  idempotent admin seeding
│   ├── tests/api.test.js     13 Jest + Supertest tests
│   ├── Dockerfile            multi-stage, non-root, healthcheck
│   └── index.js              health endpoint, graceful shutdown
├── frontend/                 React SPA
│   ├── src/services/         relative `/api` axios client, auto-logout on 401
│   ├── src/components/checkout/MockCheckoutForm.jsx
│   ├── src/test/             Vitest + Testing Library tests
│   ├── nginx.conf            SPA fallback + asset caching
│   └── Dockerfile            build stage + nginx runtime
├── nginx/
│   ├── default.conf          public reverse proxy
│   └── default-https.conf.example
├── scripts/
│   ├── deploy.sh             deploy | rollback | status
│   ├── health-check.sh       frontend + API probes
│   ├── bootstrap-app-host.sh fresh Ubuntu → Docker host
│   └── aws/                  idempotent provisioning + teardown
├── jenkins/init.groovy.d/    admin realm, credentials, pipeline job
├── compose.yaml              local all-in-one
├── compose.app.yaml          production app host (no DB)
├── compose.mongo.yaml        production MongoDB host
├── Jenkinsfile               declarative pipeline
└── .env.example              every supported variable
```

---

## Quick start (local)

Requirements: Docker Engine + Compose v2/v5.

```bash
git clone <this repo> fullstack-devops
cd fullstack-devops

cp .env.example .env
# Set at minimum: MONGO_PASSWORD, JWT_SECRET, ADMIN_PASSWORD
# Tip: openssl rand -hex 32

docker compose up -d --build
# or, with health gating and rollback support:
./scripts/deploy.sh

./scripts/health-check.sh
```

Open <http://localhost>.

Seed an administrator (idempotent — promotes the account if it already exists):

```bash
docker compose exec -T backend npm run seed:admin
```

Sign in with `ADMIN_EMAIL` / `ADMIN_PASSWORD` from `.env`.

Useful commands:

```bash
./scripts/deploy.sh status     # container state + health payload
./scripts/deploy.sh rollback   # previous known-good local images
docker compose logs -f backend
docker compose down            # keeps named volumes (data)
```

---

## Configuration

Copy `.env.example` → `.env`. Nothing sensitive is committed: `.env`,
`infra/*.pem` and `infra/aws-outputs.env` are gitignored.

| Variable | Required | Purpose |
| --- | --- | --- |
| `MONGO_USER` / `MONGO_PASSWORD` / `MONGO_DB` | yes | Mongo root credentials and database name |
| `MONGO_URI` | production | Full URI; on the app host it points at the private Mongo IP |
| `JWT_SECRET` | yes | ≥ 32 chars; `openssl rand -hex 32` |
| `ADMIN_EMAIL` / `ADMIN_PASSWORD` / `ADMIN_NAME` | seeding | Admin account used by `seed:admin` |
| `CORS_ORIGIN` | no | Comma-separated allowed origins (defaults to same-origin) |
| `RATE_LIMIT_MAX` | no | Requests per IP per 15 min (default 300) |
| `UPLOAD_DIR` | no | Local upload directory (default `/app/uploads`) |
| `STRIPE_SECRET_KEY` / `VITE_STRIPE_PUBLIC_KEY` | no | Real payments; unset → demo checkout |
| `CLOUDINARY_*` | no | Remote image hosting; unset → local disk |
| `IMAGE_SOURCE` | no | `build` (default) or `ecr` |
| `ECR_REGISTRY` / `ECR_REPO_PREFIX` / `TAG` | ECR only | Registry, repo prefix (`proshop`), image tag |
| `COMPOSE_FILE` | no | `compose.yaml` (local) or `compose.app.yaml` (production) |

> `TAG` supplied by the CI environment takes precedence over the value in `.env`,
> so a pipeline can deploy an arbitrary build without editing server files.

---

## Testing and linting

```bash
# Backend — 13 tests (health, auth, products, cart, 404s) against an in-memory MongoDB
cd backend && npm test

# Frontend — 6 tests (utility, Button, axios base URL)
cd frontend && npm test

# Lint (both exit 0; vendored UI warnings are reported as warnings)
cd backend && npm run lint
cd frontend && npm run lint

# Production bundle
cd frontend && npm run build
```

Test results (also produced inside Jenkins):

```
Backend:  Test Suites: 1 passed, 1 total   Tests: 13 passed, 13 total
Frontend: Test Files:  3 passed (3)        Tests:  6 passed (6)
Lint:     0 errors
```

---

## AWS infrastructure

Everything is created by `scripts/aws/*.sh` (idempotent; re-running is safe).
Outputs are written to `infra/aws-outputs.env` (gitignored).

| Resource | Value |
| --- | --- |
| Region | `us-east-1` |
| VPC | `10.0.0.0/16` |
| Public subnet | `10.0.1.0/24` (app + Jenkins + NAT) |
| Private subnet | `10.0.2.0/24` (MongoDB) |
| AMI | Ubuntu 24.04 LTS (resolved from SSM) |
| App host | `t3.small`, Elastic IP `100.62.16.189`, private `10.0.1.84` |
| Mongo host | `t3.small`, private only `10.0.2.103` |
| Jenkins host | `t3.small` + 2 GB swap, Elastic IP `44.218.251.137` |
| ECR | `273356968252.dkr.ecr.us-east-1.amazonaws.com/proshop/{backend,frontend}` |
| IAM | `proshop-ec2-role` (ECR **read** + SSM), `proshop-jenkins-role` (ECR **push** scoped to the two repos) |
| Admin allow-list | `54.81.38.205/32` for SSH and Jenkins 8080 |

Instance access:

```bash
chmod 600 infra/proshop-key.pem
ssh -i infra/proshop-key.pem ubuntu@100.62.16.189        # app
ssh -i infra/proshop-key.pem ubuntu@44.218.251.137       # jenkins

# Mongo has no public IP; jump through the app host:
KEY=$PWD/infra/proshop-key.pem
ssh -i $KEY -o "ProxyCommand=ssh -i $KEY -W %h:%p ubuntu@100.62.16.189" \
    ubuntu@10.0.2.103
```

### Provision from scratch

```bash
export AWS_REGION=us-east-1
export ADMIN_CIDR="$(curl -s https://checkip.amazonaws.com)/32"

./scripts/aws/01-network.sh          # VPC, subnets, IGW, NAT, routes
./scripts/aws/02-security-groups.sh  # least-privilege SGs
./scripts/aws/03-iam-ecr.sh          # instance role + private ECR repos
./scripts/aws/04-instances.sh        # key pair, 3 EC2, Elastic IPs
./scripts/aws/05-jenkins-iam.sh      # dedicated ECR-push role for Jenkins
```

Wait 2–3 minutes for cloud-init (Docker, Node, Jenkins).

---

## Deploying to AWS

### 1. MongoDB host (private subnet)

```bash
scp compose.mongo.yaml .env ubuntu@<mongo-private-ip>:/opt/proshop/   # via jump host
ssh ubuntu@<mongo-private-ip> 'cd /opt/proshop && docker compose -f compose.mongo.yaml up -d'
```

Result: `mongo:7` healthy, port 27017 bound on the host, reachable only from the
app security group. Data lives in the `proshop_mongo-data` volume.

### 2. Build and push images

```bash
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin \
    273356968252.dkr.ecr.us-east-1.amazonaws.com

TAG=$(git rev-parse --short HEAD)
docker build -t .../proshop/backend:$TAG  ./backend
docker build -t .../proshop/frontend:$TAG ./frontend
docker push .../proshop/backend:$TAG
docker push .../proshop/frontend:$TAG
```

Jenkins does this automatically; the manual path is for bootstrapping.

### 3. App host

```bash
# On the app server (/opt/proshop)
cp .env.example .env     # MONGO_URI=mongodb://user:pass@10.0.2.103:27017/proshop?authSource=admin
                         # IMAGE_SOURCE=ecr, ECR_REGISTRY=..., ECR_REPO_PREFIX=proshop
                         # COMPOSE_FILE=compose.app.yaml, TAG=<sha>

./scripts/deploy.sh      # validates, logs in to ECR, pulls, waits for health
./scripts/health-check.sh
```

The app host authenticates to ECR through its instance profile — no stored AWS
keys.

### 4. Seed the administrator

```bash
cd /opt/proshop
set -a && . ./.env && set +a
export BACKEND_IMAGE="${ECR_REGISTRY}/${ECR_REPO_PREFIX}/backend:${TAG}"
export FRONTEND_IMAGE="${ECR_REGISTRY}/${ECR_REPO_PREFIX}/frontend:${TAG}"
docker compose -f compose.app.yaml exec -T backend npm run seed:admin
```

(The two image variables are required because `compose.app.yaml` uses `:?`
guards to prevent an accidental empty tag.)

---

## Jenkins setup

The host is prepared automatically by `scripts/aws/04-instances.sh`
(Java 21, Docker, Node 22, AWS CLI v2, Jenkins LTS, 2 GB swap).

> **Signing-key note:** the old `jenkins.io-2023.key` expired on 2026-03-26 and
> breaks `apt update`. The scripts use `jenkins.io-2026.key`.

### Automated bootstrap

`jenkins/init.groovy.d/` contains three scripts that Jenkins executes at startup:

| Script | Effect |
| --- | --- |
| `01-security.groovy` | Creates `admin` from `/etc/jenkins-admin-pass`, disables anonymous read, completes the setup wizard |
| `02-credentials.groovy` | Registers `app-ssh-key` (SSH private key) and `ecr-registry` (registry hostname) |
| `03-job.groovy` | Creates the `proshop-pipeline` job from `/etc/jenkins-repo-url` (default `file:///opt/proshop-repo.git`) |

Install them on the Jenkins host:

```bash
sudo install -d -o jenkins -g jenkins /var/lib/jenkins/init.groovy.d
sudo cp jenkins/init.groovy.d/*.groovy /var/lib/jenkins/init.groovy.d/
sudo chown jenkins:jenkins /var/lib/jenkins/init.groovy.d/*.groovy

# Admin password (root-owned; the Jenkins service user must be able to read it)
sudo sh -c 'openssl rand -base64 24 > /etc/jenkins-admin-pass'
sudo chown root:jenkins /etc/jenkins-admin-pass && sudo chmod 640 /etc/jenkins-admin-pass

# Deploy key + registry
sudo install -d -m 700 -o jenkins -g jenkins /var/lib/jenkins/.ssh
sudo install -m 600 -o jenkins -g jenkins infra/proshop-key.pem \
     /var/lib/jenkins/.ssh/proshop-key
echo "273356968252.dkr.ecr.us-east-1.amazonaws.com" | sudo tee /etc/jenkins-ecr-registry

sudo systemctl restart jenkins
```

Plugins (already installed: 57 total): `git`, `workflow-aggregator`,
`credentials-binding`, `ssh-agent` and their dependencies.

Because the lab uses a local mirror, allow local checkouts once:

```bash
sudo mkdir -p /etc/systemd/system/jenkins.service.d
sudo tee /etc/systemd/system/jenkins.service.d/local-git.conf >/dev/null <<'EOF'
[Service]
Environment="JAVA_OPTS=-Djava.awt.headless=true -Dhudson.plugins.git.GitSCM.ALLOW_LOCAL_CHECKOUT=true"
EOF
sudo systemctl daemon-reload && sudo systemctl restart jenkins
```

### Production SCM (GitHub)

The pipeline is a standard declarative Jenkinsfile and expects a normal git SCM.
To switch from the local mirror to GitHub:

1. Create the repository and push this project to `main`.
2. Set the job's SCM URL to `git@github.com:<org>/<repo>.git` (or HTTPS) and the
   branch specifier to `*/main`.
3. Add a GitHub credential in Jenkins and select it in the SCM block.
4. In GitHub → **Settings → Webhooks**, add
   `http://<jenkins-host>:8080/github-webhook/` with content type
   `application/json`, then enable **GitHub hook trigger for GITScm polling**.
5. For private repositories use a deploy key or a GitHub App token — never a
   personal password.

The only lab-specific change is the local repository URL and the
`ALLOW_LOCAL_CHECKOUT` property; neither is needed with GitHub.

### Triggering the job

```bash
curl -u admin:<password> -c cookies \
  "http://<jenkins>:8080/crumbIssuer/api/json"
# then POST with the returned crumb header:
curl -b cookies -u admin:<password> -H "Jenkins-Crumb: <crumb>" \
  -X POST "http://<jenkins>:8080/job/proshop-pipeline/buildWithParameters\
?APP_HOST_OVERRIDE=10.0.1.84"
```

`buildWithParameters` is used because declarative parameters only exist after the
first parse. `APP_HOST_OVERRIDE` defaults to the app host's **private** IP: from
inside the VPC the public Elastic IP does not hairpin, and private traffic is
cheaper and never leaves the VPC.

---

## Deploy and rollback

`scripts/deploy.sh` is the single entry point on any host.

```bash
./scripts/deploy.sh            # validate → build/pull → up → health gate
./scripts/deploy.sh rollback   # previous known-good images
./scripts/deploy.sh status     # containers + live health payload
```

Behaviour:

- Refuses to run with a missing or placeholder `JWT_SECRET` / `MONGO_PASSWORD`,
  or a `JWT_SECRET` shorter than 32 characters.
- Runs `docker compose config` before touching anything.
- On ECR mode, logs in with the instance role.
- Waits for `/api/health` to report `"db":"connected"` (up to 200 s).
- On failure prints `docker compose ps` and the last 80 log lines per service.
- Records `.last-good-image` / `.previous-image` **outside git**.
- **Never** runs `down -v`; MongoDB and upload volumes survive every deploy.

Rollback is a real image rollback, verified on EC2: `651039b → d316b58`, then
rollback to `651039b`, then redeploy `d316b58`, each with a passing health check.

---

## DNS and HTTPS

The current stack serves HTTP on the Elastic IP. HTTPS is **not** enabled because
no domain is attached — see `nginx/default-https.conf.example` for the complete
configuration.

To enable it:

1. Point an `A` record (e.g. `shop.example.com`) at the app Elastic IP.
2. Issue certificates on the app host:
   ```bash
   sudo apt-get install -y certbot
   sudo certbot certonly --standalone -d shop.example.com
   ```
3. Mount `nginx/default-https.conf` (copy the example, replace `example.com`) and
   `/etc/letsencrypt` into the Nginx container, and publish `443:443`.
4. Open 443 in the app security group (already allowed by the provisioning
   script).
5. Redirect 80 → 443 (the example includes the redirect and HSTS).
6. Renew with a cron/systemd timer:
   `sudo certbot renew --deploy-hook "cd /opt/proshop && ./scripts/deploy.sh"`.

Until these steps are completed, HTTPS genuinely does not work.

---

## Backups and recovery

**Logical backup (recommended, portable)**

```bash
# On the MongoDB host
docker compose -f compose.mongo.yaml exec -T mongo \
  mongodump --username "$MONGO_USER" --password "$MONGO_PASSWORD" \
  --authenticationDatabase admin --db proshop --archive --gzip \
  > /opt/proshop/backup-$(date +%F).gz

# Restore
docker compose -f compose.mongo.yaml exec -T mongo \
  mongorestore --username "$MONGO_USER" --password "$MONGO_PASSWORD" \
  --authenticationDatabase admin --archive --gzip --drop \
  < /opt/proshop/backup-2026-10-22.gz
```

Copy backups off the host (S3 is the natural target; the Mongo host reaches AWS
through the NAT gateway).

**Uploads** live in the `proshop_uploads-data` volume on the app host:

```bash
docker run --rm -v proshop_uploads-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/uploads-$(date +%F).tgz -C /data .
```

**Elastic Block Store**

All volumes are `DeleteOnTermination=true`. For point-in-time recovery, schedule
EBS snapshots of the MongoDB volume (Data Lifecycle Manager) before relying on
them. Snapshots are the only protection against accidental instance termination.

**Recovery order:** Mongo volume/snapshot → start Mongo → `mongorestore` if
needed → deploy app tag → health check.

---

## Security model

- **No secrets in git.** `.env`, PEM keys and `infra/aws-outputs.env` are ignored;
  `git ls-files` confirms none are tracked.
- **No static AWS credentials.** EC2 uses instance profiles; Jenkins has a
  dedicated role with ECR push limited to the two repositories.
- **Least-privilege network.** Mongo is private; SSH to Mongo comes only from the
  app SG; Jenkins reaches the app only from the Jenkins SG; admin ports are locked
  to the operator's IP.
- **Containers.** Backend runs as the non-root `node` user; only Nginx publishes
  a host port; Mongo and the API are internal-only.
- **App.** JWT auth, bcrypt hashing, Helmet, rate limiting, Mongo operator
  sanitisation, 1 MB JSON limit, generic 500 messages in production, upload MIME
  and 5 MB size checks.
- **Deployment.** SSH host-key verification stays enabled (`StrictHostKeyChecking=yes`
  after `ssh-keyscan` pins the key); `deploy.sh` never disables verification.
- **Jenkins.** Anonymous read disabled, signup disabled, admin password stored
  root-owned with group read for the service user, credentials managed by the
  credentials plugin.

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `required variable BACKEND_IMAGE is missing` | Running Compose directly on the app host without the deploy wrapper | Export the two image variables or use `./scripts/deploy.sh` |
| `jenkins.io-2023.key` / `NO_PUBKEY` | Expired 2023 signing key | Use `jenkins.io-2026.key` |
| Jenkins: `references a local directory` | Local mirror SCM | Set `-Dhudson.plugins.git.GitSCM.ALLOW_LOCAL_CHECKOUT=true` (see above) |
| `chmod: Operation not permitted` on `~/.ssh` | `.ssh` owned by root | `chown -R jenkins:jenkins /var/lib/jenkins/.ssh` |
| `ssh-keyscan` returns nothing from Jenkins | Public EIP does not hairpin inside the VPC | Deploy to the app's **private** IP |
| 403 on `build` REST call | Missing CSRF crumb / session | Fetch `/crumbIssuer/api/json` with a cookie jar first |
| 400 on `buildWithParameters` | Parameters not registered yet | Run one build, then use `buildWithParameters` |
| App healthy but `/api/health` shows `db: disconnected` | Wrong `MONGO_URI`, Mongo SG or auth | Check `MONGO_URI`, SG source group, `docker compose logs mongo` |
| Images 404 | Nginx not proxying `/uploads/`, or volume not mounted | Check `nginx/default.conf` and `uploads-data` volume |
| `deploy.sh` health timeout | Bad image, DB down, port conflict | Inspect the diagnostics it prints; `./scripts/deploy.sh rollback` |
| Frontend calls wrong host | `VITE_API_URL` baked in | Leave it empty; the client uses relative `/api` |

---

## Cost and cleanup

Running costs (us-east-1, approximate, **not** covered by Free Tier):

| Item | Monthly |
| --- | --- |
| 3 × t3.small | ~$45 |
| NAT Gateway (hourly + data) | ~$33 + data |
| 3 × 20 GB gp3 | ~$5 |
| 2 × Elastic IP (attached) | ~$0 |
| ECR storage | < $1 |
| **Total** | **~$85/month** |

Destroy everything (prompts for confirmation):

```bash
./scripts/aws/99-teardown.sh
```

This terminates the instances (and their EBS volumes), releases the EIPs, deletes
the NAT gateway, subnets, routes, VPC, security groups, instance profile/role and
the ECR repositories. **MongoDB data is destroyed** — take a backup first.

Stop the bleed without deleting data by scheduling a nightly stop of the
instances; NAT gateways bill while they exist, so delete the NAT gateway if you
pause for long.

---

## Known limitations

- **CI source is a local bare mirror**, not GitHub, because no GitHub credentials
  exist in this environment. The pipeline itself is standard and the README
  documents the exact GitHub switch-over. This is the one deviation from
  "checkout from GitHub".
- **Single AZ / single NAT gateway.** Fine for a demo; production should use two
  AZs and one NAT per AZ.
- **Uploads are local to the app host.** Multi-instance deployments need S3 or
  Cloudinary (both are one environment variable away).
- **No HTTPS certificate** until a domain is attached (configuration is provided,
  not enabled).
- **Jenkins runs on a t3.small with 2 GB swap.** Adequate for this pipeline;
  upgrade to t3.medium for heavier builds.
- **The admin seed is a manual step** after the first deploy; it could be moved
  into a one-shot init container.
- Frontend bundle is a single ~1.3 MB chunk; code splitting would improve first
  load but was out of scope.

---

## Verified results

| Check | Result |
| --- | --- |
| Local Compose stack | healthy; only Nginx publishes port 80 |
| Mongo auth | correct password → `1`; wrong password → `Authentication failed` |
| API CRUD | category + product created, uploaded image served `200 image/png` |
| Mock payment | `{"clientSecret":null,"mock":true,...}` then order created |
| SPA routing | `/shop` → `200` |
| Public EC2 deployment | frontend/API/`/api/health` all `200`, `db: connected` |
| Private Mongo reachability | not reachable from outside the VPC |
| Jenkins build #5 | **SUCCESS**, 13 backend + 6 frontend tests, 0 lint errors |
| ECR | `proshop/backend` and `proshop/frontend` tagged `651039b`, `bc42a70`, `d316b58` |
| EC2 rollback | `d316b58 → 651039b → d316b58`, health-gated each time |

---

## License

The vendored application code retains its original MIT license (`LICENSE`).

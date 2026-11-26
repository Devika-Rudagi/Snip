# Snip: Scalable Cloud-Native Deployment on AWS (EKS)

Snip is a small FastAPI URL shortener with a CPU-heavy QR-code endpoint. It is deployed on Amazon EKS behind an Application Load Balancer, autoscaled by a Horizontal Pod Autoscaler, and monitored with Prometheus, Grafana and CloudWatch. The app is deliberately simple; the project focuses on how it runs in the cloud.

## Endpoints

| Endpoint | Purpose |
|---|---|
| `POST /shorten` | Stores a long URL in PostgreSQL and returns a short code |
| `GET /{code}` | Redirects to the original URL (fast, high-volume path) |
| `GET /{code}/qr` | Returns a QR code PNG (CPU-heavy, used to trigger autoscaling) |
| `GET /whoami` | Returns the pod name (proves load balancing) |
| `GET /healthz` | Liveness probe (does not touch the database) |
| `GET /ready` | Readiness probe (checks the database) |
| `GET /metrics` | Prometheus metrics |

## GCP to AWS substitutions

| Project brief (GCP) | This solution (AWS) |
|---|---|
| Google Compute Engine | EC2 (workstation and EKS worker nodes) |
| GKE | Amazon EKS, created with eksctl |
| Google Container Registry | Amazon ECR |
| Kubernetes Ingress Controller | AWS Load Balancer Controller (ALB) |
| Let's Encrypt SSL | Not used: HTTP only, as approved by the instructor |
| Cloud Logging and monitoring | CloudWatch Container Insights, Prometheus and Grafana |
| PostgreSQL | PostgreSQL 16 pod in the cluster |

## Repository layout

```
snip/
├── README.md
├── app/                 FastAPI app, requirements, Dockerfile
├── cluster.yaml         eksctl cluster definition
├── k8s/                 Kubernetes manifests, applied in numbered order
├── monitoring/          exported Grafana dashboard (added later)
├── scripts/             up.sh, down.sh, loadtest.sh
└── docs/                report and screenshots
```

## Run the app locally (Docker)

```bash
cd app
docker network create appnet
docker run -d --name db --network appnet \
  -e POSTGRES_PASSWORD=pass -e POSTGRES_DB=snip postgres:16
docker build -t snip .
docker run -d --name snip -p 8000:8000 --network appnet \
  -e DATABASE_URL=postgresql://postgres:pass@db:5432/snip snip
```

If the app container exits because the database was still starting, run `docker start snip` again.

Then test it:

```bash
curl -X POST localhost:8000/shorten -H 'Content-Type: application/json' \
  -d '{"url": "https://www.sfbu.edu"}'
curl -i localhost:8000/<code>          # expect 307 and a Location header
curl -o qr.png localhost:8000/<code>/qr
curl localhost:8000/whoami
curl localhost:8000/metrics | head
```

On an Apple Silicon Mac, build with `docker build --platform linux/amd64 -t snip .` so the image runs on the x86 EKS nodes.

## Push the image to ECR

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REGION=us-west-2
export REPO=$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/snip

aws ecr create-repository --repository-name snip --region $REGION \
  --image-scanning-configuration scanOnPush=true
aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com
docker tag snip:latest $REPO:v2
docker push $REPO:v2
```

## Build and tear down the cluster

```bash
./scripts/up.sh      # creates the cluster and deploys everything (billing starts)
./scripts/down.sh    # deletes the Ingress, the cluster and the log groups
```

The Ingress in `k8s/05-ingress.yaml` is HTTP only (port 80), as approved by the instructor. No certificate or host name needs to be edited.

The scripts in `scripts/` were written after the deployed cluster was built step by step, and they were not used to create it. Treat them as documentation of the steps.

## Load testing

```bash
HOST=http://<load balancer address> ./scripts/loadtest.sh baseline
HOST=http://<load balancer address> ./scripts/loadtest.sh qr
```

## Security notes

Never commit secrets or the `.pem` key. The database password is created by `up.sh` as a Kubernetes Secret and is never stored in Git or in the image.

## Known limitations

- PostgreSQL is a single pod without persistent storage (production would use RDS or EBS-backed storage).
- There is no CI/CD pipeline.
- Only pods autoscale; the node count is fixed at 2 (production would add Cluster Autoscaler or Karpenter).

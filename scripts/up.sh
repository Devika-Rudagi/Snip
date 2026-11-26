#!/usr/bin/env bash
# Builds the whole environment. Run from the repository root: ./scripts/up.sh
set -euo pipefail
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null

eksctl create cluster -f cluster.yaml
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

eksctl create iamserviceaccount --cluster snip --region us-west-2 \
  --namespace kube-system --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy --approve
VPC_ID=$(aws eks describe-cluster --name snip --region us-west-2 \
  --query cluster.resourcesVpcConfig.vpcId --output text)
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --set clusterName=snip --set region=us-west-2 --set vpcId=$VPC_ID \
  --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace
aws eks create-addon --cluster-name snip --region us-west-2 \
  --addon-name amazon-cloudwatch-observability

kubectl create namespace snip
DB_PASS=$(openssl rand -hex 16)
kubectl -n snip create secret generic db-secret \
  --from-literal=POSTGRES_PASSWORD=$DB_PASS \
  --from-literal=DATABASE_URL=postgresql://postgres:$DB_PASS@postgres:5432/snip

kubectl -n kube-system rollout status deploy/aws-load-balancer-controller

# Apply the manifests. The app and Ingress files contain placeholders:
# <ACCOUNT_ID> is filled in here. The Ingress is HTTP only, so nothing else needs editing.
kubectl apply -f k8s/01-postgres.yaml
kubectl -n snip rollout status deploy/postgres
sed "s/<ACCOUNT_ID>/$ACCOUNT_ID/g" k8s/02-app.yaml | kubectl apply -f -
kubectl apply -f k8s/03-hpa.yaml -f k8s/04-pdb.yaml -f k8s/06-servicemonitor.yaml \
  -f k8s/07-networkpolicy.yaml -f k8s/08-rbac.yaml
sed "s/<ACCOUNT_ID>/$ACCOUNT_ID/g" k8s/05-ingress.yaml | kubectl apply -f -
kubectl -n snip get ingress snip

#!/usr/bin/env bash
# Tears the environment down. Run from the repository root: ./scripts/down.sh
set -uo pipefail
# 1. Delete the Ingress first so the controller removes the ALB
kubectl delete -f k8s/05-ingress.yaml
sleep 90
# 2. Delete the cluster (nodes, add-ons, VPC created by eksctl)
eksctl delete cluster -f cluster.yaml --wait
# 3. CloudWatch log groups outlive the cluster
for g in application dataplane host performance; do
  aws logs delete-log-group --log-group-name /aws/containerinsights/snip/$g --region us-west-2
done
echo "Now stop the workstation and check the console for leftovers:"
echo "EC2 > Load Balancers, Target Groups, Volumes, Elastic IPs; VPC > NAT gateways."

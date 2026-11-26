#!/usr/bin/env bash
# Usage: HOST=https://snip.example.com ./scripts/loadtest.sh [baseline|qr]
# HOST can also be http://<ALB address>
set -euo pipefail
: "${HOST:?Set HOST first, for example HOST=http://my-alb.elb.amazonaws.com}"

CODE=$(curl -s -X POST "$HOST/shorten" -H 'Content-Type: application/json' \
  -d '{"url": "https://www.sfbu.edu"}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["code"])')
echo "Using short code: $CODE"

case "${1:-baseline}" in
  baseline)
    # Light redirect path; -disable-redirects keeps hey from following the redirect
    hey -z 60s -c 50 -disable-redirects "$HOST/$CODE"
    ;;
  qr)
    # CPU-heavy path used for Runs A, B and C. Watch in other terminals:
    #   kubectl -n snip get hpa -w
    hey -z 120s -c 50 "$HOST/$CODE/qr?size=20"
    ;;
  *)
    echo "Usage: $0 [baseline|qr]"; exit 1 ;;
esac

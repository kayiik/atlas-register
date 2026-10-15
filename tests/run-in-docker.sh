#!/usr/bin/env bash
# Starts an Atlas from ATLAS_IMAGE (any image of the Atlas service), runs
# tests/run.sh against it from a small container with bash, curl and jq, and
# removes everything it started. Needs Docker; DOCKER_CONTEXT picks the engine.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && { pwd -W 2>/dev/null || pwd; })
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: pass container paths as they are
image=${ATLAS_IMAGE:?set ATLAS_IMAGE to an Atlas image}
run=atlas-register-test-$$
read_key=read-$RANDOM$RANDOM operator_key=operator-$RANDOM$RANDOM

cleanup() { docker rm -f "$run-atlas" "$run-runner" >/dev/null 2>&1 || true; docker network rm "$run" >/dev/null 2>&1 || true
  docker image rm -f "$run-runner" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker network create "$run" >/dev/null
docker run -d --name "$run-atlas" --network "$run" -e ATLAS_API_KEY="$read_key" -e ATLAS_OPERATOR_KEY="$operator_key" \
  -e ATLAS_HEALTH_CHECKS=off "$image" >/dev/null
printf 'FROM alpine:3.22\nRUN apk add --no-cache bash curl jq\n' | docker build -q -t "$run-runner" - >/dev/null
docker run --rm --name "$run-runner" --network "$run" -v "$here:/action:ro" \
  -e ATLAS_URL="http://$run-atlas:8099" -e ATLAS_READ_KEY="$read_key" -e OPERATOR="$operator_key" \
  "$run-runner" bash -c '
    for i in $(seq 60); do curl -fs "$ATLAS_URL/health" >/dev/null && break; sleep 0.5; done
    export ATLAS_TEST_REPOSITORY=example/shop
    export ATLAS_WRITER_KEY=$(curl -fsS -X POST "$ATLAS_URL/v1/writer-keys" -H "X-Atlas-Key: $ATLAS_READ_KEY" \
      -H "X-Atlas-Operator-Key: $OPERATOR" -H "Content-Type: application/json" \
      -d "{\"repository_id\":\"$ATLAS_TEST_REPOSITORY\",\"holder\":\"test\"}" | jq -r .key)
    bash /action/tests/run.sh'

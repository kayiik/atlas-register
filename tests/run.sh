#!/usr/bin/env bash
# Runs register.sh the way the action does, against an Atlas given by
# ATLAS_URL, ATLAS_READ_KEY and ATLAS_WRITER_KEY (a writer key for
# ATLAS_TEST_REPOSITORY), and checks the outcome, the job summary and that the
# step never fails. tests/run-in-docker.sh runs it with everything it needs.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../register.sh"
repo=${ATLAS_TEST_REPOSITORY:?}
failures=0

# step runs the script with the given extra environment, like one workflow step.
step() {
  local dir; dir=$(mktemp -d)
  : >"$dir/summary"; : >"$dir/output"
  env GITHUB_STEP_SUMMARY="$dir/summary" GITHUB_OUTPUT="$dir/output" ATLAS_REPOSITORY="$repo" \
    ATLAS_REVISION=0123456789abcdef0123456789abcdef01234567 ATLAS_RUN_URL=https://ci.example.com/run/1 "$@" \
    bash "$script" >"$dir/log" 2>&1
  echo "$? $dir"
}

check() { # name, condition result
  if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1))
    sed "s/^/     /" "$dir/output" "$dir/log" | tail -5; fi
}
outcome() { sed -n 's/^outcome=//p' "$1/output"; }

merge=(ATLAS_MOMENT=record ATLAS_URL="$ATLAS_URL" ATLAS_READ_KEY="$ATLAS_READ_KEY"
  "ATLAS_SERVICES=web site
worker worker"
  "ATLAS_LABELS=product=shop
business=acme"
  "ATLAS_SERVICE_LABELS=web:environment=prod"
  "ATLAS_SERVICE_IDENTIFIERS=web:endpoint=https://shop.example.com"
  "ATLAS_CONFIG=web:API_URL=github-variable:API_URL|https://api.example.com/v1
web:DB_URL=aws-ssm:/shop/DB_URL"
  "ATLAS_HEALTH=web=https://shop.example.com/health"
  'ATLAS_CAPABILITIES=[{"verb":"cost","description":"Cloud cost","how":"https://shop.example.com/cost","credential":"vault:Shop/cost key"}]')

read -r code dir < <(step "${merge[@]}" ATLAS_WRITER_KEY=)
check "a dry run without a writer key answers and exits 0" $([ "$code" = 0 ] && [ "$(outcome "$dir")" = created ] && grep -q "(dry run)" "$dir/summary"; echo $?)

read -r code dir < <(step "${merge[@]}" ATLAS_WRITER_KEY="$ATLAS_WRITER_KEY")
check "a record moment registers the record" $([ "$code" = 0 ] && [ "$(outcome "$dir")" = created ]; echo $?)
read -r code dir < <(step "${merge[@]}" ATLAS_WRITER_KEY="$ATLAS_WRITER_KEY")
check "the same complete record again is unchanged" $([ "$(outcome "$dir")" = unchanged ]; echo $?)

complete=("${merge[@]}" 'ATLAS_SERVICES=web site
worker worker
database data_store' 'ATLAS_SERVICE_NOTES=web:Application: public UI
worker:Runs inside users hosts
database:Managed database' 'ATLAS_SERVICE_DEPLOYED=worker:by-users
database:provisioned' 'ATLAS_SERVICE_LIFECYCLES=worker:maintenance' ATLAS_LIFECYCLE=maintenance)
read -r code dir < <(step "${complete[@]}" ATLAS_WRITER_KEY="$ATLAS_WRITER_KEY")
check "complete registration accepts notes, deployed and lifecycle" $([ "$(outcome "$dir")" = updated ]; echo $?)
read -r code dir < <(step "${complete[@]}" ATLAS_WRITER_KEY="$ATLAS_WRITER_KEY")
check "repeated complete registration retains optional fields" $([ "$(outcome "$dir")" = unchanged ]; echo $?)
context() {
  local key="$ATLAS_READ_KEY"
  key=${key//\\/\\\\}; key=${key//\"/\\\"}
  printf 'header = "X-Atlas-Key: %s"\n' "$key" | curl --config - -fsS "$ATLAS_URL/v1/context/repository/$repo"
}
check "whole-record readback retains owner note, deployed and both lifecycles" $(context | jq -e '
 .semantics[0].content | ([.services[].id] | sort) == ["database","web","worker"] and .repository.catalogue_lifecycle == "maintenance" and
 any(.services[]; .id == "web" and .note == "Application: public UI") and
 any(.services[]; .id == "worker" and .note == "Runs inside users hosts" and .deployed == "by-users" and .catalogue_lifecycle == "maintenance") and
 any(.services[]; .id == "database" and .note == "Managed database" and .deployed == "provisioned")' >/dev/null; echo $?)
read -r code dir < <(step "${merge[@]}" ATLAS_WRITER_KEY="$ATLAS_WRITER_KEY" ATLAS_MOMENT=merge)
check "merge remains a record compatibility alias" $([ "$(outcome "$dir")" = updated ]; echo $?)
check "omitted optional owner fields are removed on replacement" $(context | jq -e '.semantics[0].content | ([.services[].id] | sort) == ["web","worker"] and .repository.catalogue_lifecycle == "active" and all(.services[]; has("note") == false and has("deployed") == false and .catalogue_lifecycle == "active")' >/dev/null; echo $?)

read -r code dir < <(step "${merge[@]}" ATLAS_READ_KEY=$'invalid\nkey' ATLAS_WRITER_KEY="$ATLAS_WRITER_KEY")
check "a read credential with a newline is refused without failing the job" $([ "$code" = 0 ] && [ "$(outcome "$dir")" = refused ] && grep -q 'credential contains a line break' "$dir/log"; echo $?)
read -r code dir < <(step "${merge[@]}" ATLAS_WRITER_KEY=$'invalid\rkey')
check "a writer credential with a carriage return is refused without failing the job" $([ "$code" = 0 ] && [ "$(outcome "$dir")" = refused ] && grep -q 'credential contains a line break' "$dir/log"; echo $?)

read -r code dir < <(step "${merge[@]/ATLAS_LABELS=product=shop/ATLAS_LABELS=product=store}" ATLAS_WRITER_KEY="$ATLAS_WRITER_KEY")
check "an established product is kept, and the summary says so" $(grep -q "| kept |" "$dir/summary"; echo $?)

read -r code dir < <(step ATLAS_MOMENT=release ATLAS_URL="$ATLAS_URL" ATLAS_READ_KEY="$ATLAS_READ_KEY" \
  ATLAS_WRITER_KEY="$ATLAS_WRITER_KEY" ATLAS_SUBJECT=web ATLAS_VERSION=v1.0.0 \
  "ATLAS_ARTIFACTS=ghcr.io/example/shop@sha256:aaaaaaaaaaaaaaaa")
check "a release is reported" $([ "$code" = 0 ] && [ "$(outcome "$dir")" = created ]; echo $?)

read -r code dir < <(step ATLAS_MOMENT=deploy ATLAS_URL="$ATLAS_URL" ATLAS_READ_KEY="$ATLAS_READ_KEY" \
  ATLAS_WRITER_KEY="$ATLAS_WRITER_KEY" ATLAS_SUBJECT=web ATLAS_IMAGE=ghcr.io/example/shop:v1.0.0)
check "a deploy reports and names what it could not know" $([ "$code" = 0 ] && [ "$(outcome "$dir")" = created ] \
  && grep -q "unknown to this job: host or account" "$dir/summary" && grep -q "unknown to this job: endpoints" "$dir/summary"; echo $?)

read -r code dir < <(step ATLAS_MOMENT=deploy ATLAS_URL="$ATLAS_URL" ATLAS_READ_KEY="$ATLAS_READ_KEY" \
  ATLAS_WRITER_KEY="$ATLAS_WRITER_KEY" ATLAS_SUBJECT=web ATLAS_VERSION=v1.0.0 \
  ATLAS_IMAGE=ghcr.io/example/shop:v1.0.0@sha256:aaaaaaaaaaaaaaaa "ATLAS_ENDPOINTS=https://shop.example.com" \
  "ATLAS_IDENTIFIERS=host=node1
account=cloud/123" "ATLAS_CONFIG=API_URL=github-variable:API_URL|https://api.example.com/v1")
check "a complete deploy has nothing unknown" $([ "$(outcome "$dir")" = updated ] && ! grep -q "unknown to this job" "$dir/summary"; echo $?)

read -r code dir < <(step ATLAS_MOMENT=merge ATLAS_URL="$ATLAS_URL" ATLAS_READ_KEY="$ATLAS_READ_KEY" \
  ATLAS_WRITER_KEY="$ATLAS_WRITER_KEY" "ATLAS_SERVICES=web site" "ATLAS_CONFIG=web:DB=env:password=hunter2")
check "a secret-shaped value is refused, and the step still exits 0" $([ "$code" = 0 ] && [ "$(outcome "$dir")" = refused ]; echo $?)

read -r code dir < <(step ATLAS_MOMENT=merge ATLAS_URL=http://127.0.0.1:9 ATLAS_READ_KEY=x "ATLAS_SERVICES=web site")
check "an unreachable Atlas leaves the job green" $([ "$code" = 0 ] && [ "$(outcome "$dir")" = unreachable ]; echo $?)

read -r code dir < <(step ATLAS_MOMENT=launch ATLAS_URL="$ATLAS_URL" ATLAS_READ_KEY="$ATLAS_READ_KEY")
check "an unknown moment is refused, and the step exits 0" $([ "$code" = 0 ] && [ "$(outcome "$dir")" = refused ]; echo $?)

echo "$failures failure(s)"
[ "$failures" = 0 ]

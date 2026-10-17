#!/usr/bin/env bash
# Builds one registration (a complete record, a release report, a deployment
# report) from the ATLAS_* environment, sends it to Atlas, and prints Atlas's
# answer. It never fails the job: Atlas does not gate anything, and neither does
# this. Needs bash, curl and jq.
set -uo pipefail

out() { [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"; return 0; }
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"; else printf '%s\n' "$*"; fi; }
finish() { out outcome "$1"; exit 0; }
note() { echo "::warning::atlas-register: $*"; }

for tool in curl jq; do
  command -v "$tool" >/dev/null || { note "$tool is not installed; nothing registered"; finish unreachable; }
done

moment=${ATLAS_MOMENT:-}
url=${ATLAS_URL%/}
repo=$(printf '%s' "${ATLAS_REPOSITORY:-}" | tr 'A-Z' 'a-z')
revision=${ATLAS_REVISION:-main}
dry=${ATLAS_DRY_RUN:-false}
[ -z "${ATLAS_WRITER_KEY:-}" ] && dry=true
# curl config values and HTTP headers cannot contain line breaks. Do not echo
# rejected credentials; refusal still leaves the surrounding job successful.
if [[ "${ATLAS_READ_KEY:-}" == *$'\r'* || "${ATLAS_READ_KEY:-}" == *$'\n'* ]] ||
   { [ "$dry" != true ] && [[ "${ATLAS_WRITER_KEY:-}" == *$'\r'* || "${ATLAS_WRITER_KEY:-}" == *$'\n'* ]]; }; then
  note "a credential contains a line break; nothing registered"; finish refused
fi
run_url=${ATLAS_RUN_URL:-https://github.com/$repo}
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
unknown=()

# lines prints the non-empty, trimmed lines of a multi-line input.
lines() { printf '%s\n' "${1:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true; }

# kv turns "<kind>=<value>" lines into a JSON list of {kind, value}.
kv() { lines "$1" | jq -R 'split("=") | {kind: .[0], value: (.[1:] | join("="))}' | jq -s '.'; }

# labels turns "<kind>=<value>" lines into {kind: [values]}.
labels() { kv "$1" | jq 'reduce .[] as $l ({}; .[$l.kind] += [$l.value])'; }

# per_service turns "<service>:<rest>" lines into a JSON list of {service, rest}.
per_service() { lines "$1" | jq -R 'index(":") as $i | {service: .[:$i], rest: .[$i+1:]}' | jq -s '.'; }

# config turns "<NAME>=<source>[|<target>]" into {name, source, target?}.
config_of() { jq -R 'index("=") as $i | .[$i+1:] as $v | ($v | split("|")) as $p
  | {name: .[:$i], source: $p[0]} + (if ($p | length) > 1 and $p[1] != "" then {target: $p[1]} else {} end)'; }

case "$moment" in
record|merge)
  name=${repo#*/}
  doc_id=${ATLAS_DOCUMENT_ID:-repository/$name}
  services=$(lines "${ATLAS_SERVICES:-}" | jq -R 'split(" ") | map(select(. != "")) | {id: .[0], kind: (.[1] // "other")}' | jq -s '.')
  service_labels=$(per_service "${ATLAS_SERVICE_LABELS:-}")
  service_ids=$(per_service "${ATLAS_SERVICE_IDENTIFIERS:-}")
  service_notes=$(per_service "${ATLAS_SERVICE_NOTES:-}")
  service_deployed=$(per_service "${ATLAS_SERVICE_DEPLOYED:-}")
  service_lifecycles=$(per_service "${ATLAS_SERVICE_LIFECYCLES:-}")
  service_config=$(per_service "${ATLAS_CONFIG:-}" | jq -c '.[]' | while read -r item; do
    svc=$(jq -r .service <<<"$item"); jq -r .rest <<<"$item" | config_of | jq --arg s "$svc" '{service: $s} + .'
  done | jq -s '.')
  health=$(lines "${ATLAS_HEALTH:-}" | jq -R 'index("=") as $i | {service: .[:$i], url: .[$i+1:]}' | jq -s '.')
  relationships=$(lines "${ATLAS_RELATIONSHIPS:-}" | jq -R 'split(" ") | map(select(. != "")) | {from_id: .[0], kind: .[1], to_id: .[2]}' | jq -s '.')
  capabilities=${ATLAS_CAPABILITIES:-[]}
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$capabilities" || { note "capabilities is not a JSON list; left out"; capabilities='[]'; }
  intent=$(lines "${ATLAS_INTENT:-}" | jq -R 'index("=") as $i | {field: .[:$i], reason: .[$i+1:]}' | jq -s '.')
  repo_labels=$(labels "${ATLAS_LABELS:-}")
  repo_ids=$(kv "${ATLAS_IDENTIFIERS:-}")
  body=$(jq -n --arg doc "$doc_id" --arg repo "$repo" --arg rev "$revision" \
    --arg lifecycle "${ATLAS_LIFECYCLE:-active}" --argjson snotes "$service_notes" --argjson sdeployed "$service_deployed" --argjson slifecycles "$service_lifecycles" \
    --argjson services "$services" --argjson slabels "$service_labels" --argjson sids "$service_ids" \
    --argjson sconfig "$service_config" --argjson health "$health" --argjson rels "$relationships" \
    --argjson caps "$capabilities" --argjson intent "$intent" --argjson labels "$repo_labels" --argjson ids "$repo_ids" '
    def nonempty(f): if (f | length) > 0 then f else empty end;
    {document_id: $doc, source_repository: $repo, source_revision: $rev,
     content: {
      repository: ({id: $repo, catalogue_lifecycle: $lifecycle, run_policy: "continuous"}
        + (if ($labels | length) > 0 then {labels: $labels} else {} end)
        + (if ($ids | length) > 0 then {identifiers: $ids} else {} end)
        + ([$caps[] | select(.service == null)] as $c | if ($c | length) > 0 then {capabilities: $c} else {} end)),
      targets: [$services[] | {id: ("runs-" + .id), kind: "environment"}],
      services: [$services[] | .id as $s | {id: $s, kind: .kind, catalogue_lifecycle: "active",
        run_policy: "continuous", target_id: ("runs-" + $s)}
        + ([$snotes[] | select(.service == $s) | .rest] | if length > 0 then {note: .[-1]} else {} end)
        + ([$sdeployed[] | select(.service == $s) | .rest] | if length > 0 then {deployed: .[-1]} else {} end)
        + ([$slifecycles[] | select(.service == $s) | .rest] | if length > 0 then {catalogue_lifecycle: .[-1]} else {} end)
        + ([$slabels[] | select(.service == $s) | .rest | index("=") as $i | {kind: .[:$i], value: .[$i+1:]}]
            | if length > 0 then {labels: (reduce .[] as $l ({}; .[$l.kind] += [$l.value]))} else {} end)
        + ([$sids[] | select(.service == $s) | .rest | index("=") as $i | {kind: .[:$i], value: .[$i+1:]}]
            | if length > 0 then {identifiers: .} else {} end)
        + ([$sconfig[] | select(.service == $s) | del(.service)] | if length > 0 then {config: .} else {} end)
        + ([$caps[] | select(.service == $s) | del(.service)] | if length > 0 then {capabilities: .} else {} end)],
      foreign_references: ([$rels[] | .to_id, .from_id | select(contains("#"))] | unique
        | map({id: ., kind: (split("#")[1] | split("/")[0])})),
      relationships: $rels,
      probes: [$health[] | {id: ("probe-" + .service), kind: "http", target: .url, healthy_when: "an answer below 400"}],
      source_bindings: [$health[] | {id: ("health-" + .service), subject_id: .service, source: "http",
        summary_kind: "health_summary", probe_id: ("probe-" + .service)}]
     }} + (if ($intent | length) > 0 then {intent: $intent} else {} end)')
  path="/v1/semantics/$doc_id"
  ;;
release|deploy)
  subject=${ATLAS_SUBJECT:-}
  if [ -z "$subject" ]; then note "subject is required for a $moment; nothing registered"; finish refused; fi
  version=${ATLAS_VERSION:-}
  if [ "$moment" = release ]; then
    [ -z "$version" ] && unknown+=("version")
    artifacts=$(lines "${ATLAS_ARTIFACTS:-}" | jq -R 'split("@") | {name: .[0]} + (if length > 1 then {digest: .[1]} else {} end)' | jq -s '.')
    [ "$(jq length <<<"$artifacts")" = 0 ] && unknown+=("artifacts")
    details=$(jq -n --arg v "$version" --argjson a "$artifacts" \
      '(if $v != "" then {version: $v} else {} end) + (if ($a | length) > 0 then {artifacts: $a} else {} end)')
    kind=release_summary state=released reason="${version:-a release} built"
  else
    image=${ATLAS_IMAGE:-}
    endpoints=$(lines "${ATLAS_ENDPOINTS:-}" | jq -R . | jq -s '.')
    ids=$(kv "${ATLAS_IDENTIFIERS:-}")
    config=$(lines "${ATLAS_CONFIG:-}" | config_of | jq -s '.')
    [ -z "$version" ] && [ "${image#*@}" = "$image" ] && unknown+=("version or image digest")
    jq -e 'any(.[]; .kind == "host" or .kind == "account")' >/dev/null <<<"$ids" || unknown+=("host or account")
    [ "$(jq length <<<"$endpoints")" = 0 ] && unknown+=("endpoints")
    details=$(jq -n --arg v "$version" --arg i "$image" --argjson e "$endpoints" --argjson d "$ids" --argjson c "$config" \
      '(if $v != "" then {version: $v} else {} end) + (if $i != "" then {image: $i} else {} end)
       + (if ($e | length) > 0 then {endpoints: $e} else {} end) + (if ($d | length) > 0 then {identifiers: $d} else {} end)
       + (if ($c | length) > 0 then {config: $c} else {} end)')
    kind=deployment_summary state=deployed reason="${version:-${image:-a deploy}} deployed"
  fi
  body=$(jq -n --arg repo "$repo" --arg s "$subject" --arg src "${ATLAS_SOURCE:-github-actions}" --arg k "$kind" \
    --arg at "$now" --arg st "$state" --arg r "$reason" --arg u "$run_url" --argjson d "$details" \
    '{repository_id: $repo, subject: $s, source: $src, kind: $k, observed_at: $at, state: $st, reason: $r,
      details_url: $u} + (if ($d | length) > 0 then {details: $d} else {} end)')
  path="/v1/foreign-summaries/$subject"
  ;;
*)
  note "moment must be record, release or deploy (merge is a compatibility alias for record); nothing registered"; finish refused ;;
esac

[ "$dry" = true ] && path="$path?dry_run=true"
# Keys are read through curl's stdin config, never exposed in process arguments.
header() {
  local value="$2"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf 'header = "%s: %s"\n' "$1" "$value"
}
auth() { header X-Atlas-Key "${ATLAS_READ_KEY:-}"; [ "$dry" = true ] || header X-Atlas-Writer-Key "${ATLAS_WRITER_KEY}"; }
response=$(mktemp)
status=$(auth | curl --config - -sS -o "$response" -w '%{http_code}' --max-time 30 -X PUT -H 'Content-Type: application/json' --data "$body" "$url$path") || status=000

summary "### Atlas: $moment of \`$repo\`$( [ "$dry" = true ] && echo ' (dry run)')"
if [ "$status" = 000 ]; then
  note "Atlas did not answer at $url"; summary "Atlas did not answer; nothing was registered."; finish unreachable
fi
if [ "$status" != 200 ]; then
  detail=$(jq -c '.detail // .' "$response" 2>/dev/null || cat "$response")
  note "Atlas refused the $moment ($status): $detail"
  summary "Refused ($status): \`$detail\`"; finish refused
fi
outcome=$(jq -r '.answer.outcome // "unknown"' "$response")
out answer "$(jq -c '.answer' "$response")"
summary "Outcome: **$outcome**$(jq -r 'if .answer.reason then " (" + .answer.reason + ")" else "" end' "$response")"
summary ""
summary "| Field | Result | Detail |"
summary "|---|---|---|"
jq -r '.answer.fields[] | select(.result != "unchanged")
  | "| `\(.path)` | \(.result) | \(if .result == "changed" then "\(.from | tojson) → \(.to | tojson)" else "" end)\(if .reason then " " + .reason else "" end) |"' \
  "$response" | while read -r row; do summary "$row"; done
summary "| | unchanged | $(jq '[.answer.fields[] | select(.result == "unchanged")] | length' "$response") fields |"
jq -r '.answer.notes // [] | .[] | "- note: \(.kind) \(.subject // ""): \(.detail)"' "$response" | while read -r row; do summary "$row"; done
for u in "${unknown[@]}"; do summary "- unknown to this job: $u"; done
rm -f "$response"
finish "$outcome"

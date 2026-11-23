# atlas-register

A GitHub Action that registers, with an Atlas service (a registry where repositories record what they declare,
release and deploy), what a repository declares (at release or by explicit dispatch), what a
release built, and what a deploy put live. It sends what your workflow gives it,
prints Atlas's answer to the job summary (what changed, what didn't, what was
kept or skipped, and why), and **never fails the job**: Atlas gates nothing.

Values come from your workflow's inputs and CI variables, so the repository
commits no identifiers. Anything a deploy cannot know is reported as unknown
in the summary, and Atlas notes the missing minimum. Without a writer key, or
with `dry-run: true`, it asks what the write would change and stores nothing.

## Use

```yaml
# In a release or workflow_dispatch workflow: the complete repository record.
- uses: kayiik/atlas-register@main
  with:
    moment: record
    atlas-url: ${{ vars.ATLAS_URL }}
    read-key: ${{ secrets.ATLAS_READ_KEY }}
    writer-key: ${{ secrets.ATLAS_WRITER_KEY }}
    services: |
      web site
      database data_store
    service-notes: |
      web:Public application; consumes the API below.
      database:Managed database provisioned at a provider.
    service-deployed: |
      database:provisioned
    service-lifecycles: |
      web:active
      database:active
    labels: |
      product=shop
      business=${{ vars.BUSINESS }}
    service-identifiers: |
      web:endpoint=https://shop.example.com
      web:account=${{ vars.CLOUD_ACCOUNT }}
    config: |
      web:API_URL=github-variable:API_URL|https://api.example.com/v1
    health: |
      web=https://shop.example.com/health

# After publishing a release: what it built.
- uses: kayiik/atlas-register@main
  with:
    moment: release
    atlas-url: ${{ vars.ATLAS_URL }}
    read-key: ${{ secrets.ATLAS_READ_KEY }}
    writer-key: ${{ secrets.ATLAS_WRITER_KEY }}
    subject: web
    version: ${{ github.ref_name }}
    artifacts: ghcr.io/example/shop@${{ steps.build.outputs.digest }}

# Right after a successful deploy: what runs, where.
- uses: kayiik/atlas-register@main
  with:
    moment: deploy
    atlas-url: ${{ vars.ATLAS_URL }}
    read-key: ${{ secrets.ATLAS_READ_KEY }}
    writer-key: ${{ secrets.ATLAS_WRITER_KEY }}
    subject: web
    version: ${{ github.ref_name }}
    image: ghcr.io/example/shop@${{ steps.build.outputs.digest }}
    endpoints: https://shop.example.com
    identifiers: |
      account=${{ vars.CLOUD_ACCOUNT }}
      host=${{ vars.DEPLOY_HOST }}
```

There are no version tags yet: `@main` follows the latest; to pin, use a
commit SHA instead (`kayiik/atlas-register@<sha>`).

Every input is described in [action.yml](action.yml). Sources in `config` are
pointers to where a value is kept, never the value; Atlas refuses anything that
looks like a secret.

### Complete declarations and retained evidence

When a workflow already collects a complete declaration or report, pass its
UTF-8 JSON file instead of rebuilding it from the convenience inputs:

```yaml
- uses: kayiik/atlas-register@<reviewed-commit-sha>
  with:
    moment: record
    atlas-url: ${{ vars.ATLAS_URL }}
    read-key: ${{ secrets.ATLAS_READ_KEY }}
    writer-key: ${{ secrets.ATLAS_WRITER_KEY }}
    revision: ${{ github.sha }}
    payload-file: atlas-record.json

# Run inside the successful deployer's workflow, after retaining the outbox.
- uses: kayiik/atlas-register@<reviewed-commit-sha>
  with:
    moment: deploy
    atlas-url: ${{ vars.ATLAS_URL }}
    read-key: ${{ secrets.ATLAS_READ_KEY }}
    writer-key: ${{ secrets.ATLAS_WRITER_KEY }}
    payload-file: deployment-evidence/summaries.json
```

This path requires Python 3 (included on GitHub's Ubuntu runners). `record`
accepts the complete semantic document object; `release` and `deploy` accept a
nonempty JSON list of their respective foreign-summary kind. The payload's
repository must equal `repository`; a record's source revision must equal
`revision`. Convenience inputs do not modify a payload file. Keep identifiers
in CI/runtime configuration and keep secret values out of every payload.

The publisher previews every entry before the first real write, retains each
report's original timestamp, state and full details, retries transient errors,
and verifies both the API echo and the exact stored repository context. It does
not follow authenticated redirects. `verified` is `true` only after this stored
readback; it is `false` for a dry run, refusal or outage. `outcome` reports the
aggregate result. Atlas failures remain warnings and never fail delivery.

For a release declaration selected after checking commit ancestry, write the
current record snapshot to a separate JSON file and pass it as
`expected-current-file`. Publication refuses a changed snapshot. Serialize all
owner declaration writers in one workflow concurrency group. Atlas has no
conditional PUT: an unrelated writer after the final check remains outside this
boundary.

Retain the outbox as a workflow artifact before publication. Retry publication
with the same file, without rebuilding or redeploying. An outage mid-batch can
leave some entries published; replaying the unchanged outbox completes it.
An older report kept by Atlas is reported as unverified instead of pretending
that a newer stored observation proves this receipt. Do not require a reachable
Atlas or a registered declaration before building or deploying.

`moment: record` is a **whole-record replacement**. Send all services and owner
fields every time, including notes, deployed markers and lifecycle. Omission
removes an owner's optional fields; it is not a patch. Operator-set labels and
the server's established-fact intent rules still apply. `lifecycle` controls the
repository (active by default); `service-lifecycles` controls each service.
`service-deployed` accepts `provisioned` or `by-users`; leave it out for a service
whose deployments are reported. Notes are one line per service, with colons
allowed inside the note.

Use `on: [release, workflow_dispatch]` with suitable release types/job conditions;
Do not trigger registration on push or merge. `merge` remains an alias for the record
moment so existing callers can migrate without a contract break. It does not
recommend a merge trigger. A release workflow can send a record step and a
separate release report step. Deploy reports follow successful deploys.

A config `target` is an actual endpoint the service consumes. Management and
display links are not consumed targets. Endpoint identifiers in a record help
navigation; deployment `endpoints` state what the service actually serves.

After registering, read `GET /v1/context/repository/{owner}/{repo}` with your
issued read key in a header to verify the **whole record** (especially service
note, deployed and lifecycle). Keep credentials in secrets, never command arguments.

## Test

`ATLAS_IMAGE=<an Atlas image> tests/run-in-docker.sh` starts that Atlas, runs
the action's script against it from a small container, and removes everything
it started.

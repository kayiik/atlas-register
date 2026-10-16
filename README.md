# atlas-register

A GitHub Action that registers, with an Atlas service (a registry where repositories record what they declare,
release and deploy), what a repository declares (on a merge to its main branch), what a
release built, and what a deploy put live. It sends what your workflow gives it,
prints Atlas's answer to the job summary (what changed, what didn't, what was
kept or skipped, and why), and **never fails the job**: Atlas gates nothing.

Values come from your workflow's inputs and CI variables, so the repository
commits no identifiers. Anything a deploy cannot know is reported as unknown
in the summary, and Atlas notes the missing minimum. Without a writer key, or
with `dry-run: true`, it asks what the write would change and stores nothing.

## Use

```yaml
# On a merge to main: what the repository declares.
- uses: kayiik/atlas-register@main
  with:
    moment: merge
    atlas-url: ${{ vars.ATLAS_URL }}
    read-key: ${{ secrets.ATLAS_READ_KEY }}
    writer-key: ${{ secrets.ATLAS_WRITER_KEY }}
    services: |
      web site
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

## Test

`ATLAS_IMAGE=<an Atlas image> tests/run-in-docker.sh` starts that Atlas, runs
the action's script against it from a small container, and removes everything
it started.

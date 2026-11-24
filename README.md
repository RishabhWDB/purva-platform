# purva-platform

The only place that changes the 9 Azure container apps. Each team's repo builds its
image and uploads it to its own repository in the shared registry; **this repo deploys
it**, and holds every app's settings. Teams have no way to change an app, its size or
anything else in Azure, even by editing their own workflow.

```
team repo (push to main) ──build + upload──▶ purvashared82aaf9d4.azurecr.io/<app>
                                                         │
this repo, every 5 min ──finds the new image──▶ deploys it with apps/<app>.conf
```

| Who | Can do in Azure |
|---|---|
| Team identity `<app>-github` | Upload images to `<app>` in the registry. For `purva-main` and `rep-tell`, also read their Static Web App's upload token (website deploys). Nothing else. |
| `purva-platform-deployer` (this repo, main branch only) | Update the 9 container apps, read the registry. |
| You (Owner) | Everything. |

## Files

| File | What |
|---|---|
| `apps/<app>.conf` | One per app: vCPU, memory, min/max copies, health check. Change it and push: the app is updated within minutes. |
| `platform.conf` | Shared settings (subscription, registry, deployer identity). |
| `scripts/deploy.sh` | What the workflow runs. |
| `scripts/azure-setup.sh` | Cloud Shell, once: creates the deployer and takes deploy rights away from the teams. |
| `scripts/deploy-timer.sh` | Cloud Shell, once: the Azure timer that starts the workflow every 5 minutes. |
| `.github/workflows/deploy.yml` | Runs when the timer starts it, on a push to main, or by hand. |

## How a deploy works

For each app, `scripts/deploy.sh`:

1. Picks the image:
   - the newest one the team uploaded, if it has never been deployed before;
   - otherwise the current one.

   An image that failed is never retried by itself.
2. Compares the image, size and copies with what Azure has. If nothing differs, it does nothing.
3. Otherwise it updates the app and waits up to 5 minutes for the new revision to be ready and
   `HEALTH_PATH` to answer 200 (`spark`'s must answer `ok`).
4. If the new revision isn't healthy, it **puts the previous image back** and the run goes red.

A new image goes live **5-10 minutes** after the team's build finishes. GitHub's own schedule
turned out to run only about every 9 hours on this repo, so a small Azure Logic App
(`deploy-timer`, ~₹35 a month) starts the workflow every 5 minutes instead; GitHub's schedule
stays in `deploy.yml` as a backup. Every run's summary has a table of what happened to each app.

**By hand** (Actions → Deploy → Run workflow):
- `app`: one app, or `all`.
- `tag`: an exact image tag, to roll back or to retry an image that failed.
- `dry_run`: only says what would change.

## Setting up (once, in Azure Cloud Shell as Owner)

```bash
git clone https://github.com/RishabhWDB/purva-platform && cd purva-platform
bash scripts/azure-setup.sh status            # who can do what today
DRY_RUN=1 bash scripts/azure-setup.sh setup
bash scripts/azure-setup.sh setup             # prints DEPLOYER_CLIENT_ID
```

1. Put the printed `DEPLOYER_CLIENT_ID` (and `GITHUB_REPO_ID`) in `platform.conf` and push.
2. Run the workflow by hand with `dry_run` on, then off. Every app should be "up to date".
3. Only then take the teams' rights away:

```bash
DRY_RUN=1 bash scripts/azure-setup.sh lock
bash scripts/azure-setup.sh lock
bash scripts/azure-setup.sh status            # teams: Repository Writer only
```

To undo: `bash scripts/azure-setup.sh unlock` gives the teams their old rights back.

4. The 5-minute timer. On GitHub, create a fine-grained token (Settings → Developer settings →
   Fine-grained tokens): repository access **only this repo**, permission **Actions: Read and
   write**, nothing else. Then:

```bash
bash scripts/deploy-timer.sh setup     # asks for the token (not shown while typing)
bash scripts/deploy-timer.sh status    # a run every 5 minutes, "Succeeded"
```

   `pause`, `resume` and `remove` do what they say. When the token expires the runs show
   "Failed": make a new token and run `setup` again.

## Changing things

- **Size or copies:** edit `apps/<app>.conf` and push. If the cost limits
  (`cost-limits.sh`) are on, raise them first, or Azure refuses.
- **Environment variables and secrets:** not here yet. Change them in Cloud Shell, e.g.
  `az containerapp update -n <app> -g <app> --set-env-vars KEY=value` or
  `az containerapp secret set …`.
  - Don't run a team repo's `deploy/azure.sh` without reading it first: the team can edit it,
    and you'd be running it as Owner.
- **New app:** create it as before, add `apps/<app>.conf`, then rerun `azure-setup.sh setup`
  and `lock`.

## Limits

- GitHub turns off its own scheduled runs in a repo with no commits for 60 days. That only
  affects the backup schedule; the Azure timer keeps working until its token expires.
- The teams still control what's *inside* their image, which is their code. They can't change
  how much it costs to run.

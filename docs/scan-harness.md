# Using scan-harness.sh

`scan-harness.sh` is the kit's helper for running a security harness on a box. It's installed when the box
parameter `InstallHarness` is `true`, and it works with Anthropic's open source
[defending-code reference harness](https://github.com/anthropics/defending-code-reference-harness), which the
box clones at first boot. For what the harness does and how its skills work, see the harness's own README;
this page covers the kit's helper only.

- [Before you start](#before-you-start)
- [Commands](#commands)
- [Headless scans](#headless-scans)
- [The autonomous pipeline](#the-autonomous-pipeline)
- [Settings](#settings)
- [Updating](#updating)
- [Troubleshooting](#troubleshooting)

## Before you start

Run the helper on the box, as the `claude` user (the user every Session Manager session opens as):

1. **Sign in** (login banner, step 1). Scans call Bedrock with a key minted from your sign-in.
2. **Start `tmux`**, so a scan keeps running if your connection drops.
3. **Check the endpoints:** headless scans have no internet access, so the VPC needs the `bedrock-runtime`
   and `bedrock` interface endpoints. A VPC the kit builds has them; for your own VPC, see the shared stack's
   `InterfaceEndpoints` parameter.

## Commands

| Command | What it does |
|---|---|
| `scan-harness.sh scan <git-url\|dir>` | Headless static scan of a repository or a folder: threat model, vulnerability scan, then triage. Runs isolated; see [Headless scans](#headless-scans). |
| `scan-harness.sh setup` | Clones the harness if it's missing, and checks out the commit the kit was tested with. Setup runs this at first boot. |
| `scan-harness.sh sandbox` | Installs Docker and sets up the harness's own sandbox for the autonomous pipeline. Run it once per box. |
| `scan-harness.sh run <target> [args...]` | Runs the harness's autonomous pipeline on one of its targets, for example `drlibs`. |
| `scan-harness.sh token` | Mints a new Bedrock API key for the autonomous pipeline. |

## Headless scans

```
scan-harness.sh scan https://github.com/<org>/<repo>     # a Git repository
scan-harness.sh scan ~/code/<repo>                       # a folder on the box
```

A headless scan runs without anyone approving each step, and the repository under scan can steer the agent.
So the helper isolates every scan:

1. **Fresh copies.** It clones the repository (or copies the folder) and copies the harness at its pinned
   commit. Nothing from an earlier scan is reused. The clone runs as you, so private repositories work with
   your Git credentials on the box.
2. **A separate user.** The scan runs as `claude-scanner`, which has no `sudo` and can't read your home
   directory or your AWS sign-in.
3. **A Bedrock-only key.** The helper mints a short-term Bedrock API key from your sign-in and gives it only to
   that scan. The key can't call other AWS services, and it's deleted when the scan ends.
4. **No internet.** Firewall rules let `claude-scanner` reach only DNS, HTTPS inside the VPC (its endpoints)
   and the box's telemetry collector, so a misled agent can't send data out to the internet or reach the
   instance metadata service.
5. **Checked results.** Each step must finish and write a complete report. Otherwise the scan stops, says
   which step failed, and doesn't report old results.

The scan's prompts, responses and tool calls are recorded in telemetry like any other Claude Code session.
Scans can take a while: start them in `tmux`.

### Results

Each scan writes a new folder, named after the repository, so scans of different repositories never mix:

```
~/scan-results/<host>/<org>/<repo>/<UTC time>/      for a Git URL, e.g. github.com/octocat/Spoon-Knife
~/scan-results/local/<path>/<UTC time>/             for a folder on the box
```

| File | Contents |
|---|---|
| `SCAN-INFO.json` | The repository, commit, harness commit, model, kit version, start and end times, and `status` (`ok`, or `failed` with the step and reason). |
| `THREAT_MODEL.md` | The threat model the scan built. |
| `VULN-FINDINGS.json`, `VULN-FINDINGS.md` | Candidate vulnerabilities from reading the code. |
| `TRIAGE.json`, `TRIAGE.md` | The triaged findings. |
| `threat-model.log`, `vuln-scan.log`, `triage.log` | Each step's output. |

The findings come from reading the code, not from running it. Treat them, and anything the agent wrote, as
untrusted until you've reviewed them. To work on the findings with Claude, run `claude` in the harness folder
(`~/defending-code-reference-harness`). In that interactive use, Claude Code runs as you, with your
permissions and sign-in, so review what it asks to run.

## The autonomous pipeline

The harness's autonomous pipeline builds the target and runs it to confirm findings. As shipped, it covers
C/C++ memory bugs; the harness README explains how to adapt it to other languages. It needs Docker and runs
its agents in the harness's own gVisor sandbox:

```
scan-harness.sh sandbox            # once per box: Docker, Python 3.12, the sandbox and a Bedrock key
scan-harness.sh run drlibs         # a run; the default arguments are --runs 2 --parallel --stream --auto-focus
```

The pipeline's agents use a Bedrock API key minted from your sign-in, stored in
`~/.config/dcrh/bedrock.env`. It lasts as long as your sign-in session, up to 12 hours. `run` refuses to start
when less than 30 minutes remain: sign in again, then run `scan-harness.sh token`.

## Settings

Set these as environment variables before the command, for example `MODEL=<id> scan-harness.sh scan <url>`:

| Variable | Default | Use |
|---|---|---|
| `MODEL` | The shared stack's `ClaudeModel` | The Bedrock inference profile for the scan and its subagents. The pipeline requires one. |
| `RESULTS_DIR` | `~/scan-results` | Where results go. |
| `HARNESS_REF` | The commit the kit was tested with | The harness commit `setup` checks out. `HARNESS_REF=main scan-harness.sh setup` moves to the latest; review it first. |
| `HARNESS_DIR` | `~/defending-code-reference-harness` | Where the harness is cloned. |
| `AWS_REGION` | The box's Region | The Region for Bedrock calls. |

## Updating

- **The helper and the isolated scan user:** after you upload a new kit version, run
  `sudo claude-scan-bootstrap --only harness` on a running box. It downloads the helper from the kit bucket,
  reinstalls `claude-scanner`'s Claude Code, reloads its firewall rules, and checks out the pinned harness
  commit again.
- **The harness:** `HARNESS_REF=<commit> scan-harness.sh setup`.

## Troubleshooting

| Message | Fix |
|---|---|
| `harness not found at ... (run setup first)` | Run `scan-harness.sh setup`. |
| `the claude-scanner user is missing` or `Bedrock key tool missing` | Run `sudo claude-scan-bootstrap --only harness`. |
| `the claude-scanner firewall rules aren't loaded` | Run `sudo systemctl restart claude-scan-scanner-firewall`. |
| `bedrock-runtime... doesn't resolve to a VPC endpoint` | The VPC has no `bedrock-runtime` endpoint, so isolated scans can't reach Bedrock. Add the `bedrock-runtime` and `bedrock` endpoints (shared stack `InterfaceEndpoints`). |
| `could not mint a Bedrock API key` or `no AWS credentials` | Sign in (login banner, step 1), then rerun the scan. |
| `<step>: <file> wasn't written` or `isn't complete` | The step ended without a complete report. Read `<step>.log` in the results folder, then rerun the scan. |
| `git clone failed` | Check the URL, and for a private repository, your Git credentials on the box. |
| `Bedrock key expires within 30 min` (pipeline) | Sign in again, then run `scan-harness.sh token`. |
| `the pipeline needs a model` | Set `MODEL=<inference profile ID>`, or set `ClaudeModel` in the shared stack. |

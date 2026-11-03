# Dashboards

With the shared stack's `ConfigureAnalytics` parameter, the kit adds Amazon Athena tables over the
telemetry bucket and two Amazon Managed Grafana dashboards. The telemetry stays where it is: Athena reads
the objects in the bucket, and nothing is copied to another store.

- [What you get](#what-you-get)
- [Before you start](#before-you-start)
- [Turn it on](#turn-it-on)
- [Set up Grafana](#set-up-grafana)
- [Use your own Grafana workspace](#use-your-own-grafana-workspace)
- [Query the data yourself](#query-the-data-yourself)
- [How it works](#how-it-works)
- [Costs](#costs)
- [Turn it off](#turn-it-off)
- [Troubleshooting](#troubleshooting)

## What you get

| Dashboard | Shows | Content |
|---|---|---|
| **Claude Code usage** | Cost, tokens, sessions and active users; cost per user and tokens by type over time; cost and tokens by user and model; active time, sessions and lines changed per user; tool calls and success rates; permission decisions. | No prompt or tool content. |
| **Claude Code activity** | Sessions, then the prompts in the selected session, then the selected prompt as a trace (each model call, and each tool call with its permission decision and run) and as a transcript of every event in order. Also rejected tool requests and model errors across all sessions. | Prompt text, commands and responses. Share it only with the people who can read the telemetry bucket. |

Both dashboards filter by owner and by the time range you pick. In the activity dashboard, click a session
to see its prompts, and click a prompt to see its trace and transcript; the **Session** and **Prompt**
selectors at the top do the same and start on the latest. The Athena tables and views are also available
for your own queries.

## Before you start

- **The kit's telemetry bucket.** When the shared stack creates the bucket, turning this on also lets the
  analytics roles read it. With your own bucket (`CreateBucket = No`), make sure its bucket policy allows the
  two roles named in [Turn it on](#turn-it-on).
- **For the Grafana workspace:** IAM Identity Center, which needs AWS Organizations. Users sign in to
  Grafana with Identity Center; Amazon Managed Grafana doesn't accept IAM users. With the kit's `IamUser`
  sign-in mode, use your own Grafana workspace with SAML, or query Athena directly.
- **`jq` and `curl`** on the computer you run `deploy.sh` from (CloudShell has both).

## Turn it on

Update the shared stack (CloudFormation → the stack → **Update** → **Use existing template** after uploading
the current kit):

| Parameter | Value |
|---|---|
| `ConfigureAnalytics` | `Yes` |
| `CreateGrafanaWorkspace` | `Yes` to create an Amazon Managed Grafana workspace; `No` to [use your own](#use-your-own-grafana-workspace) |

This adds a nested stack with the Athena tables and views, an Athena workgroup with its own encrypted
results bucket, and the workspace. It also adds these two roles to the principals the telemetry bucket
policy lets read:

- `claude-scan-platform-analytics-<region>`: lists the owner folders (`claude-code/<owner>/`) to keep the
  tables current. Its policy allows only that listing.
- `claude-scan-platform-grafana-<region>`: the workspace's role. It reads the telemetry through Athena.

The bucket's access logs record their reads, like any administrator's. Query results contain prompt text,
so the results bucket uses the same KMS key as the telemetry and deletes results after 7 days.

## Set up Grafana

1. **Assign users.** Amazon Managed Grafana console → the workspace (shared stack **Outputs** →
   `GrafanaWorkspaceId`) → **Authentication** → **IAM Identity Center** → **Assign new user or group**.
   Make yourself an **Admin**, and the others **Viewers**. From the command line:
   `aws grafana update-permissions --workspace-id <id> --update-instruction-batch 'action=ADD,role=ADMIN,users=[{id=<Identity Center user ID>,type=SSO_USER}]'`.
2. **Add the data source and dashboards:**

   ```
   ./deploy.sh grafana-setup
   ```

   It uses a 15-minute token for the workspace's API to add the Athena data source ("Claude scan
   telemetry"), installing the Athena plugin first if the workspace doesn't have it, and imports
   `dashboards/claude-code-usage.json` and `dashboards/claude-code-activity.json`. Run it again after
   updating the kit to refresh the dashboards.
3. **Open the dashboards:** shared stack **Outputs** → `GrafanaWorkspaceUrl`, sign in with Identity Center,
   then **Dashboards**.

Without `deploy.sh`: in Grafana, add an **Amazon Athena** data source (authentication: workspace IAM role;
data catalog `AwsDataCatalog`; the database and workgroup from the shared stack's **Outputs** →
`AnalyticsDatabase` and `AnalyticsWorkGroup`), then **Dashboards** → **New** → **Import** each JSON file.

## Use your own Grafana workspace

With `CreateGrafanaWorkspace = No`:

1. Attach the policy in the shared stack's **Outputs** → `GrafanaAccessPolicyArn` to your workspace's IAM
   role.
2. Add that role's ARN to the shared stack's `AdminPrincipalArnPatterns`, so the bucket policy lets it read.
3. Add the Athena data source and import the dashboards as above (without `deploy.sh`).

## Query the data yourself

In the Athena console, choose the workgroup and database from the shared stack's **Outputs**
(`AnalyticsWorkGroup`, `AnalyticsDatabase`). The views flatten the OpenTelemetry records:

| View | One row per | Main columns |
|---|---|---|
| `prompts` | prompt | `owner`, `event_time`, `session_id`, `prompt_id`, `prompt`, `prompt_length` |
| `responses` | response | `model`, `response` |
| `tool_calls` | tool Claude ran | `tool_name`, `success`, `duration_ms`, `tool_parameters`, `tool_input` |
| `tool_decisions` | permission decision | `tool_name`, `decision`, `source`, `tool_parameters` |
| `api_requests` | model call | `model`, `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_creation_tokens`, `cost_usd`, `duration_ms` |
| `api_errors` | failed model call | `model`, `error`, `status_code` |
| `usage` | metric data point | `metric` (for example `claude_code.cost.usage`), `model`, `type`, `session_id`, `value` |
| `events` | any event | `event_name`, `seq` (order within the session), `attrs` (all attributes, as a map) |
| `spans` | trace span | `trace_id`, `span_id`, `parent_span_id`, `name` (for example `claude_code.tool`), `start_time`, `duration_ms`, `status_code`, `attrs` |

The event views also have `session_id`, `prompt_id` and `trace_id`. One trace covers one prompt, so
`trace_id` links a prompt to its model calls, tool calls and responses.

Every view has `owner` and `dt`, the hour the data was written (`year=2026/month=11/day=02/hour=21`). Filter
on `dt` so Athena reads only those hours:

```sql
SELECT owner, round(sum(cost_usd), 2) AS cost_usd
FROM api_requests
WHERE dt >= date_format(now() - interval '7' day, 'year=%Y/month=%m/day=%d/hour=%H')
GROUP BY owner ORDER BY 2 DESC
```

## How it works

- The tables use partition projection on `owner` and `dt`, so new hours of data are queryable as soon as
  they're written, without a crawler.
- Athena can't discover owner folders by itself. A Lambda function adds new owners to the tables every
  15 minutes, so a new user's data appears within 15 minutes. It never removes an owner, so users whose
  boxes are gone stay in the dashboards.
- The same function creates the views when the stack is deployed.
- The workgroup stops any single query at 10 GB scanned.

## Costs

- **Athena:** per TB of data scanned. Dashboard queries read only the hours in the selected time range.
- **Amazon Managed Grafana:** per workspace per month, $9 per active editor or admin and $5 per active viewer, with
  at least one editor license ($9) even if nobody signs in. Service accounts count as users: the one
  `deploy.sh grafana-setup` uses is billed as an editor in months you run it.
- **Lambda and the results bucket:** negligible.

## Turn it off

Set `ConfigureAnalytics = No`. The stack deletes the tables, views, workgroup, results bucket, roles and
the Grafana workspace (with any changes you made in it; the dashboard files stay in the repository), and
removes the two roles from the bucket policy. The telemetry isn't touched.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Panels are empty | Widen the time range, and check the **Owner** selector. A user's first data appears within 15 minutes. |
| `Access Denied` reading the telemetry | The role must be allowed by the bucket policy (`AdminPrincipalArnPatterns`) and the KMS key. With your own bucket or workspace, see [Before you start](#before-you-start) and [Use your own Grafana workspace](#use-your-own-grafana-workspace). |
| `Query exhausted bytes scanned limit` | The query read more than 10 GB. Narrow the time range or the owners. |
| Can't sign in to Grafana | Assign the user to the workspace (Set up Grafana, step 1). |
| `deploy.sh grafana-setup`: `the shared stack has no Grafana workspace` | Set `ConfigureAnalytics = Yes` and `CreateGrafanaWorkspace = Yes`, or use your own workspace. |

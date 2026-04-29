# Jira Activity Pipeline to BigQuery

## Context

The team wants to measure AI-assisted SDLC work by analyzing Jira issue lifecycle data (status transitions, cycle time, throughput, velocity). The existing BigQuery data lake handles operational diagnostics via Cloud Logging sinks, but Jira data requires a different pattern — scheduled pull-based ETL from an external API.

**Scope**: 1-3 Jira Cloud projects, <5K issues. Daily batch extraction. Cost: ~$0/month (GCP free tiers).

## Architecture

```
Cloud Scheduler (daily cron)
    │
    ▼
Cloud Function 2nd Gen (Python)
    ├── Read watermark from GCS (last extraction timestamp)
    ├── Query Jira REST API v3: issues updated since watermark
    │     GET /rest/api/3/search?expand=changelog
    │     JQL: project in (GCP,...) AND updated >= "{watermark}"
    ├── Transform: flatten changelog → event rows, build snapshots
    ├── Write NDJSON to GCS: gs://bucket/jira-events/YYYY/MM/DD/
    ├── Trigger BigQuery load jobs from GCS files
    └── Update watermark on success
```

**Key decision**: New Terraform module (`jira-activity-pipeline/`), not an extension of `data-lake/`. Different pattern (pull ETL vs push streaming), different dataset (`sdlc_metrics` vs `data_lake`), different access controls.

## Data Model

**Table 1: `jira_issue_events`** — one row per field change (flattened changelog)

| Column | Type | Description |
|--------|------|-------------|
| event_id | STRING | `{issue_id}_{history_id}_{item_index}` |
| event_timestamp | TIMESTAMP | When the change happened |
| issue_key | STRING | e.g., GCP-123 |
| issue_id | STRING | Jira internal ID |
| project_key | STRING | e.g., GCP |
| issue_type | STRING | Story, Bug, Epic, etc. |
| author_display_name | STRING | Who made the change |
| author_account_id | STRING | Jira account ID |
| field_name | STRING | e.g., status, assignee, priority |
| field_type | STRING | jira or custom |
| from_value / to_value | STRING | Value IDs |
| from_string / to_string | STRING | Human-readable values |
| extracted_at | TIMESTAMP | Extraction time |

Partitioned by `event_timestamp`, clustered by `project_key, issue_key, field_name`.

**Table 2: `jira_issue_snapshots`** — current state of each issue

| Column | Type | Description |
|--------|------|-------------|
| issue_key, issue_id, project_key | STRING | Identifiers |
| summary, status, issue_type, priority | STRING | Current state |
| assignee, reporter | STRING | People |
| created, updated, resolved | TIMESTAMP | Dates |
| labels, components | STRING REPEATED | Tags |
| sprint_name | STRING | Current sprint |
| story_points | FLOAT64 | Points |
| parent_key | STRING | Epic/parent link |
| extracted_at | TIMESTAMP | Extraction time |

Partitioned by `extracted_at`, clustered by `project_key, status, issue_type`.

**Pre-built views**: `view_cycle_time`, `view_lead_time`, `view_throughput`, `view_status_duration`.

## File Organization

All new files in `gcp-hcp-infra/`:

```
terraform/modules/jira-activity-pipeline/
  main.tf          # BQ dataset, tables, views, GCS bucket
  function.tf      # Cloud Function 2nd gen + Cloud Scheduler
  iam.tf           # Service account, IAM bindings
  secrets.tf       # Secret Manager for Jira API token
  variables.tf     # Module inputs
  outputs.tf       # Module outputs
  versions.tf      # Provider requirements

agent/jira-activity/
  main.py          # Cloud Function entry point (HTTP handler)
  jira_client.py   # Jira API wrapper (auth, pagination, rate limiting)
  extract.py       # JQL search + changelog extraction
  transform.py     # Flatten changelog to events, build snapshots
  load.py          # Write NDJSON to GCS, trigger BQ load jobs
  watermark.py     # Incremental extraction watermark (GCS JSON file)
  schema.py        # Pydantic models (JiraIssueEvent, JiraIssueSnapshot)
  config.py        # Environment variable config
  requirements.txt # Python dependencies
  tests/           # Unit tests for each module
```

Module instantiation in `terraform/config/global/<env>/jira-pipeline.tf`.

## Implementation Steps

### Phase 1: Terraform Infrastructure
1. Create `terraform/modules/jira-activity-pipeline/variables.tf` — module inputs with `enabled` flag
2. Create `main.tf` — BigQuery dataset, both tables with explicit schemas, four views, GCS staging bucket
3. Create `iam.tf` — Service account (`jira-activity-pipeline`), BQ data editor, BQ job user, GCS object admin, Secret Manager accessor, Cloud Function invoker
4. Create `secrets.tf` — Secret Manager secret resource for Jira API token
5. Create `function.tf` — Cloud Function 2nd gen + Cloud Scheduler (daily cron)
6. Create module instantiation in global config

### Phase 2: Python Cloud Function
7. Create `schema.py` — Pydantic models following existing `agent/diagnose/schema.py` pattern
8. Create `jira_client.py` — Jira REST API v3 wrapper with Basic Auth (email + API token from Secret Manager), pagination, rate limit retry (429), 5xx retry with exponential backoff
9. Create `extract.py` — JQL search with `expand=changelog`, configurable field list
10. Create `transform.py` — Flatten changelog histories into event rows, build issue snapshots
11. Create `watermark.py` — Read/write watermark JSON from GCS for incremental extraction
12. Create `load.py` — Write NDJSON to GCS, trigger BigQuery load jobs (APPEND for events, TRUNCATE for snapshots)
13. Create `main.py` — HTTP entry point, orchestrates extract→transform→load, supports `incremental` and `backfill` modes

### Phase 3: Testing
14. Unit tests for transform, extract, load, watermark, schema modules (mocked API/GCS/BQ clients)
15. Terraform plan-only tests (`basic.tftest.hcl`)

## Jira API Details

- **Auth**: Basic Auth — `email:api_token` (token from https://id.atlassian.com/manage-profile/security/api-tokens, stored in Secret Manager)
- **Search endpoint**: `GET /rest/api/3/search?jql=...&expand=changelog&maxResults=100`
- **Fields requested**: summary, status, issuetype, priority, assignee, reporter, created, updated, resolutiondate, labels, components, customfield_10016 (story points), customfield_10020 (sprint), parent
- **Pagination**: `startAt` + `maxResults`, iterate until `startAt + len >= total`
- **Rate limiting**: Retry on HTTP 429 with `Retry-After` header, exponential backoff on 5xx

## Error Handling & Idempotency

- **Watermark only updates on success** — failed runs re-extract the same window
- **Events use deterministic `event_id`** — duplicates from re-runs are handled by periodic dedup DML or `QUALIFY ROW_NUMBER()` in views
- **Snapshots use `WRITE_TRUNCATE`** — inherently idempotent
- **Cloud Scheduler retries once** on function failure

## Backfill

Trigger manually with `{"mode": "backfill"}` — skips watermark, extracts all issues. At <5K issues, completes well within Cloud Function's 9-minute timeout (~50 API calls at ~0.5s each).

## Key Reference Files

- `gcp-hcp-infra/terraform/modules/data-lake/main.tf` — BQ dataset/view patterns, label conventions
- `gcp-hcp-infra/terraform/modules/data-lake/variables.tf` — variable naming, enable flags
- `gcp-hcp-infra/agent/diagnose/schema.py` — Pydantic model pattern
- `gcp-hcp-infra/terraform/modules/region/agent.tf` — Secret Manager + IAM patterns
- `gcp-hcp-infra/terraform/modules/data-lake/tests/basic.tftest.hcl` — Terraform test pattern

## Verification

1. `terraform plan` — verify all resources are created correctly
2. Deploy to dev, populate Jira API token secret manually
3. Trigger backfill: `curl -X POST $FUNCTION_URL -H "Authorization: bearer $(gcloud auth print-identity-token)" -d '{"mode":"backfill"}'`
4. Verify GCS files: `gsutil ls gs://bucket/jira-events/`
5. Verify BQ data: `bq query "SELECT COUNT(*) FROM sdlc_metrics.jira_issue_events"`
6. Verify views: `bq query "SELECT * FROM sdlc_metrics.view_cycle_time LIMIT 5"`
7. Wait for scheduled run, confirm incremental extraction (watermark advances, only changed issues re-extracted)

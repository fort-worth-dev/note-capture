# Phase 1 Plan Review

## Summary

The plan is directionally solid: it keeps Phase 1 focused on capture, persistence, and Notion sync while postponing retrieval/chat complexity. The main issues are not architectural ambition; they are contract mismatches and missing operational details that will cause implementation churn unless resolved before coding.

## Findings

### 1. `POST /sources` contract conflicts with the pipeline and goal

References: `phase-1-plan.md:3`, `phase-1-plan.md:44`, `phase-1-plan.md:164`, `phase-1-plan.md:171`, `phase-1-plan.md:175`

The plan says the FastAPI endpoint is synchronous through enrichment and the user waits for the summary, but the API surface says `POST /sources` returns `202 + source_id` and the client polls. The build order also says the happy path returns the summary directly.

Pick one contract before implementation. I recommend the `202 + source_id` model:

- `POST /sources` validates auth and URL, inserts a `processing` source row immediately, starts the capture job, and returns `{source_id}`.
- `GET /sources/{id}` is the only place the frontend reads `processing`, `ready`, or `failed`.
- The "within ~10 seconds" goal should become a target for the source transitioning to `ready`, not for the initial POST response.

This also removes ambiguity around frontend behavior and backend timeout handling.

### 2. Failure handling cannot work before a source row exists

References: `phase-1-plan.md:55`, `phase-1-plan.md:68`, `phase-1-plan.md:96`, `phase-1-plan.md:117`, `phase-1-plan.md:120`

The graph sends errors from every node to `mark_failed`, which updates `sources.status = 'failed'`. But `persist` appears late in the graph, after classify/fetch/enrich. If fetching or enrichment fails before `persist`, there is no source row to mark failed. The state also lacks `source_id`.

Fix by splitting persistence into two phases:

- Insert a `sources` row before running the graph, with `status = 'processing'`, `url`, `user_id`, and maybe provisional `content_type`.
- Add `source_id` to `CaptureState`.
- Have the graph update that row on success or failure.
- Keep tag creation/linking in the success path after enrichment.

This is especially important if `POST /sources` returns `202`, because the frontend needs a stable row to poll immediately.

### 3. RLS/backend auth strategy is underspecified and could be bypassed accidentally

References: `phase-1-plan.md:8`, `phase-1-plan.md:93`, `phase-1-plan.md:133`, `phase-1-plan.md:134`, `phase-1-plan.md:176`

The plan says Supabase RLS should filter reads/writes by `auth.uid()`, but the backend uses FastAPI plus `asyncpg`. If the backend connects directly to Postgres with a service role or privileged connection, Supabase RLS may not protect application queries the way it would through Supabase client/PostgREST.

Before coding, decide and document one of these patterns:

- Use backend service credentials and enforce ownership in every SQL query and mutation (`where user_id = $auth_user_id`), treating RLS as defense-in-depth where applicable.
- Or connect/query in a way that preserves the end user's JWT claims for RLS enforcement.

Also add explicit RLS policies for `profiles`, `tags`, and `source_tags`, not just `sources`. `source_tags` joins can leak relationships unless policies are defined around the owning source/tag.

### 4. Notion integration fields are described but absent from the schema

References: `phase-1-plan.md:49`, `phase-1-plan.md:64`, `phase-1-plan.md:118`, `phase-1-plan.md:125`, `phase-1-plan.md:126`, `phase-1-plan.md:184`

The plan says to store `profiles.notion_database_id` and an encrypted Notion access token, but `profiles` only has `id`, `email`, and `created_at`. The pipeline also says `queue_notion_sync` drops a job row, but no job table exists.

Add the missing persistence design:

- `profiles.notion_database_id text`
- a separate `notion_connections` table or encrypted token fields on `profiles`
- token encryption approach and key source
- either a real `notion_sync_jobs` table or a clear statement that the worker scans `sources where notion_sync_status = 'pending'`

If retries are required, model `attempt_count`, `next_attempt_at`, `last_error`, and a lock/lease field. `FastAPI BackgroundTasks` alone does not give durable retries after process restarts.

### 5. The timing target is inconsistent

References: `phase-1-plan.md:3`, `phase-1-plan.md:171`, `phase-1-plan.md:191`

The goal says the user sees the finished entry within `~10 seconds`, the API section says enrichment takes `5-15 seconds`, and the done criteria say `~15 seconds`. That difference matters for UX and timeout budgets.

Use one acceptance criterion, preferably:

> For typical HTML pages under the configured content limit, the source reaches `ready` within 15 seconds; slower captures remain visible as `processing`.

PDFs and YouTube transcripts should probably have a looser target because download/extraction/transcript availability will vary.

### 6. URL fetching needs explicit safety and resource limits

References: `phase-1-plan.md:10`, `phase-1-plan.md:108`, `phase-1-plan.md:111`, `phase-1-plan.md:113`

The fetcher plan covers libraries but not guardrails. Since users submit arbitrary URLs, add implementation requirements for:

- allowed schemes: `http` and `https` only
- SSRF protection for localhost, private IP ranges, link-local ranges, and metadata endpoints
- request timeout and redirect limit
- maximum download size
- maximum extracted text length sent to Claude
- content-type validation for PDFs

These are Phase 1 concerns because the feature accepts untrusted URLs from day one.

### 7. Scope says "one real endpoint" but the API surface has several

References: `phase-1-plan.md:9`, `phase-1-plan.md:163`

This is minor, but it will confuse build sequencing. The actual Phase 1 surface includes source create/list/detail/delete, Notion OAuth, and health. Rephrase the scope as "one primary workflow" or "one write endpoint for capture" rather than "one real endpoint."

## Recommended Plan Adjustments

1. Define `POST /sources` as `202` only, with immediate row creation.
2. Add `source_id` to pipeline state and make the graph update an existing source row.
3. Expand schema for Notion database/token storage and durable sync retry state.
4. Document the exact backend auth/RLS enforcement model.
5. Add RLS policies for every user-owned table.
6. Add URL fetcher safety limits before implementing HTML/PDF/YouTube fetchers.
7. Normalize the done criterion around a 15-second target for normal HTML captures.

## Revised Minimal Flow

1. User submits URL from the frontend.
2. Backend verifies Supabase JWT.
3. Backend validates URL and inserts `sources(status = 'processing')`.
4. Backend starts the capture pipeline and returns `202 { source_id }`.
5. Pipeline fetches content, enriches it, writes summary/key concepts/tags, and marks the source `ready`.
6. On any failure, pipeline marks the existing source `failed` with `error_message`.
7. Notion sync runs durably from pending source/job state and updates `notion_sync_status`.

## Verdict

Proceed with the plan after tightening the contracts above. The biggest implementation risk is not LangGraph or Notion; it is starting without a precise source lifecycle and auth/RLS strategy. Fix those first and the rest of Phase 1 becomes straightforward to build incrementally.

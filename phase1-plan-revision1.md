# Phase 1 Implementation Plan, Revision 1: Capture Pipeline

## Goal

End of Phase 1: a logged-in user pastes a URL into a web form, immediately sees a new `processing` entry, and for typical HTML pages sees it transition to `ready` within about 15 seconds with an AI-generated title, summary, key concepts, and suggested tags. The source is persisted in Postgres first and synced to Notion durably afterward.

No embeddings, retrieval, chat, browser extension, reverse Notion sync, team workspaces, or wiki generation in Phase 1.

## Scope

In:

- Supabase auth using email magic links.
- FastAPI backend for the capture workflow.
- Postgres persistence using Supabase-managed Postgres.
- LangGraph-based capture pipeline.
- Content fetching for HTML, YouTube transcripts, and PDFs.
- AI enrichment with structured output from Claude.
- Durable Notion sync after capture.
- Next.js frontend with login, URL form, source list, source detail, and status/error states.
- Local development with docker-compose.
- Deployment targets identified: Vercel for frontend, Railway or similar for backend, Supabase for Postgres/auth.

Out:

- Embeddings, pgvector, similarity search.
- Chat or Q&A.
- Browser extension.
- Reverse sync from Notion to Postgres.
- Multi-member workspaces.
- Wiki generation.
- Production-grade queue infrastructure unless the lightweight durable sync table proves insufficient.

## Architecture

```text
┌─────────────┐      ┌──────────────┐      ┌─────────────┐
│  Next.js    │─────▶│   FastAPI    │─────▶│  Postgres   │
│  frontend   │      │   backend    │      │ (Supabase)  │
└──────┬──────┘      └──────┬───────┘      └──────┬──────┘
       │                    │                     │
       │ Supabase Auth      │ LangGraph capture   │ durable state
       │                    ▼                     │
       │             ┌──────────────┐             │
       │             │   Claude     │             │
       │             └──────────────┘             │
       │                    │                     │
       │                    ▼                     │
       │             ┌──────────────┐             │
       └────────────▶│    Notion    │◀────────────┘
                     │     API      │
                     └──────────────┘
```

The backend does not hold the create request open while enrichment runs. `POST /sources` creates the source row, starts capture work, and returns `202 { source_id }`. The frontend polls `GET /sources/{id}` until the row becomes `ready` or `failed`.

Postgres is the source of truth. Notion is a synced destination. If Notion is down, rate-limited, or disconnected, capture still succeeds and Notion sync remains pending or failed with retry metadata.

## Source Lifecycle

1. Frontend submits a URL with the user's Supabase access token.
2. Backend verifies the JWT and extracts `user_id`.
3. Backend validates the URL and inserts a `sources` row with `status = 'processing'`.
4. Backend starts the LangGraph capture pipeline with `source_id`, `user_id`, and `url`.
5. Backend returns `202 { source_id }`.
6. Frontend adds the source optimistically and polls `GET /sources/{id}`.
7. Pipeline classifies, fetches, enriches, persists enrichment fields/tags, and marks the source `ready`.
8. On any pipeline failure, the existing source row is marked `failed` with `error_message`.
9. Notion sync is queued after a source reaches `ready`.

## Data Model

```sql
-- Supabase auth.users remains the auth source of truth.
-- profiles mirrors the minimal user data needed for app FKs and integrations.

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  notion_database_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table notion_connections (
  user_id uuid primary key references profiles(id) on delete cascade,
  workspace_id text,
  workspace_name text,
  bot_id text,
  access_token_encrypted text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table sources (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  url text not null,
  content_type text check (content_type in ('html','youtube','pdf','text')),
  title text,
  raw_content text,
  summary text,
  key_concepts jsonb not null default '[]'::jsonb,
  notion_page_id text,
  notion_sync_status text not null default 'not_queued'
    check (notion_sync_status in ('not_queued','pending','synced','failed')),
  notion_sync_error text,
  status text not null default 'processing'
    check (status in ('processing','ready','failed')),
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table tags (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  unique (user_id, name)
);

create table source_tags (
  source_id uuid not null references sources(id) on delete cascade,
  tag_id uuid not null references tags(id) on delete cascade,
  applied_by text not null check (applied_by in ('ai','user')),
  confidence real,
  created_at timestamptz not null default now(),
  primary key (source_id, tag_id)
);

create table notion_sync_jobs (
  id uuid primary key default gen_random_uuid(),
  source_id uuid not null references sources(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending','running','succeeded','failed')),
  attempt_count integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  locked_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index sources_user_created on sources(user_id, created_at desc);
create index sources_status on sources(status);
create index sources_notion_pending on sources(notion_sync_status)
  where notion_sync_status = 'pending';
create index notion_sync_jobs_ready on notion_sync_jobs(next_attempt_at, status)
  where status in ('pending','failed');
```

Access tokens must be encrypted before storage. The encryption key should come from backend environment configuration, not the database.

## Auth And Authorization

The frontend authenticates users with Supabase Auth and sends the access token to FastAPI.

FastAPI verifies the Supabase JWT in `auth.py`. All application queries use the verified `user_id` explicitly:

- Reads include `where user_id = $user_id`.
- Writes set `user_id` from the verified token, never from request bodies.
- Updates and deletes include ownership predicates.

Enable RLS on all user-owned tables as defense in depth:

- `profiles`
- `notion_connections`
- `sources`
- `tags`
- `source_tags`
- `notion_sync_jobs`

The implementation must not assume RLS alone protects queries made through a privileged backend Postgres connection. Backend ownership checks are required either way.

## API Surface

```text
POST   /sources             Create source from URL. Returns 202 + source_id.
GET    /sources             List current user's sources.
GET    /sources/{id}        Get one source owned by current user.
DELETE /sources/{id}        Delete source and local tag links; archive/delete Notion page best-effort.
POST   /notion/connect      Start Notion OAuth.
GET    /notion/callback     Complete Notion OAuth.
GET    /healthz             Health check.
```

`POST /sources` response:

```json
{
  "source_id": "uuid",
  "status": "processing"
}
```

`GET /sources/{id}` returns the source lifecycle fields, enrichment fields when ready, and Notion sync status.

## LangGraph Capture Pipeline

State:

```python
class CaptureState(TypedDict):
    source_id: str
    user_id: str
    url: str
    content_type: Literal["html", "youtube", "pdf", "text"] | None
    raw_content: str
    title: str
    summary: str
    key_concepts: list[str]
    suggested_tags: list[str]
    error: str | None
```

Nodes:

- `classify_url`: determines `content_type` without an LLM.
- `fetch_content`: fetches and extracts text based on content type.
- `enrich`: calls Claude once and validates structured output with Pydantic.
- `persist_success`: updates the existing source row to `ready`, writes title/content/summary/key concepts, creates tags, and links source tags in one transaction.
- `queue_notion_sync`: inserts a `notion_sync_jobs` row and sets `sources.notion_sync_status = 'pending'` if the user has connected Notion.
- `mark_failed`: updates the existing source row to `failed` with an error message.

Every node has an error edge to `mark_failed`. Because the source row exists before the graph starts, failures are visible to the frontend.

Use LangSmith tracing from the first LangGraph implementation. Checkpointing is optional for Phase 1 unless it is cheap to enable with the chosen LangGraph setup.

## Fetcher Requirements

All URL fetchers must enforce:

- allowed schemes: `http` and `https`
- rejection of localhost, private IP ranges, link-local ranges, and cloud metadata addresses
- request timeout
- redirect limit
- maximum download size
- maximum extracted text length sent to Claude
- useful error messages for unsupported or unavailable content

HTML:

- use `httpx` for fetching
- use `trafilatura` for extraction
- store the extracted text in `raw_content`, not the full HTML

YouTube:

- classify common YouTube URL forms
- use `youtube-transcript-api`
- fail clearly when no transcript is available

PDF:

- validate content type or URL shape before extraction
- download with size limits
- use `pypdf` for text extraction
- fail clearly for encrypted or non-text PDFs

## AI Enrichment

Use a single Claude call with structured output validated by Pydantic.

Expected output:

```json
{
  "title": "string",
  "summary": "string",
  "key_concepts": ["string"],
  "suggested_tags": ["string"]
}
```

Validation rules:

- title is required but may fall back to fetched metadata or URL if the model omits it
- summary is required
- key concepts should target about 5 items
- suggested tags should target about 3 items
- tag names should be normalized before insert, for example trim whitespace and collapse repeated spaces

## Notion Integration

User connects Notion through OAuth. Store the encrypted access token in `notion_connections` and the per-user database ID in `profiles.notion_database_id`.

One Notion database is created per user on first successful connection or first sync after connection. Database properties:

| Property | Type |
| --- | --- |
| Title | title |
| URL | url |
| Summary | rich_text |
| Key Concepts | multi_select |
| Tags | multi_select |
| Captured | date |
| Source Type | select |

The page body contains the summary and key concepts as readable blocks. Postgres remains authoritative.

Sync behavior:

- capture does not require Notion to be connected
- if Notion is connected, successful capture enqueues a sync job
- worker claims due jobs using a lock/lease
- failed sync increments `attempt_count`, stores `last_error`, updates `next_attempt_at`, and sets the source sync status to `failed` or leaves it pending based on retry policy
- successful sync stores `notion_page_id` and sets `notion_sync_status = 'synced'`

For Phase 1, the worker can be a simple backend process or scheduled loop. It should use the database job table rather than relying only on in-process `BackgroundTasks`.

## Frontend

Pages:

- login/logout flow using Supabase magic links
- `/sources`: list of captured sources with status, title/URL, created time, tags, and Notion sync indicator
- `/sources/new`: paste URL form
- `/sources/[id]`: detail view with summary, key concepts, tags, original URL, content type, and error state

Behavior:

- after `POST /sources`, immediately show the new source as `processing`
- poll `GET /sources/{id}` until `ready` or `failed`
- show fetch/enrichment failures without losing the original URL
- show Notion disconnected, pending, synced, and failed states separately from capture status

## Project Layout

```text
notes/
├── backend/
│   ├── app/
│   │   ├── main.py
│   │   ├── config.py
│   │   ├── auth.py
│   │   ├── db.py
│   │   ├── models.py
│   │   ├── routes/
│   │   │   ├── sources.py
│   │   │   └── notion.py
│   │   ├── pipeline/
│   │   │   ├── graph.py
│   │   │   ├── nodes.py
│   │   │   └── state.py
│   │   ├── integrations/
│   │   │   ├── notion.py
│   │   │   └── fetchers.py
│   │   └── workers/
│   │       └── notion_sync.py
│   ├── migrations/
│   ├── pyproject.toml
│   └── Dockerfile
├── frontend/
│   ├── app/
│   │   ├── (auth)/
│   │   ├── sources/
│   │   │   ├── page.tsx
│   │   │   ├── new/page.tsx
│   │   │   └── [id]/page.tsx
│   │   └── layout.tsx
│   ├── components/
│   ├── lib/
│   │   └── supabase.ts
│   └── package.json
├── docker-compose.yml
└── README.md
```

Use `uv` for Python dependency management and `pnpm` for frontend dependency management.

## Build Order

1. Infrastructure skeleton: create Supabase project, migrations, FastAPI app, docker-compose, Next.js app, and Supabase login/logout.
2. Authenticated source lifecycle: implement JWT verification, `POST /sources`, immediate row creation, `GET /sources`, and `GET /sources/{id}` with ownership checks.
3. HTML capture happy path: implement safe URL validation, HTML fetch/extraction, Claude enrichment, success/failure source updates, and polling UI.
4. Tags and structured persistence: create tags/source tags transactionally from enrichment output.
5. LangGraph refactor: move the working linear capture flow into LangGraph with `source_id` in state, error edges, and LangSmith tracing.
6. Notion OAuth and durable sync: implement connection storage, database creation, sync jobs, worker loop, retry metadata, and status display.
7. YouTube and PDF fetchers: add classification branches, extraction, limits, and representative tests.
8. Frontend completion: detail page, delete action, optimistic list behavior, error states, and Notion sync indicators.
9. Deployment pass: document env vars, deploy targets, and run through the done checklist.

## Key Decisions

`202 + polling` over synchronous POST:

Capture can take longer than normal request budgets, especially for PDFs and transcripts. A durable source row gives the UI something stable to show and gives failures a place to land.

Postgres over Notion as primary store:

Postgres provides ownership checks, indexes, joins, and future retrieval support. Notion is useful as a destination but weak as the canonical database.

Backend ownership checks plus RLS:

FastAPI should not rely on implicit database session state for security. Verified `user_id` must be applied directly in SQL queries and mutations. RLS still belongs in the schema as another layer.

Durable sync table over only `BackgroundTasks`:

In-process background work is fine for short-lived local behavior but does not survive restarts. A small job table is enough for Phase 1 and avoids introducing Redis/Celery too early.

LangGraph is deliberate practice:

The graph is more structure than Phase 1 strictly needs, but it prepares the codebase for later retrieval and wiki-generation flows while keeping the first graph simple.

## Done Criteria

- I can sign in with a Supabase email magic link.
- I can connect Notion through OAuth.
- I can paste `https://karpathy.github.io/2015/05/21/rnn-effectiveness/`.
- A `processing` source appears immediately.
- For that typical HTML page, the source becomes `ready` within about 15 seconds.
- The ready source has title, summary, key concepts, and suggested tags in Postgres.
- The same source syncs to the user's Notion database, or shows a clear Notion sync error while remaining captured in Postgres.
- I can paste a YouTube URL with an available transcript and get the same capture flow.
- I can paste a text-based PDF URL and get the same capture flow.
- Fetch/enrichment failures produce a visible failed source with a useful error message.
- LangSmith shows a trace for each capture run.

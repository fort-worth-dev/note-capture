Phase 1 Implementation Plan: Capture Pipeline
Goal
End of Phase 1: a logged-in user pastes a URL into a web form, and within ~10 seconds sees a new entry appear with an AI-generated summary, key concepts, and suggested tags — persisted in both Postgres and Notion.
No embeddings, no retrieval, no chat. Just frictionless capture done well.
Scope
In:

Supabase auth (email magic link to start)
FastAPI backend with one real endpoint: POST /sources
Content fetching for HTML, YouTube, PDF
LangGraph-based capture pipeline (overkill for now, deliberate practice)
Postgres persistence (Supabase-managed)
Notion sync as a background task
Next.js frontend: login, paste-URL form, list of captured sources
Local dev with docker-compose; deploy targets identified but not required

Out (Phase 2+):

Embeddings, pgvector, similarity search
Chat / Q&A
Browser extension (web form is enough for v1)
Reverse sync from Notion → Postgres
Workspaces with multiple members (single-tenant per user for now; schema supports multi-user later)
Wiki generation

Architecture
┌─────────────┐      ┌──────────────┐      ┌─────────────┐
│  Next.js    │─────▶│   FastAPI    │─────▶│  Postgres   │
│  (Vercel)   │      │  (Railway)   │      │ (Supabase)  │
└─────────────┘      └──────┬───────┘      └─────────────┘
       │                    │
       │ Supabase           │ LangGraph pipeline
       │ Auth               ▼
       │             ┌──────────────┐
       │             │   Claude     │
       │             │  (Anthropic) │
       │             └──────────────┘
       │                    │
       │                    ▼
       │             ┌──────────────┐
       └────────────▶│    Notion    │
                     │     API      │
                     └──────────────┘
The FastAPI endpoint is synchronous through the AI enrichment (user waits for the summary) but async-fires the Notion write. If Notion is down or rate-limited, the source is still captured — Notion sync retries in the background.
Data model (Phase 1 only)
sql-- Users come from Supabase auth.users
-- We mirror minimally into a profiles table for FK targets

create table profiles (
  id uuid primary key references auth.users(id),
  email text not null,
  created_at timestamptz default now()
);

create table sources (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id),
  url text not null,
  content_type text not null check (content_type in ('html','youtube','pdf','text')),
  title text,
  raw_content text,           -- the fetched text we ran through Claude
  summary text,
  key_concepts jsonb,         -- ["RAG", "tool use", ...]
  notion_page_id text,
  notion_sync_status text not null default 'pending'
    check (notion_sync_status in ('pending','synced','failed')),
  notion_sync_error text,
  status text not null default 'processing'
    check (status in ('processing','ready','failed')),
  error_message text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table tags (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id),
  name text not null,
  unique (user_id, name)
);

create table source_tags (
  source_id uuid references sources(id) on delete cascade,
  tag_id uuid references tags(id) on delete cascade,
  applied_by text not null check (applied_by in ('ai','user')),
  confidence real,
  primary key (source_id, tag_id)
);

create index sources_user_created on sources(user_id, created_at desc);
create index sources_notion_pending on sources(notion_sync_status)
  where notion_sync_status = 'pending';
Row-level security in Supabase: every read/write on sources filters by user_id = auth.uid(). Set this up from day one — retrofitting RLS is painful.
The LangGraph pipeline
State:
pythonclass CaptureState(TypedDict):
    url: str
    user_id: str
    content_type: Literal["html", "youtube", "pdf", "text"]
    raw_content: str
    title: str
    summary: str
    key_concepts: list[str]
    suggested_tags: list[str]
    error: str | None
Nodes:

classify_url — sniff the URL, decide content_type. Pure function, no LLM.
fetch_content — branches on content_type:

HTML: httpx + trafilatura for clean extraction
YouTube: youtube-transcript-api (fall back to a "couldn't get transcript" error)
PDF: httpx download + pypdf extraction


enrich — single Claude call with structured output (use the SDK's tool-call-as-schema pattern or just JSON mode with a Pydantic model). Returns {title, summary, key_concepts, suggested_tags}.
persist — write to Postgres in a transaction; create any new tags, link them.
queue_notion_sync — drop a job row; the background worker picks it up.

Error edges from every node go to a terminal mark_failed node that updates sources.status = 'failed'.
This is a straight-line graph for now. The reason to use LangGraph rather than a plain function: when Phase 2 adds retrieval and Phase 3 adds wiki generation, you'll already have the patterns (state, checkpointing, retries, LangSmith tracing) in muscle memory. Build the muscle on the easy task.
Notion structure
One Notion database per user, created on first capture. Schema:
PropertyTypeTitletitleURLurlSummaryrich_textKey Conceptsmulti_selectTagsmulti_selectCaptureddateSource Typeselect
The page body holds the full summary as rendered blocks. Store the database ID on profiles.notion_database_id.
User connects Notion via OAuth on first run; store the access token encrypted.
Project layout
notes/
├── backend/
│   ├── app/
│   │   ├── main.py              # FastAPI entry
│   │   ├── config.py            # pydantic-settings
│   │   ├── auth.py              # Supabase JWT verification
│   │   ├── db.py                # asyncpg pool
│   │   ├── models.py            # Pydantic request/response models
│   │   ├── routes/
│   │   │   └── sources.py
│   │   ├── pipeline/
│   │   │   ├── graph.py         # LangGraph definition
│   │   │   ├── nodes.py
│   │   │   └── state.py
│   │   ├── integrations/
│   │   │   ├── notion.py
│   │   │   └── fetchers.py      # html, youtube, pdf
│   │   └── workers/
│   │       └── notion_sync.py   # background task / cron
│   ├── migrations/              # using alembic or raw .sql
│   ├── pyproject.toml           # uv-managed
│   └── Dockerfile
├── frontend/
│   ├── app/
│   │   ├── (auth)/
│   │   ├── sources/
│   │   │   ├── page.tsx         # list view
│   │   │   └── new/page.tsx     # paste form
│   │   └── layout.tsx
│   ├── components/
│   ├── lib/supabase.ts
│   └── package.json
├── docker-compose.yml           # local postgres + backend
└── README.md
Use uv for Python deps — much faster than pip and the lockfile story is cleaner. Use pnpm on the frontend.
API surface (Phase 1)
POST   /sources           Create from URL. Returns 202 + source_id, client polls.
GET    /sources           List current user's sources.
GET    /sources/{id}      Single source detail.
DELETE /sources/{id}      Delete (cascades to source_tags, soft-delete Notion page).
POST   /notion/connect    Start Notion OAuth.
GET    /notion/callback   OAuth callback.
GET    /healthz
The POST /sources returning 202 is deliberate: enrichment takes 5–15 seconds and you don't want to hold an HTTP connection that long. Frontend polls GET /sources/{id} until status == 'ready'. (Alternative: SSE or WebSocket. Polling is fine for v1.)
Build order (recommended)
I'd do this in roughly seven sittings:
Sitting 1 — Infrastructure skeleton. Supabase project created, schema migrated, FastAPI hello-world deployed locally with docker-compose, Next.js scaffold with Supabase auth, login/logout works end-to-end. No business logic yet. The point is to verify the wiring before adding anything interesting.
Sitting 2 — Capture happy path, console-only. POST /sources accepts a URL, fetches HTML, calls Claude, returns the summary in the response. No DB write, no Notion. Just prove the pipeline works.
Sitting 3 — Persistence. Wrap the call in a transaction, write to sources and tags. Add GET /sources and GET /sources/{id}. RLS policies in place.
Sitting 4 — LangGraph refactor. Take the linear pipeline from sitting 2 and rebuild it in LangGraph with proper state, error edges, and LangSmith tracing. Behavior identical; structure improved. This is practice for Phase 2/3.
Sitting 5 — Notion integration. OAuth flow, database creation on first connect, sync-on-create. Background worker (FastAPI BackgroundTasks is fine for v1; move to a real queue later).
Sitting 6 — YouTube and PDF fetchers. Extend the fetch_content node to branch on content type. Test with a Karpathy YouTube video and an arXiv PDF — both will be in your real corpus.
Sitting 7 — Frontend polish. List view with status indicators, source detail page, paste-URL form with optimistic UI, error states. shadcn/ui components. Deploy frontend to Vercel, backend to Railway.
Key decisions and tradeoffs
Why Supabase over Clerk + separate Postgres? You get auth + Postgres + RLS + (later) pgvector + storage in one platform. One vendor for Phase 1 is the right call; you can always migrate auth to Clerk later if you outgrow it. The RLS-from-day-one story is also genuinely useful.
Why structured output via Pydantic over function calling? Either works. Pydantic-with-JSON-mode reads cleaner in Python and the validation errors are better. Use whatever the Anthropic SDK ergonomics favor at the time you build.
Why no queue (Redis/Celery) yet? FastAPI's BackgroundTasks runs in the same process — fine when you have one user and a few captures per day. The moment you have real load or want retries with backoff, swap in Arq (Redis-based, async-native, lightweight) or RQ. Don't preemptively build queue infrastructure.
Why not just store in Notion and skip Postgres? Notion's API rate limits (3 req/sec) and weak query capabilities make it bad as a primary store. Also: you need RLS, joins, and indexes for Phase 2's retrieval. Postgres now means no migration pain later.
What "done" looks like for Phase 1

I log in with my email, get a magic link, sign in.
I connect Notion, OAuth completes, my notes database is created.
I paste https://karpathy.github.io/2015/05/21/rnn-effectiveness/ into the form.
Within ~15 seconds, the source appears in my list with title, summary, ~5 key concepts, ~3 suggested tags.
I open Notion, see the new page in my notes database with all the same info.
I can paste a YouTube URL or arXiv PDF and the same flow works.
LangSmith shows the full trace of every capture run.

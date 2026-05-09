# Phase 1 Implementation Steps

Each step is a shippable increment. Complete and manually verify before moving to the next.

---

## Step 1 — Infrastructure Skeleton

**Goal:** Repo exists, services start, login works end-to-end.

### 1.1 Repo and tooling
- [x] Create `notes/` directory with the layout from the plan.
- [x] Initialize `backend/` with `uv init`, add `pyproject.toml` with Python 3.12+.
- [x] Initialize `frontend/` with `pnpm create next-app` (App Router, TypeScript, Tailwind).
- [x] Add `.gitignore` entries for `.env*`, `__pycache__`, `.next`, `node_modules`.

### 1.2 Supabase project
- [ ] Create Supabase project via dashboard.
- [ ] Note `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_JWT_SECRET`.
- [ ] Enable email magic link auth in Supabase dashboard (disable email confirmation for local dev).

### 1.3 Database migrations
- [ ] Create `backend/migrations/001_initial.sql` with all tables and indexes from the data model:
  - `profiles`, `notion_connections`, `sources`, `tags`, `source_tags`, `notion_sync_jobs`
- [ ] Enable RLS on every user-owned table.
- [ ] Add a Supabase function/trigger to auto-insert a `profiles` row on `auth.users` insert.
- [ ] Run migration against the Supabase project.

### 1.4 FastAPI skeleton
- [ ] Add dependencies: `fastapi`, `uvicorn`, `httpx`, `python-jose[cryptography]`, `asyncpg`, `python-dotenv`.
- [ ] Implement `app/main.py` with app factory, CORS, lifespan.
- [ ] Implement `app/config.py` loading env vars with validation.
- [ ] Implement `app/db.py` with asyncpg connection pool (init/close in lifespan).
- [ ] Add `GET /healthz` returning `{"status": "ok"}`.
- [ ] Smoke-test: `uvicorn app.main:app --reload` returns 200 on `/healthz`.

### 1.5 Docker Compose
- [ ] Add `docker-compose.yml` with `backend` service (FastAPI) and `frontend` service (Next.js dev server).
- [ ] Mount source directories as volumes so live reload works.
- [ ] Add `.env.example` documenting all required vars.

### 1.6 Frontend auth
- [ ] Install `@supabase/supabase-js`, `@supabase/ssr`.
- [ ] Implement `lib/supabase.ts` (browser client and server client helpers).
- [ ] Implement login page: email input → `signInWithOtp` → "check your email" message.
- [ ] Implement auth callback route to exchange the magic link token.
- [ ] Implement logout button in layout.
- [ ] Protected route middleware: redirect unauthenticated users to login.

**Verify:** Sign in with magic link, see authenticated state, sign out.

---

## Step 2 — Authenticated Source Lifecycle

**Goal:** Can create a source row and read it back through the API with auth enforced.

### 2.1 JWT verification
- [ ] Implement `app/auth.py`: `get_current_user(token: str) -> dict` verifies the Supabase JWT using `SUPABASE_JWT_SECRET`, returns `{"user_id": "..."}`.
- [ ] Add FastAPI dependency `require_user = Depends(get_current_user)`.

### 2.2 Source routes (no pipeline yet)
- [ ] Implement `app/models.py` with Pydantic schemas: `SourceCreate`, `SourceResponse`, `SourceListResponse`.
- [ ] Implement `app/routes/sources.py`:
  - `POST /sources`: validate URL scheme, insert row with `status='processing'`, return `202 {source_id, status}`.
  - `GET /sources`: return list for `user_id`, ordered by `created_at desc`.
  - `GET /sources/{id}`: return one row, ownership check (`where id=$1 and user_id=$2`), 404 if not found.
  - `DELETE /sources/{id}`: delete row, ownership check, return 204.
- [ ] All queries use verified `user_id`, never request body values.

### 2.3 Frontend source list shell
- [ ] `app/sources/page.tsx`: fetch `GET /sources` with the Supabase access token, render a table/list.
- [ ] `app/sources/new/page.tsx`: URL input form, `POST /sources` on submit, redirect to list on success.

**Verify:** Create a source via the form, see it in the list with `status=processing`, fetch it by ID from the API.

---

## Step 3 — HTML Capture Happy Path

**Goal:** Paste an HTML URL, get back title/summary/key concepts within ~15 seconds.

### 3.1 Safe URL validator
- [ ] Implement `app/integrations/fetchers.py`:
  - `validate_url(url: str)`: enforce `http`/`https` scheme, resolve hostname, reject private/loopback/link-local/169.254.x.x/metadata IP ranges. Raise `ValueError` with a clear message on rejection.

### 3.2 HTML fetcher
- [ ] Implement `fetch_html(url: str) -> str` in `fetchers.py`:
  - Use `httpx` with a 15s timeout and max 5 redirects.
  - Enforce max download size (e.g., 5 MB).
  - Use `trafilatura` to extract main text.
  - Truncate extracted text to a max length before returning (e.g., 20 000 chars).
  - Raise descriptive errors for network failures, extraction failures, empty content.

### 3.3 Claude enrichment
- [ ] Add dependency: `anthropic`.
- [ ] Implement `app/pipeline/nodes.py` → `enrich(raw_content, url) -> EnrichmentResult`:
  - Single Claude call with a system prompt asking for JSON output.
  - Pydantic model `EnrichmentResult(title, summary, key_concepts, suggested_tags)`.
  - Fallback: if title is missing, use the URL.
  - Normalize tag names: strip, lowercase, collapse spaces.

### 3.4 Linear capture flow (no LangGraph yet)
- [ ] In `POST /sources` (or a `BackgroundTasks` callback), after inserting the row:
  - Call `validate_url` → `fetch_html` → `enrich`.
  - On success: update the source row (`title`, `summary`, `key_concepts`, `status='ready'`), create/upsert tags and source_tags in a transaction.
  - On any exception: update source row `status='failed'`, `error_message=str(e)`.

### 3.5 Polling UI
- [ ] In `app/sources/new/page.tsx` (or redirect to detail): after `POST /sources` returns `source_id`, poll `GET /sources/{id}` every 2s until `ready` or `failed`.
- [ ] Show a spinner while `processing`, success state when `ready`, error state when `failed`.

**Verify:** Paste `https://karpathy.github.io/2015/05/21/rnn-effectiveness/`, see `processing`, then `ready` with AI content within ~15s. Paste an invalid URL, see a clear error.

---

## Step 4 — Tags and Structured Persistence

**Goal:** Tag rows are created cleanly; repeated tags are deduplicated per user.

### 4.1 Tag upsert transaction
- [ ] In the success path: for each suggested tag, `INSERT INTO tags (user_id, name) VALUES ($1, $2) ON CONFLICT (user_id, name) DO NOTHING RETURNING id`.
- [ ] `INSERT INTO source_tags (source_id, tag_id, applied_by, confidence)` for each tag.
- [ ] Wrap the source update + tag creation in a single `asyncpg` transaction.

### 4.2 Expose tags in API response
- [ ] Update `GET /sources/{id}` and `GET /sources` to JOIN tags and return them in the response.

### 4.3 Display tags in frontend
- [ ] Show tag chips on the source list and source detail views.

**Verify:** Source has tags after `ready`. Create a second source with overlapping tags; verify the tags table has no duplicates.

---

## Step 5 — LangGraph Refactor

**Goal:** Capture runs as a LangGraph graph with typed state, error edges, and LangSmith traces.

### 5.1 Dependencies
- [ ] Add `langgraph`, `langsmith` to `pyproject.toml`.
- [ ] Set `LANGCHAIN_TRACING_V2=true`, `LANGCHAIN_API_KEY`, `LANGCHAIN_PROJECT` in `.env`.

### 5.2 State definition
- [ ] Implement `app/pipeline/state.py` with `CaptureState(TypedDict)` matching the plan.

### 5.3 Graph nodes
- [ ] Implement `app/pipeline/nodes.py` with individual node functions:
  - `classify_url(state)` → sets `content_type` (rule-based, no LLM).
  - `fetch_content(state)` → calls the appropriate fetcher, sets `raw_content`.
  - `enrich(state)` → calls Claude, sets `title`, `summary`, `key_concepts`, `suggested_tags`.
  - `persist_success(state)` → DB transaction: update source, upsert tags.
  - `queue_notion_sync(state)` → insert `notion_sync_jobs` row if user has Notion connected.
  - `mark_failed(state)` → update source row to `failed`.

### 5.4 Graph wiring
- [ ] Implement `app/pipeline/graph.py`:
  - Build `StateGraph(CaptureState)`.
  - Add all nodes.
  - Wire edges: `classify_url → fetch_content → enrich → persist_success → queue_notion_sync`.
  - Add error edges from each node to `mark_failed`.
  - Compile the graph.

### 5.5 Replace linear flow
- [ ] In `POST /sources`, launch the compiled graph via `BackgroundTasks` (or `asyncio.create_task`).
- [ ] Remove the old inline capture code.

**Verify:** Capture still works end-to-end. LangSmith dashboard shows a trace with each node.

---

## Step 6 — Notion OAuth and Durable Sync

**Goal:** Connect Notion, captured sources sync to a Notion database, failures retry.

### 6.1 Notion OAuth
- [ ] Register an integration at https://www.notion.so/my-integrations, get `NOTION_CLIENT_ID` and `NOTION_CLIENT_SECRET`.
- [ ] Implement `app/routes/notion.py`:
  - `POST /notion/connect`: redirect to Notion OAuth URL with `state` param (CSRF token tied to user session).
  - `GET /notion/callback`: exchange code for access token, encrypt token, upsert `notion_connections` row, redirect to frontend.
- [ ] Implement token encryption/decryption in `app/integrations/notion.py` using `ENCRYPTION_KEY` from config (use `cryptography` Fernet or similar).

### 6.2 Notion database creation
- [ ] On first sync for a user (when `profiles.notion_database_id` is null): create the Notion database with the schema from the plan, store the database ID in `profiles.notion_database_id`.

### 6.3 Notion page sync
- [ ] Implement `sync_source_to_notion(source_id, user_id)` in `app/integrations/notion.py`:
  - Load source and notion connection.
  - Create Notion page with all properties and body blocks.
  - On success: update `sources.notion_page_id` and `notion_sync_status='synced'`.
  - On failure: store error in the job row.

### 6.4 Durable sync worker
- [ ] Implement `app/workers/notion_sync.py`:
  - Poll loop (or background task) that claims due `notion_sync_jobs` rows using `UPDATE ... WHERE status='pending' AND next_attempt_at <= now() ... RETURNING` with a row lock.
  - Call `sync_source_to_notion`.
  - On success: mark job `succeeded`.
  - On failure: increment `attempt_count`, set `next_attempt_at` (exponential backoff capped at e.g. 1h), set job `status='failed'` if `attempt_count >= max_attempts`, else back to `pending`.
- [ ] Start the worker in the FastAPI lifespan (as an `asyncio.Task`).

### 6.5 Frontend Notion states
- [ ] Show "Notion disconnected" / "pending" / "synced" / "failed" badges on source list and detail.
- [ ] Add "Connect Notion" link to the UI if not connected.

**Verify:** Connect Notion, capture a source, see it appear in the Notion database. Disconnect/invalidate the token and verify the sync fails gracefully and the source still shows as `ready` in Postgres.

---

## Step 7 — YouTube and PDF Fetchers

**Goal:** Capture works for YouTube videos with transcripts and text-based PDFs.

### 7.1 YouTube fetcher
- [ ] Add `youtube-transcript-api` to `pyproject.toml`.
- [ ] Update `classify_url` to detect YouTube URL patterns (`youtube.com/watch?v=`, `youtu.be/`).
- [ ] Implement `fetch_youtube(url: str) -> str`:
  - Extract video ID from URL.
  - Fetch transcript via `youtube-transcript-api`.
  - Join transcript segments, truncate to max length.
  - Raise a clear error if no transcript available.

### 7.2 PDF fetcher
- [ ] Add `pypdf` to `pyproject.toml`.
- [ ] Update `classify_url` to detect `.pdf` extension or `application/pdf` content type (check HEAD response).
- [ ] Implement `fetch_pdf(url: str) -> str`:
  - Download with `httpx`, enforce size limit.
  - Extract text with `pypdf`.
  - Raise a clear error for encrypted PDFs or PDFs with no extractable text.
  - Truncate to max length.

### 7.3 Route fetcher by content type
- [ ] In `fetch_content` node: branch on `state.content_type` → call `fetch_html`, `fetch_youtube`, or `fetch_pdf`.

### 7.4 Tests
- [ ] Write representative tests for each fetcher (unit tests with mocked HTTP, integration test pointing at a known stable public URL).
- [ ] Test that invalid/private URLs are rejected.
- [ ] Test that oversized content is truncated, not errored.

**Verify:** Paste a YouTube URL with a transcript → `ready`. Paste a public PDF URL → `ready`. Paste a YouTube URL without a transcript → `failed` with a useful message.

---

## Step 8 — Frontend Completion

**Goal:** All UI states are handled; the app feels complete for the done criteria.

### 8.1 Source detail page
- [ ] `app/sources/[id]/page.tsx`: show full detail — title, URL, content type, summary, key concepts, tags, Notion sync status, error message if failed.
- [ ] Link from source list to detail page.

### 8.2 Delete action
- [ ] Delete button on source detail (and optionally list) → `DELETE /sources/{id}` → remove from UI.
- [ ] Confirm before delete.

### 8.3 Optimistic list behavior
- [ ] After `POST /sources`, immediately append a `processing` row to the source list without waiting for the poll to resolve.
- [ ] When poll resolves to `ready` or `failed`, update that row in place.

### 8.4 Error states
- [ ] Show the original URL in failed sources so the user can retry.
- [ ] Show meaningful error message text from `error_message`.

### 8.5 Empty and loading states
- [ ] Empty state copy on the source list when no sources exist yet.
- [ ] Skeleton loaders or spinners during initial data fetch.

**Verify:** Walk through all done criteria manually in the browser.

---

## Step 9 — Deployment Pass

**Goal:** The app runs in production and the done checklist passes there.

### 9.1 Environment documentation
- [ ] Update `.env.example` to document every required var with a short description.
- [ ] Document which vars are secret vs. safe to commit.

### 9.2 Backend deployment (Railway or Fly.io)
- [ ] Finalize `backend/Dockerfile` (multi-stage, non-root user).
- [ ] Deploy to Railway (or chosen platform), set all env vars.
- [ ] Run database migrations against the production Supabase project.
- [ ] Verify `/healthz` returns 200 in production.

### 9.3 Frontend deployment (Vercel)
- [ ] Connect the repo to Vercel, configure `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `NEXT_PUBLIC_API_URL`.
- [ ] Set Supabase redirect URL to the production domain.
- [ ] Deploy and verify login flow.

### 9.4 Done checklist
- [ ] Sign in with a Supabase email magic link.
- [ ] Connect Notion through OAuth.
- [ ] Paste `https://karpathy.github.io/2015/05/21/rnn-effectiveness/` → `processing` → `ready` within ~15s with title, summary, key concepts, and tags.
- [ ] Source syncs to Notion database (or shows a clear sync error while remaining `ready` in Postgres).
- [ ] Paste a YouTube URL with a transcript → `ready`.
- [ ] Paste a text-based PDF URL → `ready`.
- [ ] Paste an invalid URL → `failed` with a useful message.
- [ ] LangSmith shows a trace for each capture run.

---

## Environment Variables Reference

| Variable | Where used | Notes |
|---|---|---|
| `SUPABASE_URL` | backend, frontend | Public |
| `SUPABASE_ANON_KEY` | frontend | Public |
| `SUPABASE_SERVICE_ROLE_KEY` | backend | Secret |
| `SUPABASE_JWT_SECRET` | backend | Secret — used to verify JWTs |
| `ANTHROPIC_API_KEY` | backend | Secret |
| `NOTION_CLIENT_ID` | backend | Secret |
| `NOTION_CLIENT_SECRET` | backend | Secret |
| `NOTION_REDIRECT_URI` | backend | Must match Notion app config |
| `ENCRYPTION_KEY` | backend | Secret — Fernet key for token encryption |
| `LANGCHAIN_API_KEY` | backend | Secret |
| `LANGCHAIN_TRACING_V2` | backend | `true` |
| `LANGCHAIN_PROJECT` | backend | Project name in LangSmith |
| `DATABASE_URL` | backend | Supabase Postgres connection string |

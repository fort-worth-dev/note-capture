-- Phase 1 initial schema (revision 1 data model)
-- Run via Supabase SQL editor or `psql` when ready (Step 1.3 — apply migration separately).

-- -----------------------------------------------------------------------------
-- Tables
-- -----------------------------------------------------------------------------

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text not null,
  notion_database_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.notion_connections (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  workspace_id text,
  workspace_name text,
  bot_id text,
  access_token_encrypted text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.sources (
  id uuid primary key default gen_random_uuid (),
  user_id uuid not null references public.profiles (id) on delete cascade,
  url text not null,
  content_type text check (
    content_type in ('html', 'youtube', 'pdf', 'text')
  ),
  title text,
  raw_content text,
  summary text,
  key_concepts jsonb not null default '[]'::jsonb,
  notion_page_id text,
  notion_sync_status text not null default 'not_queued' check (
    notion_sync_status in ('not_queued', 'pending', 'synced', 'failed')
  ),
  notion_sync_error text,
  status text not null default 'processing' check (
    status in ('processing', 'ready', 'failed')
  ),
  error_message text,
  created_at timestamptz not null default now (),
  updated_at timestamptz not null default now ()
);

create table public.tags (
  id uuid primary key default gen_random_uuid (),
  user_id uuid not null references public.profiles (id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now (),
  unique (user_id, name)
);

create table public.source_tags (
  source_id uuid not null references public.sources (id) on delete cascade,
  tag_id uuid not null references public.tags (id) on delete cascade,
  applied_by text not null check (applied_by in ('ai', 'user')),
  confidence real,
  created_at timestamptz not null default now (),
  primary key (source_id, tag_id)
);

create table public.notion_sync_jobs (
  id uuid primary key default gen_random_uuid (),
  source_id uuid not null references public.sources (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'pending' check (
    status in ('pending', 'running', 'succeeded', 'failed')
  ),
  attempt_count integer not null default 0,
  next_attempt_at timestamptz not null default now (),
  locked_at timestamptz,
  last_error text,
  created_at timestamptz not null default now (),
  updated_at timestamptz not null default now ()
);

-- -----------------------------------------------------------------------------
-- Indexes
-- -----------------------------------------------------------------------------

create index sources_user_created on public.sources (user_id, created_at desc);

create index sources_status on public.sources (status);

create index sources_notion_pending on public.sources (notion_sync_status)
where
  notion_sync_status = 'pending';

create index notion_sync_jobs_ready on public.notion_sync_jobs (next_attempt_at, status)
where
  status in ('pending', 'failed');

-- -----------------------------------------------------------------------------
-- Row level security
-- -----------------------------------------------------------------------------

alter table public.profiles enable row level security;

alter table public.notion_connections enable row level security;

alter table public.sources enable row level security;

alter table public.tags enable row level security;

alter table public.source_tags enable row level security;

alter table public.notion_sync_jobs enable row level security;

create policy "Users select own profile" on public.profiles for select to authenticated using (auth.uid() = id);

create policy "Users update own profile" on public.profiles
for update
  to authenticated using (auth.uid() = id)
with
  check (auth.uid() = id);

create policy "Users manage own notion connection" on public.notion_connections for all to authenticated using (auth.uid() = user_id)
with
  check (auth.uid() = user_id);

create policy "Users manage own sources" on public.sources for all to authenticated using (auth.uid() = user_id)
with
  check (auth.uid() = user_id);

create policy "Users manage own tags" on public.tags for all to authenticated using (auth.uid() = user_id)
with
  check (auth.uid() = user_id);

create policy "Users read source_tags for own sources" on public.source_tags for select to authenticated using (
  exists (
    select
      1
    from
      public.sources s
    where
      s.id = source_tags.source_id
      and s.user_id = auth.uid()
  )
);

create policy "Users insert source_tags for own sources and tags" on public.source_tags for insert to authenticated
with
  check (
    exists (
      select
        1
      from
        public.sources s
      where
        s.id = source_tags.source_id
        and s.user_id = auth.uid()
    )
    and exists (
      select
        1
      from
        public.tags t
      where
        t.id = source_tags.tag_id
        and t.user_id = auth.uid()
    )
  );

create policy "Users update source_tags for own sources" on public.source_tags
for update
  to authenticated using (
    exists (
      select
        1
      from
        public.sources s
      where
        s.id = source_tags.source_id
        and s.user_id = auth.uid()
    )
  )
with
  check (
    exists (
      select
        1
      from
        public.sources s
      where
        s.id = source_tags.source_id
        and s.user_id = auth.uid()
    )
    and exists (
      select
        1
      from
        public.tags t
      where
        t.id = source_tags.tag_id
        and t.user_id = auth.uid()
    )
  );

create policy "Users delete source_tags for own sources" on public.source_tags for delete to authenticated using (
  exists (
    select
      1
    from
      public.sources s
    where
      s.id = source_tags.source_id
      and s.user_id = auth.uid()
  )
);

create policy "Users manage own notion sync jobs" on public.notion_sync_jobs for all to authenticated using (auth.uid() = user_id)
with
  check (auth.uid() = user_id);

-- -----------------------------------------------------------------------------
-- Grants (Supabase: JWT-authenticated clients use role `authenticated`)
-- -----------------------------------------------------------------------------

grant usage on schema public to anon, authenticated, service_role;

grant select, insert, update, delete on table public.profiles to authenticated;

grant select, insert, update, delete on table public.notion_connections to authenticated;

grant select, insert, update, delete on table public.sources to authenticated;

grant select, insert, update, delete on table public.tags to authenticated;

grant select, insert, update, delete on table public.source_tags to authenticated;

grant select, insert, update, delete on table public.notion_sync_jobs to authenticated;

grant all on table public.profiles to service_role;

grant all on table public.notion_connections to service_role;

grant all on table public.sources to service_role;

grant all on table public.tags to service_role;

grant all on table public.source_tags to service_role;

grant all on table public.notion_sync_jobs to service_role;

-- -----------------------------------------------------------------------------
-- Profile row when a Supabase auth user is created
-- -----------------------------------------------------------------------------

create or replace function public.handle_new_user() returns trigger language plpgsql security definer
set
  search_path = public as $$
begin
  insert into public.profiles (id, email)
  values (
    new.id,
    coalesce(new.email, new.raw_user_meta_data ->> 'email', '')
  );
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users for each row
execute function public.handle_new_user();

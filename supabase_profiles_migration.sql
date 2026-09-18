-- Run this once in the Supabase SQL Editor (https://app.supabase.com -> your project -> SQL Editor).
-- Creates a per-user "profiles" row that mirrors everything currently kept in
-- localStorage (coins, owned skins, selected skin, revive keys, nickname,
-- best score, language, mute state), so progress survives across devices.

create table if not exists public.profiles (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  nickname     text,
  best_score   integer not null default 0,
  coins        integer not null default 0,
  owned_skins  jsonb not null default '["neon"]'::jsonb,
  selected_skin text not null default 'neon',
  keys         integer not null default 0,
  lang         text not null default 'en',
  muted        boolean not null default false,
  updated_at   timestamptz not null default now()
);

-- keep updated_at fresh on every upsert
create or replace function public.touch_profiles_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_touch_profiles_updated_at on public.profiles;
create trigger trg_touch_profiles_updated_at
  before update on public.profiles
  for each row execute function public.touch_profiles_updated_at();

alter table public.profiles enable row level security;

-- each signed-in user may only read/write their own row
drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own" on public.profiles
  for select using (auth.uid() = user_id);

drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own" on public.profiles
  for insert with check (auth.uid() = user_id);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

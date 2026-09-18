-- Run this in the Supabase SQL Editor AFTER supabase_profiles_migration.sql.
--
-- Problem this closes: previously the client pushed coins/keys/owned_skins/
-- selected_skin/best_score straight into `profiles` with a plain upsert. Since
-- that value came from the browser's own JS variables, anyone could open
-- devtools, edit localStorage (or the in-memory `coins` var) and the next sync
-- would happily write that fake number to the database, letting them "buy"
-- anything in the shop for free.
--
-- Fix: take away the client's ability to write coins/keys/owned_skins/
-- selected_skin/best_score directly. From now on those columns can only change
-- through the SECURITY DEFINER functions below, which check the *stored*
-- balance on the server, not whatever the browser claims it is. Only the
-- harmless prefs (nickname/lang/muted) stay directly editable by the client.

revoke insert, update on public.profiles from authenticated, anon;
grant select on public.profiles to authenticated;
grant update (nickname, lang, muted) on public.profiles to authenticated;

-- get-or-create the caller's row (called right after sign-in)
create or replace function public.ensure_profile()
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare result public.profiles;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  insert into public.profiles(user_id) values (auth.uid()) on conflict (user_id) do nothing;
  select * into result from public.profiles where user_id = auth.uid();
  return result;
end;
$$;

-- buy an unowned skin: only succeeds if the stored coin balance covers it
create or replace function public.buy_skin(p_skin_id text, p_cost integer)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare result public.profiles;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if p_cost < 0 then raise exception 'invalid_cost'; end if;

  update public.profiles
  set coins = coins - p_cost,
      owned_skins = owned_skins || to_jsonb(p_skin_id),
      selected_skin = p_skin_id
  where user_id = auth.uid()
    and coins >= p_cost
    and not (owned_skins @> to_jsonb(p_skin_id))
  returning * into result;

  if result is null then raise exception 'purchase_rejected'; end if;
  return result;
end;
$$;

-- switch to an already-owned skin (server re-checks ownership, ignores any tampered local list)
create or replace function public.select_owned_skin(p_skin_id text)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare result public.profiles;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;

  update public.profiles
  set selected_skin = p_skin_id
  where user_id = auth.uid()
    and owned_skins @> to_jsonb(p_skin_id)
  returning * into result;

  if result is null then raise exception 'skin_not_owned'; end if;
  return result;
end;
$$;

-- buy a revive key with coins
create or replace function public.buy_revive_key(p_cost integer)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare result public.profiles;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if p_cost < 0 then raise exception 'invalid_cost'; end if;

  update public.profiles
  set coins = coins - p_cost,
      keys = keys + 1
  where user_id = auth.uid()
    and coins >= p_cost
  returning * into result;

  if result is null then raise exception 'purchase_rejected'; end if;
  return result;
end;
$$;

-- spend one revive key mid-run
create or replace function public.use_revive_key()
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare result public.profiles;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;

  update public.profiles
  set keys = keys - 1
  where user_id = auth.uid() and keys > 0
  returning * into result;

  if result is null then raise exception 'no_keys'; end if;
  return result;
end;
$$;

-- settle a finished run atomically: credit the coins earned, raise best_score
-- if beaten, and post the leaderboard row - all in one server-trusted call
create or replace function public.award_run_result(p_coins_earned integer, p_score integer, p_distance numeric, p_nickname text)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare result public.profiles;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if p_coins_earned < 0 or p_coins_earned > 100000 then raise exception 'invalid_amount'; end if;

  update public.profiles
  set coins = coins + p_coins_earned,
      best_score = greatest(best_score, coalesce(p_score, 0))
  where user_id = auth.uid()
  returning * into result;

  if result is null then raise exception 'no_profile'; end if;

  insert into public.scores(user_id, nickname, score, distance)
  values (auth.uid(), coalesce(nullif(trim(p_nickname), ''), 'player'), greatest(0, coalesce(p_score,0)), greatest(0, coalesce(p_distance,0)));

  return result;
end;
$$;

grant execute on function public.ensure_profile() to authenticated;
grant execute on function public.buy_skin(text, integer) to authenticated;
grant execute on function public.select_owned_skin(text) to authenticated;
grant execute on function public.buy_revive_key(integer) to authenticated;
grant execute on function public.use_revive_key() to authenticated;
grant execute on function public.award_run_result(integer, integer, numeric, text) to authenticated;

-- Validator Tycoon — run AFTER schema.sql and multiplayer.sql (applied to the live project 2026-11-15).
-- Keeps public leaderboard numbers on the public profile so the views never read private saves,
-- and makes every public view respect row-level security (security_invoker).
alter table public.players
  add column if not exists net_worth   numeric not null default 0,
  add column if not exists fork_points int not null default 0;

create or replace function public.submit_save(p_state jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  prev        public.saves%rowtype;
  elapsed     numeric;
  new_life    numeric := coalesce((p_state->>'lifetime')::numeric, 0);
  new_ema     numeric := coalesce((p_state->>'incomeEMA')::numeric, 0);
  new_nw      numeric := coalesce((p_state->>'coins')::numeric, 0) + coalesce((p_state->>'ownStake')::numeric, 0);
  new_fp      int     := coalesce((p_state->>'forkPoints')::int, 0);
  max_gain    numeric;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  insert into public.players (id) values (auth.uid()) on conflict do nothing;

  select * into prev from public.saves where player_id = auth.uid();
  if found then
    elapsed  := greatest(1, extract(epoch from now() - prev.updated_at));
    max_gain := greatest(prev.income_ema, 50000) * 3 * elapsed * 4 + 5e6;
    if new_life - prev.lifetime > max_gain then
      return jsonb_build_object('ok', false, 'reason', 'progress too fast', 'state', prev.state);
    end if;
  end if;

  insert into public.saves (player_id, state, net_worth, lifetime, income_ema, fork_points, updated_at)
  values (auth.uid(), p_state, new_nw, new_life, new_ema, new_fp, now())
  on conflict (player_id) do update set
    state = excluded.state, net_worth = excluded.net_worth, lifetime = excluded.lifetime,
    income_ema = excluded.income_ema, fork_points = excluded.fork_points, updated_at = now();

  update public.players set net_worth = new_nw, fork_points = new_fp, last_seen = now() where id = auth.uid();
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.submit_save(jsonb) from public, anon;
grant execute on function public.submit_save(jsonb) to authenticated;

drop view if exists public.leaderboard;
drop view if exists public.guild_leaderboard;
drop view if exists public.world_companies;
drop view if exists public.guild_pools;

create view public.leaderboard with (security_invoker = true) as
  select p.id, p.company_name, p.net_worth, p.fork_points,
         rank() over (order by p.net_worth desc) as rank
  from public.players p;

create view public.guild_leaderboard with (security_invoker = true) as
  select g.id, g.name, count(m.player_id) as members, coalesce(sum(m.stake), 0) as total_stake,
         floor(coalesce(sum(m.stake), 0) / 32000000) as validators,
         rank() over (order by coalesce(sum(m.stake), 0) desc) as rank
  from public.guilds g left join public.guild_members m on m.guild_id = g.id
  group by g.id, g.name;

create view public.world_companies with (security_invoker = true) as
  select p.id, p.company_name, p.city, p.lat, p.lon, p.validators, p.reputation, p.commission, p.online,
         (p.slashed_at > now() - interval '5 minutes') as recently_slashed,
         m.guild_id, p.net_worth
  from public.players p
  left join public.guild_members m on m.player_id = p.id
  where p.city is not null and p.last_seen > now() - interval '7 days';

create view public.guild_pools with (security_invoker = true) as
  select g.id, g.name, g.color, g.fee, g.owner_id,
         count(m.player_id) as members, coalesce(sum(m.stake), 0) as pooled,
         floor(coalesce(sum(m.stake), 0) / 32000000) as validators
  from public.guilds g left join public.guild_members m on m.guild_id = g.id
  group by g.id;

grant select on public.leaderboard, public.guild_leaderboard, public.world_companies, public.guild_pools to anon, authenticated;

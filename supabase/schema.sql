-- Validator Tycoon — online backend (Supabase / Postgres)
-- Phase 3: cloud saves, server-checked progress, guild staking pools, seasonal leaderboards.
-- Run in the Supabase SQL editor. Uses Supabase Auth (auth.users).

-- ---------- players ----------
create table if not exists public.players (
  id            uuid primary key references auth.users(id) on delete cascade,
  company_name  text not null default 'My Staking Co.' check (char_length(company_name) between 1 and 28),
  wallet        text unique,                       -- optional PulseChain address (0x...), set after wallet connect
  created_at    timestamptz not null default now()
);

-- ---------- cloud saves (server is the source of truth for offline earnings) ----------
create table if not exists public.saves (
  player_id     uuid primary key references public.players(id) on delete cascade,
  state         jsonb not null,
  net_worth     numeric not null default 0,
  lifetime      numeric not null default 0,
  income_ema    numeric not null default 0,
  fork_points   int not null default 0,
  updated_at    timestamptz not null default now()
);

-- ---------- guilds (shared staking pools) ----------
create table if not exists public.guilds (
  id            uuid primary key default gen_random_uuid(),
  name          text not null unique check (char_length(name) between 3 and 32),
  owner_id      uuid not null references public.players(id),
  commission    numeric not null default 0.05 check (commission between 0 and 0.25),
  created_at    timestamptz not null default now()
);

create table if not exists public.guild_members (
  guild_id      uuid not null references public.guilds(id) on delete cascade,
  player_id     uuid not null references public.players(id) on delete cascade,
  stake         numeric not null default 0 check (stake >= 0),
  joined_at     timestamptz not null default now(),
  primary key (guild_id, player_id),
  unique (player_id)                                 -- one guild per player
);

-- ---------- seasons & badges ----------
create table if not exists public.seasons (
  id            int primary key,
  starts_at     timestamptz not null,
  ends_at       timestamptz not null,
  prize_pool    numeric not null default 0,          -- in stablecoin units, mirrors SeasonPrizePool funding
  merkle_root   text                                 -- set when results are published on-chain
);

create table if not exists public.badges (
  player_id     uuid not null references public.players(id) on delete cascade,
  badge_id      text not null,
  earned_at     timestamptz not null default now(),
  claim_sig     text,                                -- server signature for TycoonBadges.claim()
  primary key (player_id, badge_id)
);

-- ---------- leaderboards ----------
-- Public leaderboards expose only public columns (never the save state).
create or replace view public.leaderboard as
  select p.id, p.company_name, s.net_worth, s.fork_points,
         rank() over (order by s.net_worth desc) as rank
  from public.saves s join public.players p on p.id = s.player_id;

create or replace view public.guild_leaderboard as
  select g.id, g.name, count(m.player_id) as members, coalesce(sum(m.stake), 0) as total_stake,
         floor(coalesce(sum(m.stake), 0) / 32000000) as validators,
         rank() over (order by coalesce(sum(m.stake), 0) desc) as rank
  from public.guilds g left join public.guild_members m on m.guild_id = g.id
  group by g.id, g.name;

-- ---------- anti-cheat save function ----------
-- Clients never write saves directly. They call submit_save(); the server caps how much
-- lifetime earnings can grow based on real elapsed time and the player's recent income rate.
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
  max_gain    numeric;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  insert into public.players (id) values (auth.uid()) on conflict do nothing;

  select * into prev from public.saves where player_id = auth.uid();
  if found then
    elapsed  := greatest(1, extract(epoch from now() - prev.updated_at));
    -- at most 4 blocks/sec (4x speed), with generous headroom on the income rate
    max_gain := greatest(prev.income_ema, 50000) * 3 * elapsed * 4 + 5e6;
    if new_life - prev.lifetime > max_gain then
      return jsonb_build_object('ok', false, 'reason', 'progress too fast', 'state', prev.state);
    end if;
  end if;

  insert into public.saves (player_id, state, net_worth, lifetime, income_ema, fork_points, updated_at)
  values (auth.uid(), p_state,
          coalesce((p_state->>'coins')::numeric, 0) + coalesce((p_state->>'ownStake')::numeric, 0),
          new_life, new_ema, coalesce((p_state->>'forkPoints')::int, 0), now())
  on conflict (player_id) do update set
    state = excluded.state, net_worth = excluded.net_worth, lifetime = excluded.lifetime,
    income_ema = excluded.income_ema, fork_points = excluded.fork_points, updated_at = now();

  return jsonb_build_object('ok', true);
end $$;

-- ---------- row level security ----------
alter table public.players       enable row level security;
alter table public.saves         enable row level security;
alter table public.guilds        enable row level security;
alter table public.guild_members enable row level security;
alter table public.seasons       enable row level security;
alter table public.badges        enable row level security;

create policy "players readable by all"   on public.players for select using (true);
-- no direct updates to players: profile changes go through update_company()
create policy "read own save"             on public.saves   for select using (player_id = auth.uid());
-- no insert/update policy on saves: writes only via submit_save()
create policy "guilds readable by all"    on public.guilds  for select using (true);
create policy "create guild as owner"     on public.guilds  for insert with check (owner_id = auth.uid());
create policy "owner edits guild"         on public.guilds  for update using (owner_id = auth.uid());
create policy "members readable by all"   on public.guild_members for select using (true);
create policy "join guild as self"        on public.guild_members for insert with check (player_id = auth.uid() and stake = 0);
create policy "leave guild as self"       on public.guild_members for delete using (player_id = auth.uid());
create policy "seasons readable by all"   on public.seasons for select using (true);
create policy "read own badges"           on public.badges  for select using (player_id = auth.uid());

grant select on public.leaderboard, public.guild_leaderboard to anon, authenticated;
revoke execute on function public.submit_save(jsonb) from public, anon;
grant execute on function public.submit_save(jsonb) to authenticated;

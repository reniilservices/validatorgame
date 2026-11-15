-- Validator Tycoon — multiplayer layer (run AFTER schema.sql)
-- Real players on the world map, staking with each other, and guild pools.
-- The game's NET object (index.html) maps 1:1 onto these tables and functions.

-- ---------- public company profile (what other players see on the globe) ----------
alter table public.players
  add column if not exists city        text,              -- chosen from the game's city list; never GPS
  add column if not exists lat         numeric,           -- city centre, not the player's real position
  add column if not exists lon         numeric,
  add column if not exists validators  int not null default 0,
  add column if not exists reputation  numeric not null default 50,
  add column if not exists commission  numeric not null default 0.10 check (commission between 0 and 0.25),
  add column if not exists online      boolean not null default true,
  add column if not exists slashed_at  timestamptz,
  add column if not exists last_seen   timestamptz not null default now();

create index if not exists players_last_seen on public.players (last_seen desc);

-- ---------- staking with another player's company ----------
create table if not exists public.delegations (
  staker_id    uuid not null references public.players(id) on delete cascade,
  company_id   uuid not null references public.players(id) on delete cascade,
  amount       numeric not null check (amount > 0),
  updated_at   timestamptz not null default now(),
  primary key (staker_id, company_id),
  check (staker_id <> company_id)
);

-- ---------- guild extras ----------
alter table public.guilds
  add column if not exists color int not null default 16727212,   -- 0xff3cac
  add column if not exists fee   numeric not null default 0.05 check (fee between 0 and 0.15);

-- ---------- functions the game calls (all checked server-side) ----------
-- Profile + heartbeat, sent every ~30s with the save.
create or replace function public.update_company(p_city text, p_lat numeric, p_lon numeric,
  p_validators int, p_reputation numeric, p_commission numeric, p_online boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  update public.players set city = p_city, lat = p_lat, lon = p_lon,
    validators = greatest(0, least(p_validators, 2000)), reputation = greatest(0, least(p_reputation, 100)),
    commission = greatest(0, least(p_commission, 0.25)), online = p_online, last_seen = now()
  where id = auth.uid();
end $$;

-- Stake with / unstake from another company. Coins are deducted from the caller's saved state.
create or replace function public.delegate(p_company uuid, p_amount numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare coins numeric;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_company = auth.uid() then raise exception 'cannot stake with yourself'; end if;
  select (state->>'coins')::numeric into coins from public.saves where player_id = auth.uid() for update;
  if p_amount <= 0 or coalesce(coins, 0) < p_amount then return jsonb_build_object('ok', false, 'reason', 'not enough coins'); end if;
  update public.saves set state = jsonb_set(state, '{coins}', to_jsonb(coins - p_amount)) where player_id = auth.uid();
  insert into public.delegations (staker_id, company_id, amount) values (auth.uid(), p_company, p_amount)
  on conflict (staker_id, company_id) do update set amount = public.delegations.amount + excluded.amount, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.undelegate(p_company uuid, p_amount numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cur numeric;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select amount into cur from public.delegations where staker_id = auth.uid() and company_id = p_company for update;
  if cur is null or p_amount <= 0 then return jsonb_build_object('ok', false); end if;
  if p_amount >= cur then delete from public.delegations where staker_id = auth.uid() and company_id = p_company;
  else update public.delegations set amount = cur - p_amount, updated_at = now() where staker_id = auth.uid() and company_id = p_company; end if;
  -- the game adds the amount to its unbonding queue; the next submit_save carries it back into coins
  return jsonb_build_object('ok', true, 'amount', least(p_amount, cur));
end $$;

-- Add to / withdraw from your guild's pool.
create or replace function public.guild_pool(p_delta numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cur numeric; coins numeric;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select stake into cur from public.guild_members where player_id = auth.uid() for update;
  if cur is null then return jsonb_build_object('ok', false, 'reason', 'not in a guild'); end if;
  if p_delta > 0 then
    select (state->>'coins')::numeric into coins from public.saves where player_id = auth.uid() for update;
    if coalesce(coins, 0) < p_delta then return jsonb_build_object('ok', false, 'reason', 'not enough coins'); end if;
    update public.saves set state = jsonb_set(state, '{coins}', to_jsonb(coins - p_delta)) where player_id = auth.uid();
  elsif -p_delta > cur then return jsonb_build_object('ok', false, 'reason', 'not that much pooled');
  end if;
  update public.guild_members set stake = cur + p_delta where player_id = auth.uid();
  return jsonb_build_object('ok', true);
end $$;

-- ---------- views the globe and Network tab read ----------
create or replace view public.world_companies as
  select p.id, p.company_name, p.city, p.lat, p.lon, p.validators, p.reputation, p.commission, p.online,
         (p.slashed_at > now() - interval '5 minutes') as recently_slashed,
         m.guild_id, s.net_worth
  from public.players p
  left join public.guild_members m on m.player_id = p.id
  left join public.saves s on s.player_id = p.id
  where p.city is not null and p.last_seen > now() - interval '7 days';

create or replace view public.guild_pools as
  select g.id, g.name, g.color, g.fee, g.owner_id,
         count(m.player_id) as members, coalesce(sum(m.stake), 0) as pooled,
         floor(coalesce(sum(m.stake), 0) / 32000000) as validators
  from public.guilds g left join public.guild_members m on m.guild_id = g.id
  group by g.id;

-- ---------- security ----------
alter table public.delegations enable row level security;
create policy "delegations readable by all" on public.delegations for select using (true);
-- writes only through delegate() / undelegate()

grant select on public.world_companies, public.guild_pools to anon, authenticated;
grant execute on function public.update_company(text, numeric, numeric, int, numeric, numeric, boolean) to authenticated;
grant execute on function public.delegate(uuid, numeric) to authenticated;
grant execute on function public.undelegate(uuid, numeric) to authenticated;
grant execute on function public.guild_pool(numeric) to authenticated;

-- Live map: stream company changes (online/offline, validators, slashes) to every open globe.
alter publication supabase_realtime add table public.players;

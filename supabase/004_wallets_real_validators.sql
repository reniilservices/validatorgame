-- Validator Tycoon — 004: wallet sign-in, real PulseChain validators, guild validator projects.
-- Wallet addresses stay private (own row only). Validator data is public on-chain anyway, so it is public here.
-- Only the `validators` Edge Function (service role) writes wallets and real validators, after checking the beacon chain.

create table if not exists public.player_wallets (
  player_id   uuid primary key references public.players(id) on delete cascade,
  address     text not null unique check (address ~ '^0x[0-9a-f]{40}$'),
  linked_at   timestamptz not null default now()
);
alter table public.player_wallets enable row level security;
create policy "read own wallet" on public.player_wallets for select using (player_id = (select auth.uid()));

-- Guild validator projects: a coordination board. The game never holds PLS.
create table if not exists public.guild_projects (
  id          uuid primary key default gen_random_uuid(),
  guild_id    uuid not null references public.guilds(id) on delete cascade,
  name        text not null check (char_length(name) between 3 and 32),
  operator_id uuid not null references public.players(id) on delete cascade,
  target_pls  numeric not null default 32000000 check (target_pls between 32000000 and 3200000000),
  created_at  timestamptz not null default now(),
  unique (guild_id, name)
);
create index if not exists guild_projects_guild_idx on public.guild_projects(guild_id);
create index if not exists guild_projects_operator_idx on public.guild_projects(operator_id);
alter table public.guild_projects enable row level security;
create policy "projects readable by all" on public.guild_projects for select using (true);
create policy "members start projects they operate" on public.guild_projects for insert
  with check (operator_id = (select auth.uid())
              and exists (select 1 from public.guild_members m where m.guild_id = guild_projects.guild_id and m.player_id = (select auth.uid()))
              and (select count(*) from public.guild_projects p where p.guild_id = guild_projects.guild_id) < 10);
create policy "operator closes project" on public.guild_projects for delete using (operator_id = (select auth.uid()));

create table if not exists public.guild_pledges (
  project_id  uuid not null references public.guild_projects(id) on delete cascade,
  player_id   uuid not null references public.players(id) on delete cascade,
  amount_pls  numeric not null check (amount_pls > 0 and amount_pls <= 3200000000),
  updated_at  timestamptz not null default now(),
  primary key (project_id, player_id)
);
create index if not exists guild_pledges_player_idx on public.guild_pledges(player_id);
alter table public.guild_pledges enable row level security;
create policy "pledges readable by all" on public.guild_pledges for select using (true);
create policy "members pledge as self" on public.guild_pledges for insert
  with check (player_id = (select auth.uid()) and exists (
    select 1 from public.guild_projects p join public.guild_members m on m.guild_id = p.guild_id
    where p.id = guild_pledges.project_id and m.player_id = (select auth.uid())));
create policy "change own pledge" on public.guild_pledges for update using (player_id = (select auth.uid())) with check (player_id = (select auth.uid()));
create policy "withdraw own pledge" on public.guild_pledges for delete using (player_id = (select auth.uid()));

create table if not exists public.real_validators (
  validator_index    bigint primary key,
  player_id          uuid not null references public.players(id) on delete cascade,
  project_id         uuid references public.guild_projects(id) on delete set null,
  pubkey             text not null,
  status             text not null,
  slashed            boolean not null default false,
  balance_gwei       bigint not null default 0,
  effective_gwei     bigint not null default 0,
  start_balance_gwei bigint not null default 0,
  healthy            boolean not null default true,   -- balance grew (or held) since the previous check
  linked_at          timestamptz not null default now(),
  checked_at         timestamptz not null default now()
);
create index if not exists real_validators_player_idx on public.real_validators(player_id);
create index if not exists real_validators_project_idx on public.real_validators(project_id);
alter table public.real_validators enable row level security;
create policy "real validators readable by all" on public.real_validators for select using (true);

-- Per-player summary used for badges, the Real Operators board and in-game perks.
create or replace view public.real_operators with (security_invoker = true) as
  select p.id, p.company_name,
         count(v.*) filter (where v.status like 'active%') as active_validators,
         count(v.*) filter (where v.status like 'active%' and v.healthy and not v.slashed) as healthy_validators,
         coalesce(sum(v.effective_gwei) filter (where v.status like 'active%'), 0) / 1e9 as staked_pls,
         coalesce(sum(v.balance_gwei - v.start_balance_gwei) filter (where v.status like 'active%'), 0) / 1e9 as earned_since_link_pls,
         max(v.checked_at) as checked_at
  from public.players p join public.real_validators v on v.player_id = p.id
  group by p.id, p.company_name;

create or replace view public.guild_project_status with (security_invoker = true) as
  select gp.id, gp.guild_id, gp.name, gp.operator_id, op.company_name as operator_name, gp.target_pls, gp.created_at,
         coalesce((select sum(amount_pls) from public.guild_pledges x where x.project_id = gp.id), 0) as pledged_pls,
         (select count(*) from public.guild_pledges x where x.project_id = gp.id) as pledgers,
         (select count(*) from public.real_validators v where v.project_id = gp.id and v.status like 'active%') as live_validators,
         (select bool_and(v.healthy and not v.slashed) from public.real_validators v where v.project_id = gp.id and v.status like 'active%') as all_healthy
  from public.guild_projects gp join public.players op on op.id = gp.operator_id;

grant select on public.real_operators, public.guild_project_status to anon, authenticated;

# Validator Tycoon

A 3D isometric idle/tycoon game about running a staking company on a PulseChain-style network.

## What's in here

| Path | What it is | Status |
|---|---|---|
| `index.html` | The whole playable game (Three.js, single file, no build step), with online play via Supabase | **Playable** |
| `chars/*.glb` | 12 Mixamo characters, converted and compressed (512px WebP textures + meshopt), ~0.4–0.75 MB each | Loaded on demand |
| `anims.js` | 32 Mixamo animations packed into one compact module (~1 MB) | Loaded at start |
| `contracts/ValidatorLicence.sol` | ERC-1155 limited-supply cosmetic company licences, paid in PLS | Compiles (solc 0.8.24, OpenZeppelin 5.0.2), not audited or deployed |
| `contracts/TycoonBadges.sol` | Soulbound achievement badges; server signs, player claims | Compiles, not deployed |
| `contracts/SeasonPrizePool.sol` | Stablecoin prize pool with Merkle-proof claims per season | Compiles, not deployed |
| `supabase/schema.sql` | Cloud saves with anti-cheat, guilds, leaderboards, RLS | **Applied** to the live project (run order: schema → multiplayer → 003); game not wired to it yet |
| `supabase/multiplayer.sql` | Public company profiles for the globe, staking between players, guild pools, realtime | **Applied** to the live project |
| `supabase/003_public_stats_invoker_views.sql` | Public stats on profiles; all public views respect row-level security | **Applied** to the live project |

## Game systems (all in `index.html`)

- **Staking:** 32M stake = 1 validator, each needs a node. Own stake + staker delegation + whale.
- **Commission slider** trades profit per staker against how fast stakers arrive.
- **Rewards:** attestation each block, ~10% chance to propose a block for fees; 25% of fees burned (drives the in-game price).
- **Hardware:** 3 node tiers, upgrade/sell/repair, 4 room eras (Back Room → Multi-Region Campus).
- **Power:** grid outages, UPS (30 blocks), diesel generator (fuel cost + smoke), solar (daytime savings), day/night cycle.
- **Internet:** fibre cuts, 4G backup (patchy), satellite (solid, costs per block).
- **Heat:** cooling levels vs. node heat; overheating multiplies failure rates.
- **Technicians:** walk to broken racks and repair them; 2+ auto-patch network upgrades.
- **Hot backup:** keeps a broken node validating but risks a double-sign **slash**.
- **Events:** outage, fibre cut, meme-coin mania, bridge scare, network upgrade deadline, whale offer + trial, bear market auction, heatwave.
- **Hard Fork prestige:** at 1B lifetime earnings, reset for permanent +25% per fork point.
- **Facility upgrades (real data-centre kit):** raised floor (+25% cooling), hot/cold aisle containment (+35%), precision CRAC units, structured cabling (−20% failures), FM-200 fire suppression (stops fires from overheating or electrical faults), CCTV + biometric access (stops night break-ins), NOC monitoring wall (2× faster repairs, +25% reputation growth), A+B power feeds (no crashes on switchover), automatic transfer switch (instant generator), DDoS protection, UPS lithium upgrades (30/60/120 blocks). All visible in the 3D room.
- **New nodes:** ARM Efficiency Node (heat 1, half power) and Liquid-Cooled Dual Rig (2 validators per rack, Data Hall and up). Validators are now counted in *slots*.
- **Server farms:** up to 5 remote sites in other cities (Colocation Cage 4 slots → Edge Farm 12 → Hyperscale Hall 40). They keep running when HQ power/internet fails but go down in their own city's grid outages; hosting fee per slot. Shown on the globe with dashed links to HQ.
- **Design tab:** floors (dark tiles, data-centre white, epoxy, oak, carbon, neon hex), wall colours, accent lights (incl. rainbow), rack paint, lighting mood, plus decorations: neon company sign, plants, coffee corner, trophy shelf (a cup per badge). Paid once, kept across Hard Forks.
- **Compound:** the room sits on a building plinth inside a walled yard: perimeter wall with razor wire, gate with boom barrier and guard booth, company sign at the gate, driveway, parking with cars, street lamps (lit at night), trees and a road.
- **Door:** real doorway in the left wall; the door swings open when visitors, the whale or the rival walk through.
- **Validator world (simulated):** 32 starting companies in 46 real cities (6 in Nigeria), growing to 90 as new ones join. They grow, propose blocks, get slashed, go offline in regional grid outages, and the weakest go bust in bear markets.
- **Staking with other companies:** put spare coins with any company; earn while they're online, minus their commission (60% of what your own validator would make). If they're slashed you lose 3%; if they go bust your stake is returned. 60-block unbonding.
- **Guilds:** 10 starting guilds, or found your own for 5M (other companies join over time based on your reputation). Members pool coins; every 32M pooled runs one guild validator on members' nodes; rewards split by contribution, minus the guild fee (founder collects it). Guild uptime = share of members online. Guild leaderboard in the Company tab.
- **3D globe (🌍 World button):** dot-matrix Earth, a pin per company at its city (pin colour = guild, height = validators), white ripples for blocks, red for slashes, orange for outages, green when a company joins. Arcs link your guild (or the selected company's guild). Click a pin to view and stake. Players choose a city; real location is never used.
- **Badges, season leaderboard** (top 10 + your rank out of every company), offline earnings (50%, max 8h), local saves.
- **Live chain heartbeat:** polls `https://rpc.pulsechain.com` for real block numbers and gives a +10% bonus per new real block. Blocked inside the claude.ai artifact (no outside network calls); works when hosted on your own domain.

## Online play (Supabase)

The game connects to the Supabase project `ieiluyjwhpjzofvasyck` (URL and publishable key are in `CLOUD` at the top of the online section of `index.html`; the publishable key is meant to be public).

- **Sign-in:** email + password, or **Play as guest** (anonymous). Guests can attach an email later in the Company tab. **Play offline** skips the server entirely.
- **Cloud saves:** every 30 seconds and when the tab is hidden, via `submit_save` (rejects impossible progress). On sign-in the newer of cloud/local save wins; another account's local save is never uploaded.
- **Signed in = real players only:** the computer-run companies and guilds are hidden online (stakes with them are returned via unbonding). Offline play keeps the computer-run world.
- **Real players:** your company profile (name, chosen city, validators, reputation, commission, online) is published via `update_company`. Real players appear on the globe (white or guild-coloured pins), in the company list and on the leaderboard with 👤, alongside the computer-run companies.
- **Staking with real players:** `delegate` / `undelegate` run on the server first (coins checked there). Real players staking with *you* add to your total stake and pay you commission.
- **Real guilds:** found (5M coins), join, pool, withdraw and leave; pool changes go through `guild_pool`. Bot guilds still work locally.
- **Offline fallback:** if Supabase or the library CDN can't be reached (e.g. the claude.ai preview), the game runs exactly as before with local saves.

**One-time Supabase settings (dashboard):**
1. Authentication → Sign In / Providers → enable **Allow anonymous sign-ins** (for guest play).
2. Authentication → URL Configuration → set **Site URL** to the live Vercel address, so email confirmation links open the game.

**Deploy:** Vercel → Add New → Project → import `reniilservices/validatorgame`, framework *Other*, no build command. Every push to `main` redeploys.

## Run it locally

Any static server works:

```bash
npx serve .        # or: python -m http.server
```

## Deploy (Vercel)

Drop the folder into a Vercel project (framework: "Other"). No build command needed.

## Next steps

1. **Cast (done):** technicians Bogdan, Kwame, Diego, Amara (hired in that order); CEO at the desk (Mei, Zainab, Daniel or Priya, picked in the Company tab); the whale Maximus Vane (sunglasses and gold chain added in code); rival CEO Victor Crane at season end; visitors Kai and Lars; Bogdan digging during fibre cuts. Display names are original; the model files keep their source names (`chars/pete.glb` etc.). Characters only download when they first appear. If the asset files are missing, the game falls back to simple figures.
   - To add a character: convert the Mixamo FBX with `FBX2glTF --binary`, then `gltf-transform optimize in.glb chars/<name>.glb --texture-compress webp --texture-size 512 --compress meshopt`, and add its key to the cast lists in `index.html`.
   - Bone names are normalised in code (`mixamorig:`, `mixamorig1:` … all become plain names), and each character's hip height is scaled so every animation fits every rig.
2. **Supabase:** run `schema.sql`, add Supabase Auth, and call `submit_save(state)` every 30s instead of `localStorage`. Compute offline earnings server-side.
3. **Real players (guilds, staking with others, the globe):** run `multiplayer.sql`. Every interaction with other companies already goes through the `NET` object in `index.html`, so only its methods change:
   - `NET.companies()` → `select * from world_companies` (subscribe to realtime on `players` for live pins)
   - `NET.guilds()` → `select * from guild_pools`
   - `NET.delegate / undelegate` → `rpc('delegate' | 'undelegate', { p_company, p_amount })`
   - `NET.joinGuild / leaveGuild / foundGuild` → insert/delete in `guild_members`, insert in `guilds`; pool changes → `rpc('guild_pool', { p_delta })`
   - every 30s: `rpc('update_company', …)` with your city, validators, reputation, commission and online state
   - Keep the simulated companies as "bots" while the player count is small, so the world never looks empty.
4. **Contracts:** test on PulseChain testnet v4 with Hardhat or Foundry, get an audit, then deploy to chain ID 369. Wire `wagmi`/`viem` for wallet connect. Use bridged USDC/DAI for the prize pool.
5. **Legal:** keep entry free and prizes skill-based. Get Nigerian legal advice (ISA 2025 treats digital assets, including NFTs, as securities) before selling licences or running a prize pool.

## Cities, privacy and terms

- 51 player cities, listed A–Z (Accra → Zurich), with a strong U.S. lineup (Atlanta, Austin, Boston, Chicago, Dallas, Denver, Las Vegas, Los Angeles, Miami, New York, Phoenix, San Francisco, Seattle, Washington DC). Lagos is the only Nigerian city; old saves in removed cities are moved automatically.
- `privacy.html` and `terms.html` are linked from the sign-in box, the Company tab and the help screen. **Before launch, replace `[Operator name]`, `[contact email]`, `[State]` and `[County, State]` in both files.**

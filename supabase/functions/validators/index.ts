// Validator Tycoon — `validators` Edge Function.
// Links real PulseChain validators to a wallet-signed-in player after checking the beacon chain:
// a validator belongs to a player only if its withdrawal credentials (0x01/0x02) point at the player's wallet.
// Actions: link {ids, project_id?} · discover · refresh · unlink {ids}
import { createClient } from 'npm:@supabase/supabase-js@2';

const BEACONS = [
  'https://pulsechain-beacon-api.publicnode.com',
  'https://rpc-pulsechain.g4mm4.io/beacon-api',
];
const SCAN = 'https://api.scan.pulsechain.com/api/v2';
const MAX_IDS = 50, RECHECK_MS = 6 * 60 * 1000, FULL_GWEI = 32_000_000n * 1_000_000_000n;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

async function getJSON(url: string, ms = 9000) {
  const r = await fetch(url, { signal: AbortSignal.timeout(ms), headers: { accept: 'application/json' } });
  if (!r.ok) throw new Error(`${r.status} from ${new URL(url).host}`);
  return r.json();
}
async function beaconValidators(ids: string[]) {
  let last: unknown;
  for (const base of BEACONS) {
    try { return (await getJSON(`${base}/eth/v1/beacon/states/head/validators?id=${ids.join(',')}`)).data as any[]; }
    catch (e) { last = e; }
  }
  throw last ?? new Error('beacon API unavailable');
}
function walletOf(user: any): string | null {
  const web3 = user?.app_metadata?.provider === 'web3' || (user?.identities || []).some((i: any) => i.provider === 'web3');
  if (!web3 || user?.is_anonymous) return null;
  const hay = JSON.stringify([user.identities, user.user_metadata, user.app_metadata]);
  const m = hay.match(/0x[0-9a-fA-F]{40}/);
  return m ? m[0].toLowerCase() : null;
}
const owns = (v: any, addr: string) => {
  const wc = String(v?.validator?.withdrawal_credentials || '').toLowerCase();
  return (wc.startsWith('0x01') || wc.startsWith('0x02')) && ('0x' + wc.slice(-40)) === addr;
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ ok: false, reason: 'POST only' }, 405);
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  const { data: ud, error: ue } = await admin.auth.getUser(jwt);
  if (ue || !ud?.user) return json({ ok: false, reason: 'Sign in first.' }, 401);
  const user = ud.user, addr = walletOf(user);
  if (!addr) return json({ ok: false, reason: 'Sign in with a wallet to link real validators.' }, 403);

  let body: any = {};
  try { body = await req.json(); } catch { /* empty body */ }
  const action = String(body.action || 'refresh');

  // make sure the player row and the private wallet row exist
  await admin.from('players').upsert({ id: user.id }, { onConflict: 'id', ignoreDuplicates: true });
  const { data: wrow } = await admin.from('player_wallets').select('address').eq('player_id', user.id).maybeSingle();
  if (!wrow) {
    const { error } = await admin.from('player_wallets').insert({ player_id: user.id, address: addr });
    if (error) return json({ ok: false, reason: 'This wallet is already linked to another company.' }, 409);
  } else if (wrow.address !== addr) return json({ ok: false, reason: 'Wallet mismatch for this account.' }, 409);

  const messages: string[] = [];
  let ids: string[] = [];

  if (action === 'unlink') {
    ids = (body.ids || []).map((x: any) => String(x).trim()).filter((x: string) => /^\d+$/.test(x)).slice(0, MAX_IDS);
    if (ids.length) await admin.from('real_validators').delete().eq('player_id', user.id).in('validator_index', ids);
    messages.push(`Unlinked ${ids.length} validator${ids.length === 1 ? '' : 's'}.`);
  }

  if (action === 'discover') {
    try {
      const w = await getJSON(`${SCAN}/addresses/${addr}/withdrawals`, 12000);
      ids = [...new Set((w.items || []).map((i: any) => String(i.index ?? i.validator_index)).filter((x: string) => /^\d+$/.test(x)))].slice(0, MAX_IDS) as string[];
      if (!ids.length) messages.push('No validator payouts found for this wallet yet. Paste your validator numbers instead.');
    } catch { messages.push('The explorer is slow right now. Paste your validator numbers instead.'); }
  }

  if (action === 'link') {
    ids = (body.ids || []).map((x: any) => String(x).trim().toLowerCase())
      .filter((x: string) => /^\d+$/.test(x) || /^0x[0-9a-f]{96}$/.test(x)).slice(0, MAX_IDS);
    if (!ids.length) return json({ ok: false, reason: 'Enter validator numbers (index) or public keys.' }, 400);
  }

  let projectId: string | null = null;
  if (action === 'link' && body.project_id) {
    const { data: pr } = await admin.from('guild_projects').select('id, operator_id').eq('id', body.project_id).maybeSingle();
    if (!pr || pr.operator_id !== user.id) return json({ ok: false, reason: 'Only the project operator can link its validator.' }, 403);
    projectId = pr.id;
  }

  // link / discover: verify ownership on the beacon chain
  if ((action === 'link' || action === 'discover') && ids.length) {
    let vals: any[] = [];
    try { vals = await beaconValidators(ids); } catch { return json({ ok: false, reason: 'PulseChain beacon API is unreachable. Try again soon.' }, 502); }
    const mine = vals.filter(v => owns(v, addr)), notMine = vals.length - mine.length;
    const { data: taken } = await admin.from('real_validators').select('validator_index, player_id').in('validator_index', mine.map(v => v.index));
    const takenByOther = new Set((taken || []).filter(t => t.player_id !== user.id).map(t => String(t.validator_index)));
    const rows = mine.filter(v => !takenByOther.has(String(v.index))).map(v => ({
      validator_index: Number(v.index), player_id: user.id, pubkey: v.validator.pubkey, status: v.status,
      slashed: !!v.validator.slashed, balance_gwei: String(v.balance), effective_gwei: String(v.validator.effective_balance),
      start_balance_gwei: String(v.balance), healthy: true, checked_at: new Date().toISOString(),
      ...(projectId ? { project_id: projectId } : {}),
    }));
    const existing = new Set((taken || []).filter(t => t.player_id === user.id).map(t => String(t.validator_index)));
    const fresh = rows.filter(r => !existing.has(String(r.validator_index)));
    if (fresh.length) await admin.from('real_validators').insert(fresh);
    if (projectId) await admin.from('real_validators').update({ project_id: projectId }).eq('player_id', user.id).in('validator_index', rows.map(r => r.validator_index));
    if (rows.length) messages.push(`Linked ${rows.length} validator${rows.length === 1 ? '' : 's'}.`);
    if (notMine) messages.push(`${notMine} validator${notMine === 1 ? ' does' : 's do'} not pay out to this wallet, so ${notMine === 1 ? 'it was' : 'they were'} skipped.`);
    if (vals.length < ids.length) messages.push(`${ids.length - vals.length} not found on PulseChain.`);
    if (takenByOther.size) messages.push(`${takenByOther.size} already linked to another company.`);
  }

  // refresh this player's validators (at most every 6 minutes each)
  const { data: list } = await admin.from('real_validators').select('*').eq('player_id', user.id).order('validator_index');
  const stale = (list || []).filter(v => Date.now() - new Date(v.checked_at).getTime() > RECHECK_MS);
  if (stale.length) {
    try {
      const live = new Map((await beaconValidators(stale.map(v => String(v.validator_index)))).map(v => [String(v.index), v]));
      for (const old of stale) {
        const v = live.get(String(old.validator_index)); if (!v) continue;
        if (!owns(v, addr)) { await admin.from('real_validators').delete().eq('validator_index', old.validator_index); continue; }
        const prev = BigInt(old.balance_gwei), now = BigInt(v.balance), delta = now - prev;
        // PulseChain sweeps the excess above 32M PLS to the wallet: a drop down to ~32M is a payout, not downtime.
        const swept = delta < 0n && now <= FULL_GWEI + 1_000_000_000n && prev > FULL_GWEI;
        // positive deltas were already counted as they grew; after a sweep only the new excess is fresh
        const earned = BigInt(old.earned_gwei) + (delta > 0n ? delta : swept && now > FULL_GWEI ? now - FULL_GWEI : 0n);
        const healthy = String(v.status).startsWith('active') ? (delta > 0n || swept ? true : delta === 0n ? old.healthy : false) : false;
        await admin.from('real_validators').update({
          status: v.status, slashed: !!v.validator.slashed, balance_gwei: now.toString(), effective_gwei: String(v.validator.effective_balance),
          earned_gwei: earned.toString(), healthy, checked_at: new Date().toISOString(),
        }).eq('validator_index', old.validator_index);
      }
    } catch { messages.push('Could not refresh from PulseChain right now; showing the last check.'); }
  }

  const { data: out } = await admin.from('real_validators')
    .select('validator_index, status, slashed, balance_gwei, effective_gwei, earned_gwei, healthy, project_id, checked_at')
    .eq('player_id', user.id).order('validator_index');
  return json({ ok: true, wallet: addr, validators: out || [], messages });
});

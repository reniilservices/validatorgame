# Validator Tycoon community staking pool (design draft)

**Status: unaudited draft, testnet only.** `contracts/TycoonStakingPool.sol` refuses to deploy on PulseChain mainnet (chain 369). Do not remove that guard until the steps in "Path to mainnet" are done.

## Why

PulseChain needs more independent validators, but each one needs 32M PLS. Existing pools charge around 10% of rewards. This pool lets players combine any amount of PLS into real validators run by an operator they know, for a **3% fee on rewards (hard cap 5%)**.

## How it works

1. **Deposit** any amount (min 1 PLS). You get pool shares, priced by the pool's total assets.
2. **Stake.** Every time 32M PLS is free in the pool, the operator calls `stake()` with validator keys they generated. The contract forces the withdrawal credentials to `0x01…<this contract>`, so principal and rewards can only ever come back to the pool, never to the operator.
3. **Rewards.** PulseChain automatically sweeps validator rewards above 32M to the withdrawal address (this contract). The operator sets the node's fee recipient to this contract too. `harvest()` counts new PLS as rewards, takes the fee for the operator, and the rest raises every share's value.
4. **Withdraw.** `requestWithdrawal(shares)` locks in your PLS at today's value and puts you in a first-in, first-out queue. If the pool has free PLS, you're paid at once; otherwise the operator exits validators, and when the 32M principal returns, anyone can call `payQueue()` to pay the queue in order.

| Rule | Value |
|---|---|
| Operator fee | 3% of rewards (rewards only, never principal) |
| Fee cap | 5%, enforced by the contract |
| Fee raises | Wait 7 days (stakers can leave first); cuts apply instantly |
| Pausing | Can stop new deposits; can never stop withdrawals |
| Shares | Not transferable (no liquid token, no DeFi exposure) |

## Trust assumptions (the honest part)

The contract can't see the beacon chain, so stakers trust the operator to:

- keep validators online (offline validators slowly lose PLS, which lowers everyone's share value);
- never double-sign (slashing loss is shared by the whole pool);
- call `reportExit(n)` when exiting validators, so returning principal isn't counted as reward (otherwise the operator would take a fee on principal);
- call `reportLoss(amount)` honestly if exited principal comes back short;
- point the execution fee recipient at the pool.

The game's real-validator linking (wallet sign-in and the `validators` Edge Function) can show the pool's validators publicly, which gives stakers independent monitoring.

## Tested behaviour (local simulation)

`contracts/test/pool-sim.mjs` compiles the contract and runs it on a local chain:

- refuses to deploy on chain 369;
- forces withdrawal credentials to the pool;
- 1M rewards on a 32M validator: 3% fee (30k), the rest shared pro-rata (20M depositor is then worth 20.61M);
- late depositors buy in at the fair share price and don't dilute earlier ones;
- funds owed to the withdrawal queue can't be staked;
- after an exit, the queue is paid in full and the remaining shares exactly equal the remaining assets;
- fee cap, 7-day delay on raises, instant cuts, deposit pause and withdrawals-while-paused all behave as intended.

Run it: `cd contracts/test && npm i solc@0.8.24 ganache@7 ethers@6 && node pool-sim.mjs`

## Path to mainnet

1. Deploy on PulseChain testnet v4 (chain 943, same deposit contract address `0x3693…3693`) and run real validators for weeks.
2. Independent security audit. Fix everything, then re-audit.
3. Make the operator a multisig (for example a Safe with several trusted signers), not one wallet.
4. Decide on remaining open questions: queue fairness when slashing happens mid-queue, minimum operator bond, emergency exit process.
5. Get legal advice in the U.S. before offering it. Pooling other people's funds and sharing rewards can raise securities, money transmission and tax questions, even with the 2025 SEC staff statements on protocol and liquid staking. Keep marketing factual, never promise returns.
6. Only then remove the chain-369 guard, with a public announcement and the audit report.

Until then, the game's **guild validator projects** cover the same need without the game holding anyone's PLS.

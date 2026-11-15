import solc from 'solc';
import ganache from 'ganache';
import { ethers } from 'ethers';
import fs from 'fs';

const src = fs.readFileSync('../TycoonStakingPool.sol', 'utf8');
const mock = `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
contract MockDeposit { uint256 public count; bytes public lastCreds;
  function deposit(bytes calldata, bytes calldata wc, bytes calldata, bytes32) external payable { require(msg.value == 32_000_000 ether, "amount"); count++; lastCreds = wc; } }`;
const out = JSON.parse(solc.compile(JSON.stringify({ language:'Solidity', sources:{ 'Pool.sol':{ content:src }, 'Mock.sol':{ content:mock } },
  settings:{ optimizer:{ enabled:true, runs:200 }, outputSelection:{ '*':{ '*':['abi','evm.bytecode.object'] } } } })));
const errs = (out.errors || []).filter(e => e.severity === 'error'); if (errs.length){ console.log(errs.map(e => e.formattedMessage).join('\n')); process.exit(1); }
console.log('compiled; warnings:', (out.errors || []).length);
const P = out.contracts['Pool.sol'].TycoonStakingPool, M = out.contracts['Mock.sol'].MockDeposit;

async function chain(chainId){
  const g = ganache.provider({ chain:{ chainId }, wallet:{ totalAccounts:5, defaultBalance:1e10 }, logging:{ quiet:true } });
  const provider = new ethers.BrowserProvider(g); const signers = await Promise.all([0,1,2,3,4].map(i => provider.getSigner(i)));
  return { provider, signers };
}
const balOf = (pr, a) => pr.send('eth_getBalance', [a, 'latest']).then(BigInt);
const pls = n => ethers.parseEther(String(n));
const fmt = w => Number(ethers.formatEther(w)).toLocaleString('en-US', { maximumFractionDigits:2 });

// 1) refuses mainnet
{ const { signers } = await chain(369);
  const d = await new ethers.ContractFactory(M.abi, M.evm.bytecode.object, signers[0]).deploy();
  try { const c = await new ethers.ContractFactory(P.abi, P.evm.bytecode.object, signers[0]).deploy(await d.getAddress(), signers[0].address, 300, { gasLimit:5_000_000 }); await c.waitForDeployment(); console.log('FAIL: deployed on 369'); }
  catch (e) { console.log('mainnet guard: deployment on chain 369 reverted OK'); } }

// 2) full cycle on testnet v4 (943)
const { provider, signers } = await chain(943);
const [op, A, B, C, rewards] = signers;
const dep = await new ethers.ContractFactory(M.abi, M.evm.bytecode.object, op).deploy();
const pool = await new ethers.ContractFactory(P.abi, P.evm.bytecode.object, op).deploy(await dep.getAddress(), op.address, 300);
const addr = await pool.getAddress(); const as = s => pool.connect(s);
await (await as(A).deposit({ value:pls(20e6) })).wait();
await (await as(B).deposit({ value:pls(12e6) })).wait();
await (await pool.stake('0x' + '11'.repeat(48), '0x' + '22'.repeat(96), '0x' + '33'.repeat(32))).wait();
console.log('staked: validators', await pool.activeValidators(), 'cash', fmt(await pool.cash()), 'creds ok', (await dep.lastCreds()).toLowerCase() === ('0x01' + '00'.repeat(11) + addr.slice(2)).toLowerCase());
await (await rewards.sendTransaction({ to:addr, value:pls(1e6) })).wait();          // a reward sweep arrives
await (await pool.harvest()).wait();
console.log('after 1M rewards: totalAssets', fmt(await pool.totalAssets()), 'fees', fmt(await pool.operatorFees()), 'A', fmt(await pool.assetsOf(A.address)), 'B', fmt(await pool.assetsOf(B.address)));
await (await as(C).deposit({ value:pls(3e6) })).wait();
console.log('C deposits 3M -> C worth', fmt(await pool.assetsOf(C.address)));
const aShares = await pool.sharesOf(A.address);
await (await as(A).requestWithdrawal(aShares)).wait();
const c0 = await pool.claims(0);
console.log('A queued', fmt(c0.amount), 'paid?', c0.paid, 'cash', fmt(await pool.cash()));
try { await (await pool.stake('0x' + '44'.repeat(48), '0x' + '22'.repeat(96), '0x' + '33'.repeat(32))).wait(); console.log('FAIL: staked reserved funds'); } catch { console.log('cannot stake funds owed to the queue: OK'); }
await (await pool.reportExit(1)).wait();
const aBefore = await balOf(provider, A.address);
await (await rewards.sendTransaction({ to:addr, value:pls(32e6) })).wait();          // principal returns from the beacon chain
await (await as(B).payQueue(5)).wait();
const aGot = (await balOf(provider, A.address)) - aBefore;
console.log('after exit: A received', fmt(aGot), '(gain', fmt(aGot - pls(20e6)) + ')', 'claim paid', (await pool.claims(0)).paid);
console.log('remaining: totalAssets', fmt(await pool.totalAssets()), '= B', fmt(await pool.assetsOf(B.address)), '+ C', fmt(await pool.assetsOf(C.address)), '| fees', fmt(await pool.operatorFees()), '| contract bal', fmt(await balOf(provider, addr)));
// fee rules
try { await (await pool.scheduleFee(600)).wait(); console.log('FAIL: fee above cap'); } catch { console.log('fee cap 5%: OK'); }
await (await pool.scheduleFee(450)).wait();
try { await (await pool.applyFee()).wait(); console.log('FAIL: instant raise'); } catch { console.log('fee raise waits 7 days: OK'); }
await (await pool.scheduleFee(200)).wait(); console.log('fee lowered instantly to', await pool.feeBps());
const opBefore = await balOf(provider, op.address); await (await pool.withdrawFees(op.address)).wait();
console.log('operator fee withdrawn ~', fmt((await balOf(provider, op.address)) - opBefore), 'pool still solvent:', (await balOf(provider, addr)) >= (await pool.trackedBalance()));
// pause blocks deposits but not withdrawals
await (await pool.setDepositsPaused(true)).wait();
try { await (await as(C).deposit({ value:pls(1) })).wait(); console.log('FAIL: deposit while paused'); } catch { console.log('pause blocks deposits: OK'); }
await (await as(C).requestWithdrawal(await pool.sharesOf(C.address))).wait();
console.log('C withdrew while paused, claim paid:', (await pool.claims(1)).paid);
process.exit(0);

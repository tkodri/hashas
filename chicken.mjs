// chicken.mjs — ChickenHash miner, multi-wallet. npm i ethers ; node chicken.mjs
import { ethers } from "ethers";
import os from "os";

const PRIVATE_KEYS = ["0xWALLET1", "0xWALLET2"]; // isi 2-10 key
const RPC = "https://rpc.mainnet.chain.robinhood.com";
const CONTRACT = "0xcC13C70834516C47266C1d37dd5bb173EED8deCf";
const THREADS = os.cpus().length;
const CHUNK = 20000;

const ABI = [
  "function miningState() view returns (tuple(bytes32 challenge,uint256 currentTarget,uint256 storedTarget,uint256 price,uint256 epoch,uint256 totalMinted,uint256 maxSupply,bool mintOpen,uint256 lastMintTime,uint256 targetInterval,uint256[10] prices,uint256 maxPerWallet,uint256 freePerWallet,uint256 timestamp))",
  "function mint(uint256 nonce, bytes32 expectedChallenge) payable returns (uint256)",
  "function freeLeft(address) view returns (uint256)",
  "function minedCount(address) view returns (uint256)",
];

const provider = new ethers.JsonRpcProvider(RPC, 4663);
const con = new ethers.Contract(CONTRACT, ABI, provider);
let cursor = BigInt(Math.floor(Math.random() * 1e12));

async function mineChunk(challenge, miner, target, start, count) {
  for (let i = 0n; i < count; i++) {
    const n = start + i;
    const h = ethers.solidityPackedKeccak256(
      ["bytes32", "address", "uint256"], [challenge, miner, n]);
    if (BigInt(h) < target) return n;
  }
  return null;
}

while (true) {
  const s = await con.miningState();
  if (!s.mintOpen) { console.log("closed, sleep"); await new Promise(r => setTimeout(r, 10000)); continue; }
  if (s.totalMinted >= s.maxSupply) { console.log("SOLD OUT"); break; }
  let act = null;
  for (const pk of PRIVATE_KEYS) {
    if (pk.includes("WALLET")) continue;
    const w = new ethers.Wallet(pk, provider);
    if (await con.minedCount(w.address) >= s.maxPerWallet) continue;
    if (s.price === 0n && await con.freeLeft(w.address) === 0n) continue;
    act = w; break;
  }
  if (!act) { console.log("semua wallet habis jatah"); break; }
  console.log(`[ep${s.epoch + 1n} ${s.totalMinted}/${s.maxSupply}] mining for ${act.address} diff=${(1n << 256n) / (s.currentTarget + 1n)}`);
  const jobs = [];
  for (let t = 0; t < THREADS; t++) jobs.push(mineChunk(s.challenge, act.address, s.currentTarget, cursor + BigInt(t * CHUNK), BigInt(CHUNK)));
  const res = await Promise.all(jobs);
  cursor += BigInt(THREADS * CHUNK);
  const found = res.find(x => x !== null);
  const s2 = await con.miningState();
  if (s2.challenge !== s.challenge) { console.log("keduluan, challenge baru"); continue; }
  if (found == null) continue;
  console.log("FOUND", found.toString(), "submit...");
  try {
    const tx = await con.connect(act).mint(found, s.challenge, { value: s.price });
    console.log("TX", tx.hash); await tx.wait(); console.log("SUKSES");
  } catch (e) { console.log("gagal:", String(e).slice(0, 200)); }
}

# chicken_multi.py — ChickenHash solo miner, MULTI-WALLET, multi-core
# Chain: Robinhood Chain 4663 | Contract: 0xcC13C70834516C47266C1d37dd5bb173EED8deCf
# Logic: keccak256(challenge + miner + nonce) < target -> mint(nonce, challenge)
# pip install web3
import os, sys, time, random, multiprocessing as mp
from web3 import Web3

# ============ EDIT INI ============
PRIVATE_KEYS = [
    "0xWALLET1",
    "0xWALLET2",
    # tambah sampai 10...
]
RPC = "https://rpc.mainnet.chain.robinhood.com"
THREADS = os.cpu_count() or 4
CHUNK_PER_WORKER = 50000
# ===================================

CONTRACT = Web3.to_checksum_address("0xcC13C70834516C47266C1d37dd5bb173EED8deCf")
CHAIN_ID = 4663
ABI = [
 {"inputs":[],"name":"miningState","outputs":[{"components":[
  {"name":"challenge","type":"bytes32"},{"name":"currentTarget","type":"uint256"},
  {"name":"storedTarget","type":"uint256"},{"name":"price","type":"uint256"},
  {"name":"epoch","type":"uint256"},{"name":"totalMinted","type":"uint256"},
  {"name":"maxSupply","type":"uint256"},{"name":"mintOpen","type":"bool"},
  {"name":"lastMintTime","type":"uint256"},{"name":"targetInterval","type":"uint256"},
  {"name":"prices","type":"uint256[10]"},{"name":"maxPerWallet","type":"uint256"},
  {"name":"freePerWallet","type":"uint256"},{"name":"timestamp","type":"uint256"}],
  "name":"s","type":"tuple"}],"stateMutability":"view","type":"function"},
 {"inputs":[{"name":"nonce","type":"uint256"},{"name":"expectedChallenge","type":"bytes32"}],
  "name":"mint","outputs":[{"name":"tokenId","type":"uint256"}],"stateMutability":"payable","type":"function"},
 {"inputs":[{"name":"who","type":"address"}],"name":"freeLeft","outputs":[{"name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
 {"inputs":[{"name":"","type":"address"}],"name":"minedCount","outputs":[{"name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
]

def mine_range(ch_hex, miner_addr, target_int, start, count):
    from eth_utils import keccak
    pre = bytes.fromhex(ch_hex[2:]) + bytes.fromhex(miner_addr[2:])
    for i in range(start, start + count):
        if int.from_bytes(keccak(pre + i.to_bytes(32, "big")), "big") < target_int:
            return i
    return None

def main():
    KEYS = [k for k in PRIVATE_KEYS if "WALLET" not in k and len(k) > 10]
    if not KEYS: print("Isi PRIVATE_KEYS dulu!"); sys.exit(1)
    w3 = Web3(Web3.HTTPProvider(RPC, request_kwargs={"timeout": 15}))
    assert w3.is_connected(), "RPC fail"
    accts = [(w3.eth.account.from_key(k), k) for k in KEYS]
    print(f"{len(accts)} wallet | chain {w3.eth.chain_id} | threads {THREADS}")
    for a, _ in accts:
        print(f" - {a.address} bal={float(w3.from_wei(w3.eth.get_balance(a.address),'ether')):.5f} ETH")
    con = w3.eth.contract(address=CONTRACT, abi=ABI)
    pool = mp.Pool(THREADS)
    cursor = random.randrange(0, 2**64)
    total_h = 0; t0 = time.time()
    try:
        while True:
            s = con.functions.miningState().call()
            ch, target, price = s[0], int(s[1]), s[3]
            epoch, minted, maxsup, is_open, maxpw = s[4], s[5], s[6], s[7], s[11]
            ch_hex = "0x" + (ch.hex() if isinstance(ch, bytes) else ch.hex())
            diff = (1 << 256) // (target + 1)
            if not is_open: print("mint closed, sleep 10s"); time.sleep(10); continue
            if minted >= maxsup: print("SOLD OUT"); break
            active = None
            for acct, pk in accts:
                if con.functions.minedCount(acct.address).call() >= maxpw: continue
                if price == 0 and con.functions.freeLeft(acct.address).call() == 0: continue
                if w3.eth.get_balance(acct.address) == 0:
                    print(f"{acct.address} saldo 0, skip (isi gas)"); continue
                active = (acct, pk); break
            if not active: print("Semua wallet habis jatah / saldo 0. Selesai."); break
            acct, pk = active
            hr = total_h / (time.time() - t0) if time.time() - t0 > 1 else 0
            print(f"[ep{epoch+1} {minted}/{maxsup}] mining untuk {acct.address[:10]}.. diff={diff:,} speed={hr/1e6:.2f} MH/s")
            args = [(ch_hex, acct.address, target, cursor + i * CHUNK_PER_WORKER, CHUNK_PER_WORKER) for i in range(THREADS)]
            found = None
            for r in [pool.apply_async(mine_range, a) for a in args]:
                v = r.get()
                if v is not None: found = v
            total_h += THREADS * CHUNK_PER_WORKER
            cursor = (cursor + THREADS * CHUNK_PER_WORKER) % (2**256 - 10**7)
            c2 = con.functions.miningState().call()[0]
            c2hex = "0x" + (c2.hex() if isinstance(c2, bytes) else c2.hex())
            if c2hex.lower() != ch_hex.lower(): print("Keduluan orang, ganti challenge..."); continue
            if found is None: continue
            print(f"FOUND nonce={found} untuk {acct.address}, submit...")
            try:
                est = con.functions.mint(found, ch_hex).estimate_gas({"from": acct.address, "value": price})
                tx = con.functions.mint(found, ch_hex).build_transaction({
                    "from": acct.address, "value": price, "gas": int(est*15//10),
                    "gasPrice": w3.eth.gas_price, "nonce": w3.eth.get_transaction_count(acct.address),
                    "chainId": CHAIN_ID})
                h = w3.eth.send_raw_transaction(w3.eth.account.sign_transaction(tx, pk).raw_transaction)
                print(f"TX {h.hex()} menunggu...")
                rc = w3.eth.wait_for_transaction_receipt(h, timeout=120)
                print("SUKSES!" if rc.status == 1 else "REVERT (keduluan). Lanjut.")
            except Exception as e:
                print(f"submit gagal: {str(e)[:250]}")
                time.sleep(2)
    except KeyboardInterrupt: print("\nStop.")
    finally: pool.terminate()

if __name__ == "__main__":
    mp.freeze_support(); main()

# ChickenHash Miner (Robinhood Chain)

Solo PoW miner untuk ChickenHash: 7.000 pixel hens di Robinhood Chain (4663).

- Hash: `keccak256(challenge + miner + nonce) < target` -> `mint(nonce, challenge)`
- Kontrak: `0xcC13C70834516C47266C1d37dd5bb173EED8deCf`
- Max 2 hens / wallet. Epoch 1 FREE (gas only).

## Python (multi-wallet, multi-core, recommended VPS)

```bash
pip install -r requirements.txt
# isi PRIVATE_KEYS di chicken_multi.py (wallet fresh, JANGAN wallet utama)
python3 chicken_multi.py
```

## Node.js

```bash
npm install
# isi PRIVATE_KEYS di chicken.mjs
node chicken.mjs
```

## Disclaimer

Difficulty saat penulisan ~28T hash. Solo CPU = lotre. Fokus hashrate ke 1 wallet sampai 2/2 lalu otomatis pindah. Jangan share private key.

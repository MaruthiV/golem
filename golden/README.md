# The golem contract

This directory is the source of truth for golem's hardware. The golden model is a pure-integer
NumPy implementation of the network; every RTL block must match it bit for bit. If RTL and golden
disagree, the RTL is wrong (or this spec is — either way, fix happens here first).

No floats exist anywhere in the inference path: int8 tensors in, int32 logits out.

## The model

Decoder-only transformer, trained on TinyStories:

- d_model 256, 8 layers, 8 heads (head_dim 32), MLP 3x (GELU), context 256, vocab 4096 (BPE)
- RMSNorm (no bias, no mean-subtract), learned absolute position embeddings, tied embeddings
- 6,361,344 parameters = 6.36MB at int8

## Number formats

- Activations: int8, symmetric, per-tensor scales (calibrated). Range [-127, 127] (never -128).
- Weights: int8, symmetric, per-channel (per output row) scales for linears; per-tensor for
  embeddings and norm gains.
- Accumulators: int32 (worst case 127·127·768 ≈ 2^23.6, margin to spare).
- Softmax probabilities: **Q15 int16** (0..32768). Do not quantize probs to int8 — at T=256 the
  typical probability sits below int8 resolution and the distribution collapses (measured: +10%
  loss delta at int8 probs vs +3.2% at Q15).

## Requantization (the one rounding rule)

Scale conversion factors r are encoded as (M, S) with M in [2^30, 2^31) and r = M · 2^-S:

    q = clip( (acc · M + 2^(S-1)) >> S , -127, 127 )

Signed arithmetic, arithmetic right shift, round-half-up (ties toward +inf). The 64-bit
intermediate acc·M is required. All exported matmul shifts satisfy S ≥ 1.

## Ops

- **matmul**: out[t,j] = requant(Σ_k x[t,k]·w[j,k], M[j], S[j]). Weights stored (out, in),
  streamed row-major — each weight byte is consumed exactly once per output row.
- **rmsnorm**: msq = round(Σx²/D) (D=256, exact shift); t = isqrt(msq << 12) (exact integer
  sqrt); inv = round(2^26 / t) ≈ 2^20/rms(x-codes); acc = x·inv·g; out = requant(acc, M, S).
  Input scale cancels (x/rms is scale-invariant); the norm needs one integer divide per token.
  msq == 0 guard: output 0.
- **softmax** (per row, causal): d = rowmax - score (int32, masked lanes excluded);
  idx = clip(requant(d, M_sm, S_sm), 0, 511); e = EXP_LUT[idx] (Q15, exp(-idx/32));
  p = (e << 15) / Σe (integer divide, one per row). Probs are Q15.
- **attention out**: acc[t,j] = Σ_s p[t,s]·v[s,j] — an int16(Q15) × int8 multiply stage —
  then requant with r = s_v / (2^15 · s_att).
- **gelu**: 256-entry int8→int8 LUT per layer, built at export from the real gelu and the
  up/gel scales. Index = code + 127.
- **residual add**: both operands requantized to the output scale, added, saturated.
- **embedding**: x0 = sat(requant(tok_row) + requant(pos_row)).
- **logits**: out_norm output × tok_emb^T, left as int32. Dequant scale for the host:
  logit_scale = s_on · s_tok. Greedy decoding = argmax(int32) — float-free.

## Artifacts

- `data/golem_int8.npz` — all int8 weights, per-channel (M, S) vectors, per-layer GELU LUTs,
  the shared EXP LUT, logit_scale. Produced by `quant/quantize.py` from the fp32 checkpoint +
  `data/act_scales.json` (produced by `quant/calibrate.py`).
- `data/vectors/` — per-layer int test vectors captured from a real sequence
  (`golden/vectors.py`). Every RTL block is verified against these plus randomized cases.

## Hardware notes

- The engine is weight-streaming: tok/s ≈ memory_bandwidth / model_bytes. Keep the MACs fed.
- Fixed schedule, no data-dependent control flow: every token takes the same cycle count.
- Two integer divides per token per norm (17 norms) and one per softmax row are the only
  divides in the design.

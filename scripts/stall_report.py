import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

G = [
    ("S_IDLE", "idle"), ("S_HDR", "header scalars"), ("S_LUT", "exp LUT load"),
    ("S_ETOK", "token embedding"), ("S_EPOS", "pos embedding"), ("S_ECMB", "embed combine"),
    ("S_LX", "load x -> block"), ("S_SCAL", "layer scalars"), ("S_PARM", "per-channel params"),
    ("S_GATN", "attn-norm gains"), ("S_GMLP", "mlp-norm gains"), ("S_GELU", "gelu LUT"),
    ("S_START", "block start"), ("S_WT", "WEIGHT STREAM"), ("S_CAP", "block drain"),
    ("S_NEXT", "layer advance"), ("S_ON_G", "out-norm gain"), ("S_ON_RUN", "out-norm compute"),
    ("S_LG", "LOGITS argmax"), ("S_DONE", "done"),
]
C = ["init", "init-precharge", "init-refresh", "init-LMR", "IDLE (accepting)", "ACT (tRCD wait)",
     "rcd", "rd", "CAS wait", "WR", "tRP wait", "REFRESH"]
A = ["pick", "issue-write", "issue-read", "wait-data", "cooldown"]

PAGE = 256  # words per SDRAM page from the {bank,row,col[7:0]} map


def bar(frac, w=28):
    n = int(round(frac * w))
    return "█" * n + "·" * (w - n)


def main():
    p = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "data" / "stall_baseline.json"
    d = json.loads(p.read_text())

    tot = d["cyc_total"]
    mrd_stall = d["cyc_mrd_stall"]
    kv_stall = d["cyc_kv_stall"]
    reads = d["n_mrd_reads"] + d["n_kv_reads"]
    ideal = tot - mrd_stall - kv_stall

    final = bool(d.get("final", 1))
    print(f"\nT30 STALL ACCOUNTING — {p.name} ({d['tokens']} token)")
    if not final:
        print("*** PARTIAL SNAPSHOT mid-token — ratios are valid, per-token totals are NOT ***")
    print("=" * 74)
    print(f"total cycles/token        {tot:>14,}")
    print(f"ideal (instant memory)    {ideal:>14,}   <- what it'd be with 0-latency reads")
    print(f"schedule efficiency       {ideal / tot:>13.2%}   <- THE baseline number")
    print(f"stalled on weights/cfg    {mrd_stall:>14,}  ({mrd_stall / tot:.1%})")
    print(f"stalled on KV             {kv_stall:>14,}  ({kv_stall / tot:.1%})")
    print(f"arbiter blocked (cmd)     {d['cyc_cmd_wait']:>14,}  ({d['cyc_cmd_wait'] / tot:.1%})")
    print(f"bus idle, nobody asking   {d['cyc_bus_idle']:>14,}  ({d['cyc_bus_idle'] / tot:.1%})")
    print()
    print(f"weight/config reads       {d['n_mrd_reads']:>14,}")
    print(f"KV reads / writes         {d['n_kv_reads']:>14,} / {d['n_kv_writes']:,}")
    print(f"refreshes                 {d['n_refresh']:>14,}")
    print(f"CYCLES PER MEMORY WORD    {tot / max(reads, 1):>14.2f}   <- the number to kill")

    print("\n" + "-" * 74)
    print("WHERE THE CYCLES GO (golem FSM state)")
    print("-" * 74)
    rows = sorted(
        ((G[i][0], G[i][1], c, d["golem_state_stall"][i]) for i, c in enumerate(d["golem_state_cycles"]) if c),
        key=lambda r: -r[2])
    print(f"{'state':<10}{'what':<20}{'cycles':>13} {'%tot':>6} {'stalled':>13} {'stall%':>7}")
    for name, desc, cyc, stl in rows:
        print(f"{name:<10}{desc:<20}{cyc:>13,} {cyc / tot:>6.1%} {stl:>13,} {stl / cyc:>7.1%}")

    print("\n" + "-" * 74)
    print("WHERE THE MEMORY TIME GOES (SDRAM controller state)")
    print("-" * 74)
    crows = sorted(((C[i], c) for i, c in enumerate(d["ctrl_state_cycles"]) if c), key=lambda r: -r[1])
    for name, cyc in crows:
        print(f"{name:<20}{cyc:>13,} {cyc / tot:>7.1%}  {bar(cyc / tot)}")

    print("\n" + "-" * 74)
    print("ARBITER OVERHEAD")
    print("-" * 74)
    for i, cyc in enumerate(d["arb_state_cycles"]):
        if cyc:
            print(f"{A[i]:<20}{cyc:>13,} {cyc / tot:>7.1%}  {bar(cyc / tot)}")

    # T34 prediction: one ACTIVE per page instead of per word
    act = d["ctrl_state_cycles"][5] + d["ctrl_state_cycles"][10]  # tRCD + tRP
    cas = d["ctrl_state_cycles"][8]
    per_word_overhead = (act + cas) / max(reads, 1)
    burst_tot = ideal + (act + cas) / PAGE + d["ctrl_state_cycles"][11]
    print("\n" + "=" * 74)
    print("T34 PREDICTION — full-page bursts (DERIVED, not measured)")
    print("=" * 74)
    print(f"per-word ACT+tRP+CAS overhead   {per_word_overhead:>10.2f} cycles")
    print(f"amortized over a {PAGE}-word page  {per_word_overhead / PAGE:>10.4f} cycles")
    print(f"speedup on this traffic         {tot / max(burst_tot, 1):>10.1f}x")
    if final:
        print(f"predicted cycles/token          {burst_tot:>10,.0f}")
        print(f"predicted tok/s @ 27MHz         {27e6 / max(burst_tot, 1):>10.1f}   (from {27e6 / tot:.2f} today)")
        print(f"predicted tok/s @ 166MHz mem    {166e6 / max(burst_tot, 1):>10.1f}   (T34.5, needs the PLL)")
    else:
        print("(per-token and tok/s projections suppressed — partial snapshot)")
    print("\nGATE G3.5: weight-read stalls must dominate, and T34 must measure >=4x.")
    print()


if __name__ == "__main__":
    main()

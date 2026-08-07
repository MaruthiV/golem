import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# the measured optimization arc, in order
STEPS = [
    ("baseline", "stall_baseline.json", "per-word ACT+CAS+PRE, one word per request"),
    ("T34b", "stall_t34b.json", "full-page bursts + single line buffer"),
    ("T37", "stall_t37.json", "two ping-pong lines: fill overlaps compute"),
]
BUS_BITS = 32          # Gowin DS226-2.7E: GW2AR-18 QN88 SDR SDRAM is 32-bit
CLK = 27e6             # golem's current fabric/memory clock
RATED = 166e6          # the SDRAM's rated clock, same datasheet


def load(name):
    p = ROOT / "data" / name
    return json.loads(p.read_text()) if p.exists() else None


def main():
    rows = []
    base = None
    for label, fname, what in STEPS:
        d = load(fname)
        if d is None:
            print(f"(skipping {label}: data/{fname} not found)", file=sys.stderr)
            continue
        cyc = d["cyc_total"]
        words = d["n_mrd_reads"] + d["n_kv_reads"] + d["n_kv_writes"]
        ideal = cyc - d["cyc_mrd_stall"] - d["cyc_kv_stall"]
        mbps = words * 4 / (cyc / CLK) / 1e6
        base = base or cyc
        rows.append(dict(
            label=label, what=what, cyc=cyc, cpw=cyc / d["n_mrd_reads"],
            eff=ideal / cyc, mbps=mbps, pct=mbps * 1e6 / (BUS_BITS * CLK / 8),
            toks=CLK / cyc, toks_rated=RATED / cyc, speedup=base / cyc,
            stream=d["ctrl_state_cycles"][6] / cyc,
        ))

    w = "| step | change | cycles/token | cyc/word | sched eff | MB/s | % theo BW | tok/s | speedup |"
    print("\n" + w)
    print("|" + "---|" * 9)
    for r in rows:
        print(f"| {r['label']} | {r['what']} | {r['cyc']:,} | {r['cpw']:.3f} | {r['eff']:.2%} "
              f"| {r['mbps']:.1f} | {r['pct']:.1%} | {r['toks']:.2f} | {r['speedup']:.2f}x |")

    print(f"\nMeasured in simulation, one token, bit-exact vs the golden model at every step.")
    print(f"Theoretical bandwidth = {BUS_BITS} bits x {CLK/1e6:.0f} MHz = "
          f"{BUS_BITS * CLK / 8 / 1e6:.0f} MB/s.")
    if rows:
        r = rows[-1]
        print(f"\nAt the SDRAM's RATED {RATED/1e6:.0f} MHz the same design would be "
              f"{r['cyc']/RATED*1e3:.2f} ms/token = {r['toks_rated']:.1f} tok/s "
              f"({r['mbps']*RATED/CLK:.0f} MB/s), CONDITIONAL on Fmax (unmeasured — T45).")
        print(f"Against that rated {BUS_BITS * RATED / 8 / 1e6:.0f} MB/s peak, "
              f"{r['label']} sits at {r['mbps']*1e6/(BUS_BITS*RATED/8):.1%}.")

    print("""
CAVEATS that must travel with these numbers:
- Simulated against rtl/sdram_chip.sv with sim timing params. NOT measured on silicon (T48).
- "% theo BW" is against the 27 MHz clock ceiling, not the chip's rated 166 MHz peak. Quote both.
- The published 85% bar (arXiv 2502.10659) is DDR4 / 64-bit / LLaMA2-7B on a KV260. Only the
  methodology transfers; golem does not compete with it on throughput or model scale.
- tok/s is derived from measured cycle counts at a stated clock, not wall-clock on hardware.""")


if __name__ == "__main__":
    main()

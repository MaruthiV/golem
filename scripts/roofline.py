"""T33: turn the stall probes into the numbers docs/claims.md quotes.

Every figure here is derived from a measured cycle count plus the SDRAM datasheet, and the two
efficiency denominators are kept apart on purpose (see docs/claims.md):
  schedule efficiency   = weight-read words / total cycles      (bandwidth-independent)
  % theoretical         = achieved bytes/s / (width x clock)    (needs a real clock)

  python scripts/roofline.py                 # the arc, as a markdown table
  python scripts/roofline.py --clock 66      # project tok/s at another clock
  python scripts/roofline.py --plot roofline.svg
"""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"

BUS_BITS = 32
RATED_MHZ = 166.0          # Gowin DS226-2.7E
BYTES_PER_WORD = BUS_BITS // 8

# the arc, in the order it happened; (file, label)
ARC = [
    ("stall_baseline.json", "baseline (auto-precharge per word)"),
    ("stall_t34b.json", "full-page bursts"),
    ("stall_t37.json", "+ line buffer + ping-pong (LB=8)"),
    ("stall_rqnarrow.json", "LB=6 (traded for area)"),
    ("stall_lb7_rqnarrow.json", "LB=7 (shipped)"),
    ("stall_t68.json", "+ SDRAM timings derived from ns"),
]


def load(name):
    with open(DATA / name) as f:
        d = json.load(f)
    cyc, reads = d["cyc_total"], d["n_mrd_reads"]
    return {
        "cycles": cyc,
        "reads": reads,
        "bytes": reads * BYTES_PER_WORD,
        "sched_eff": reads / cyc,
        "cycles_per_word": cyc / reads,
        "useful": d.get("cyc_useful"),
        "mrd_stall": d.get("cyc_mrd_stall"),
        "refresh": d.get("n_refresh"),
    }


def at_clock(r, mhz):
    secs = r["cycles"] / (mhz * 1e6)
    bw = r["bytes"] / secs
    return {
        "ms": secs * 1e3,
        "toks": 1.0 / secs,
        "mbs": bw / 1e6,
        "pct_theoretical": bw / (RATED_MHZ * 1e6 * BYTES_PER_WORD),
    }


def svg(rows, clock, path):
    """Tiny hand-rolled SVG so this has no plotting dependency."""
    w, h, pad = 720, 340, 56
    lo, hi = 0.0, 1.0
    bars = []
    n = len(rows)
    bw = (w - 2 * pad) / n * 0.62
    for i, (label, r) in enumerate(rows):
        x = pad + (w - 2 * pad) * (i + 0.5) / n - bw / 2
        bh = (h - 2 * pad) * (r["sched_eff"] - lo) / (hi - lo)
        bars.append(
            f'<rect x="{x:.1f}" y="{h - pad - bh:.1f}" width="{bw:.1f}" height="{bh:.1f}" '
            f'fill="#3b6ea5"/>'
            f'<text x="{x + bw / 2:.1f}" y="{h - pad - bh - 6:.1f}" font-size="11" '
            f'text-anchor="middle" fill="#222">{r["sched_eff"] * 100:.1f}%</text>'
            f'<text x="{x + bw / 2:.1f}" y="{h - pad + 14:.1f}" font-size="9" '
            f'text-anchor="middle" fill="#555">{i}</text>')
    axis = (f'<line x1="{pad}" y1="{h - pad}" x2="{w - pad}" y2="{h - pad}" stroke="#888"/>'
            f'<line x1="{pad}" y1="{pad}" x2="{pad}" y2="{h - pad}" stroke="#888"/>')
    title = (f'<text x="{pad}" y="{pad - 22}" font-size="14" fill="#111">golem schedule '
             f'efficiency (weight-read words / cycles), measured in simulation</text>'
             f'<text x="{pad}" y="{pad - 6}" font-size="10" fill="#666">bars numbered in the '
             f'order the optimizations landed; NOT a % of memory bandwidth</text>')
    Path(path).write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
        f'viewBox="0 0 {w} {h}"><rect width="{w}" height="{h}" fill="#fff"/>'
        f'{title}{axis}{"".join(bars)}</svg>')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clock", type=float, default=27.0, help="system clock in MHz")
    ap.add_argument("--plot", default=None, help="write an SVG of the arc")
    args = ap.parse_args()

    rows = []
    for name, label in ARC:
        if (DATA / name).exists():
            rows.append((label, load(name)))
        else:
            print(f"  (missing {name}, skipped)")

    print(f"\n## The arc — measured cycles, schedule efficiency at any clock\n")
    print("| step | cycles/token | cycles/word | schedule eff |")
    print("|---|---|---|---|")
    for label, r in rows:
        print(f"| {label} | {r['cycles']:,} | {r['cycles_per_word']:.2f} | {r['sched_eff'] * 100:.1f}% |")
    first, last = rows[0][1], rows[-1][1]
    print(f"\n**{first['cycles'] / last['cycles']:.2f}x** end to end "
          f"({first['sched_eff'] * 100:.1f}% -> {last['sched_eff'] * 100:.1f}% schedule efficiency).")

    print(f"\n## Projected at {args.clock:g} MHz (DERIVED: measured cycles / clock, not silicon)\n")
    print("| step | ms/token | tok/s | achieved MB/s | % of 664 MB/s rated |")
    print("|---|---|---|---|---|")
    for label, r in rows:
        p = at_clock(r, args.clock)
        print(f"| {label} | {p['ms']:.1f} | {p['toks']:.2f} | {p['mbs']:.1f} | "
              f"{p['pct_theoretical'] * 100:.1f}% |")

    p = at_clock(last, args.clock)
    ceil_ms = last["bytes"] / (RATED_MHZ * 1e6 * BYTES_PER_WORD) * 1e3
    print(f"\nMemory-bound ceiling for {last['bytes'] / 1e6:.2f} MB/token at the rated "
          f"{RATED_MHZ:g} MHz: **{ceil_ms:.2f} ms = {1000 / ceil_ms:.1f} tok/s**.")
    print(f"At {args.clock:g} MHz golem is at {p['toks']:.2f} tok/s, "
          f"{p['pct_theoretical'] * 100:.1f}% of that rated bandwidth — the schedule is "
          f"{last['sched_eff'] * 100:.1f}% efficient, so what is left on the table is CLOCK, "
          f"not scheduling.")

    if args.plot:
        svg(rows, args.clock, args.plot)
        print(f"\nwrote {args.plot}")


if __name__ == "__main__":
    main()

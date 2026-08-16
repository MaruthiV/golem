# wstream: burst weight streaming for LLMs on small FPGAs

Three SystemVerilog files that keep a datapath fed from SDR SDRAM at ~91% of the ideal schedule
instead of the ~12% you get by asking the memory for one word at a time.

If you are putting a transformer on an FPGA, the memory subsystem is the part that decides your
tokens per second, and it is the part everyone hand-rolls badly. This is that part, extracted from a
working accelerator, parameterized, and measured.

```
lib/rtl/sdram_ctrl.sv    SDR SDRAM controller: init, full-page burst reads, refresh, timings in ns
lib/rtl/wstream.sv       page-aligned line buffer, two lines, ping-pong prefetch
lib/rtl/mem_arbiter.sv   multiplexes several requesters onto one command port
```

No vendor IP, no HLS, no Vivado. Built and verified with yosys, nextpnr, Icarus and cocotb.

## The measurement

Reading 4,096 sequential words through the real SDRAM protocol, with nothing else in the design:

| path | cycles/word | schedule efficiency |
|---|---|---|
| one command per word | 8.15 | 12.3% |
| **full-page bursts through `wstream`** | **1.10** | **91.1%** |

That is **7.4x**, and you can reproduce both rows in about a second:

```
python lib/sim/run_demo.py                  # burst path
DEMO_MODE=bypass python lib/sim/run_demo.py # one command per word
```

The example writes its own pattern, reads it back, checks every word, and reports the counters. It
needs no data file and no model.

In the accelerator this came from, the same three techniques took a full token from 19,591,114 cycles
to 1,770,097, which is **11.07x** end to end and 8.2% to 93.8% schedule efficiency, bit-exact at every
step. The standalone number is smaller because the demo's baseline loop is already tighter than the
original design's was.

## Why it is faster

SDR SDRAM makes you open a row before you read it and close it afterwards. Do that per word and you
pay ACTIVE, tRCD, CAS and tRP for every single value. A weight stream is perfectly sequential, so you
can open a row once and stream a whole page out of it.

Three things have to be true together, and missing any one of them costs you most of the win:

1. **Full-page bursts.** One row activation per page, not per word.
2. **Page-aligned lines.** An SDR burst wraps inside its page, so a line that straddles a row
   boundary quietly returns the wrong data. `wstream` aligns every fill.
3. **Ping-pong.** Two lines, so the next fill overlaps the current line being consumed. With one line
   the memory sits idle almost half the time while the datapath drains.

## Using it

`wstream` presents a read port that answers combinationally on a hit, so a datapath written against
zero-latency memory keeps working unchanged:

```systemverilog
wstream #(.LB(7), .LIMIT_ADDR(23'(MY_READONLY_END))) u_ws (
    .clk, .rst,
    .mrd_req, .mrd_addr, .mrd_valid, .mrd_data,      // your datapath
    .m_req, .m_addr, .m_len, .m_valid, .m_last, .m_data);  // to the arbiter or controller
```

| parameter | default | what it controls |
|---|---|---|
| `wstream.LB` | 8 | line size, `2^LB` words. Must not exceed one SDRAM page |
| `wstream.LIMIT_ADDR` | all ones | read-ahead never crosses this. Set it to the end of your read-only region so prefetch cannot touch addresses someone else writes |
| `sdram_ctrl.CLK_MHZ` | 27 | every timing below is converted from ns using this |
| `sdram_ctrl.tRCD_NS` / `tRP_NS` / `tRC_NS` | 15 / 15 / 60 | from your SDRAM datasheet |
| `sdram_ctrl.tREFI_NS` | 15625 | refresh interval. 4,096 refreshes per 64 ms is the usual figure |
| `sdram_ctrl.INIT_NS` | 200000 | power-up wait before the first command |
| `sdram_ctrl.CAS` | 2 | CAS latency, set in the mode register |
| `sdram_ctrl.PAGE` | 256 | words per page, from your address map |
| `mem_arbiter.KV_BASE` / `KV_STRIDE` | 0 / 131072 | where the second requester's two regions live |

Two things that will cost you a day if you skip them:

- **Wait for `init_done`.** SDR SDRAM needs roughly 200 us of power-up. Anything streaming data in
  before that is talking to a controller that cannot accept a word yet.
- **Hold `cmd_valid` until `cmd_ready`.** `cmd_ready` is combinational and means "accepted this
  cycle". A refresh can take any given cycle, so a requester that drops valid after one cycle loses
  commands at random.

## What this is not

It is an SDR SDRAM design. DDR needs a different data phase. It assumes your weights are stored in
the order you read them, which is what makes full-page bursts legal in the first place, so if your
packer emits some other layout the burst path will not help you. Reads are single-outstanding. The
arbiter's priority is fixed. There is no ECC and no scrubbing.

The efficiency figures are measured in simulation against a behavioural SDRAM model, through the real
command protocol including refresh. They have not yet been confirmed on physical silicon.

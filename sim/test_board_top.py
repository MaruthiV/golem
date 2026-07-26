import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Event, FallingEdge, First, RisingEdge

DATA = Path(__file__).resolve().parents[1] / "data"
CLKS = 8
N = 16                                   # words "uploaded" over UART (rest come from preload)


async def send_byte(dut, b):
    dut.uart_rx_pin.value = 0            # start bit
    await ClockCycles(dut.clk27, CLKS)
    for i in range(8):
        dut.uart_rx_pin.value = (b >> i) & 1
        await ClockCycles(dut.clk27, CLKS)
    dut.uart_rx_pin.value = 1            # stop bit
    await ClockCycles(dut.clk27, CLKS)


async def mon_tx(dut, out):
    while True:
        await FallingEdge(dut.uart_tx_pin)
        await ClockCycles(dut.clk27, CLKS + CLKS // 2)
        b = 0; bad = False
        for i in range(8):
            try:
                b |= int(dut.uart_tx_pin.value) << i
            except ValueError:
                bad = True
            await ClockCycles(dut.clk27, CLKS)
        out.append("X" if bad else b)


async def watch_reads(dut, ev, info):
    # trap the first controller read that returns X — logs its address (event-driven, fast)
    while True:
        await RisingEdge(dut.u_top.c_rvalid)
        try:
            int(dut.u_top.c_rdata.value)
        except ValueError:
            info["addr"] = int(dut.u_top.c_addr.value)
            info["wr"] = int(dut.u_top.c_wr.value)
            ev.set()
            return


@cocotb.test()
async def board(dut):
    ref = np.load(DATA / "greedy_ref.npy")
    words = (DATA / "golem_mem.hex").read_text().split()
    cocotb.start_soon(Clock(dut.clk27, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.uart_rx_pin.value = 1
    for _ in range(8):
        await RisingEdge(dut.clk27)
    dut.rst_n.value = 1

    got = []
    cocotb.start_soon(mon_tx(dut, got))
    xev = Event(); xinfo = {}
    cocotb.start_soon(watch_reads(dut, xev, xinfo))

    for w in words[:N]:                  # upload the first N words (correct values)
        val = int(w, 16)
        for i in range(4):
            await send_byte(dut, (val >> (8 * i)) & 0xFF)

    await RisingEdge(dut.u_top.load_done)
    dut._log.info("LOAD done -> golem released; generating first token...")
    await First(RisingEdge(dut.u_top.story_done), xev.wait())

    if xinfo:
        raise AssertionError(f"controller returned X on a read: addr={xinfo['addr']} "
                             f"(0x{xinfo['addr']:X}) wr={xinfo.get('wr')} — inout bus not driven "
                             f"when sampled (KV_BASE=1624264)")
    assert len(got) >= 2, f"no token streamed (got {got})"
    tok = (got[0] << 8) | got[1]
    want = int(ref[1])
    assert tok == want, f"board token {tok} != golden {want}"
    dut._log.info(f"PASS: golem_board_top UART-loaded weights, generated + streamed token "
                  f"{tok} over UART, bit-exact vs golden greedy")

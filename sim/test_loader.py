import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

N = 20


async def feed_byte(dut, b):
    dut.rx_data.value = b
    dut.rx_valid.value = 1
    await RisingEdge(dut.clk)
    dut.rx_valid.value = 0
    await ClockCycles(dut.clk, 40)      # gap for the triggered SDRAM write (mirrors slow UART)


async def feed_word(dut, w):
    for i in range(4):                  # little-endian, LSB first (matches pack.py)
        await feed_byte(dut, (w >> (8 * i)) & 0xFF)


async def t_rd(dut, addr):
    while not int(dut.t_ready.value):
        await RisingEdge(dut.clk)
    dut.t_valid.value = 1; dut.t_addr.value = addr
    await RisingEdge(dut.clk)
    dut.t_valid.value = 0
    while not int(dut.t_rvalid.value):
        await RisingEdge(dut.clk)
    return int(dut.t_rdata.value)


@cocotb.test()
async def load(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1; dut.rx_valid.value = 0; dut.t_valid.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst.value = 0

    words = [(0xC0DE0000 + i * 0x1111) & 0xFFFFFFFF for i in range(N)]
    for w in words:
        await feed_word(dut, w)

    for _ in range(400):
        if int(dut.load_done.value):
            break
        await RisingEdge(dut.clk)
    assert int(dut.load_done.value), "loader never asserted done"

    for a in range(N):
        got = await t_rd(dut, a)
        assert got == words[a], f"word[{a}] got {got:#x} want {words[a]:#x}"
    dut._log.info(f"weight_loader verified: {N} words streamed over UART landed in SDRAM bit-exact")

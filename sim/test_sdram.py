import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

DATA = Path(__file__).resolve().parents[1] / "data"


async def wait_ready(dut):
    while not int(dut.cmd_ready.value):
        await RisingEdge(dut.clk)


async def wr(dut, addr, val):
    await wait_ready(dut)
    dut.cmd_valid.value = 1; dut.cmd_wr.value = 1
    dut.cmd_addr.value = addr; dut.cmd_wdata.value = val
    await RisingEdge(dut.clk)
    dut.cmd_valid.value = 0
    await RisingEdge(dut.clk)


async def rd(dut, addr):
    await wait_ready(dut)
    dut.cmd_valid.value = 1; dut.cmd_wr.value = 0; dut.cmd_addr.value = addr
    await RisingEdge(dut.clk)
    dut.cmd_valid.value = 0
    while not int(dut.rd_valid.value):
        await RisingEdge(dut.clk)
    return int(dut.rd_data.value)


@cocotb.test()
async def readwrite(dut):
    hexwords = [int(x, 16) for x in (DATA / "golem_mem.hex").read_text().split()]
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1; dut.cmd_valid.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst.value = 0

    # 1) read preloaded weight words at a few addresses
    for addr in (0, 1, 100, 1000, 40000):
        got = await rd(dut, addr)
        assert got == hexwords[addr], f"read[{addr}] got {got:#x} want {hexwords[addr]:#x}"
    dut._log.info("preloaded reads OK")

    # 2) write/read roundtrip on scratch addresses (incl. a KV-region addr)
    cases = [(0x12345, 0xDEADBEEF), (0x1F0000, 0xCAFEF00D), (7, 0x00000001),
             (0x1FFFFF, 0xFFFFFFFF), (500, 0xA5A5A5A5)]
    for addr, val in cases:
        await wr(dut, addr, val)
    for addr, val in cases:
        got = await rd(dut, addr)
        assert got == val, f"roundtrip[{addr:#x}] got {got:#x} want {val:#x}"
    dut._log.info("write/read roundtrips OK")
    dut._log.info("PASS: SDR SDRAM controller + chip model verified")

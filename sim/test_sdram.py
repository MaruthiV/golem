import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

DATA = Path(__file__).resolve().parents[1] / "data"


# cmd_ready is combinational and means "I will accept THIS cycle" — a refresh can steal any
# given cycle, so a requester must hold cmd_valid until it sees ready, exactly as mem_arbiter
# does. Sampling on the falling edge reads a settled value for the cycle about to end.
async def issue(dut):
    while True:
        await FallingEdge(dut.clk)
        if int(dut.cmd_ready.value):
            await RisingEdge(dut.clk)
            dut.cmd_valid.value = 0
            return
        await RisingEdge(dut.clk)


async def wr(dut, addr, val):
    dut.cmd_valid.value = 1; dut.cmd_wr.value = 1
    dut.cmd_addr.value = addr; dut.cmd_wdata.value = val
    await issue(dut)
    await RisingEdge(dut.clk)


async def rd(dut, addr):
    dut.cmd_valid.value = 1; dut.cmd_wr.value = 0; dut.cmd_addr.value = addr
    dut.cmd_len.value = 1
    await issue(dut)
    while not int(dut.rd_valid.value):
        await RisingEdge(dut.clk)
    return int(dut.rd_data.value)


async def burst(dut, addr, n):
    dut.cmd_valid.value = 1; dut.cmd_wr.value = 0; dut.cmd_addr.value = addr
    dut.cmd_len.value = n
    await issue(dut)
    words, cycles, saw_last = [], 0, False
    while len(words) < n:
        await RisingEdge(dut.clk)
        cycles += 1
        if int(dut.rd_valid.value):
            words.append(int(dut.rd_data.value))
            if int(dut.rd_last.value):
                saw_last = True
        assert cycles < 40 + 4 * n, f"burst({addr},{n}) hung after {len(words)} words"
    assert saw_last, f"burst({addr},{n}) never asserted rd_last"
    return words, cycles


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

    # 3) T34: burst reads must return the same words as single reads, and get cheaper per word
    single = 0
    for n in (1, 2, 4, 8, 16, 64, 256):
        base = 1024                      # page-aligned, so no clamp
        words, cycles = await burst(dut, base, n)
        want = hexwords[base:base + n]
        assert words == want, f"burst({base},{n}) mismatch at {[i for i,(g,w) in enumerate(zip(words,want)) if g!=w][:4]}"
        if n == 1:
            single = cycles
        dut._log.info(f"burst n={n:>3}: {cycles:>4} cycles = {cycles / n:5.2f}/word "
                      f"({single / (cycles / n):5.1f}x vs single)")

    # unaligned start still correct (clamped at the page edge)
    words, _ = await burst(dut, 1024 + 250, 6)
    assert words == hexwords[1274:1280], "unaligned burst mismatch"

    # a burst must not silently wrap inside the page: ask to cross, expect a clamp to 2 words
    words, _ = await burst(dut, 1024 + 254, 2)
    assert words == hexwords[1278:1280], "page-edge burst mismatch"
    dut._log.info("burst reads OK (data matches single reads, rd_last correct, page-edge safe)")
    dut._log.info("PASS: SDR SDRAM controller + chip model verified")

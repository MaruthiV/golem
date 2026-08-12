import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

CLKS = 8


async def mon_tx(dut, out):
    while True:
        await FallingEdge(dut.uart_tx_pin)
        await ClockCycles(dut.clk27, CLKS + CLKS // 2)
        b = 0
        for i in range(8):
            b |= int(dut.uart_tx_pin.value) << i
            await ClockCycles(dut.clk27, CLKS)
        out.append(b)


@cocotb.test()
async def selftest(dut):
    cocotb.start_soon(Clock(dut.clk27, 10, unit="ns").start())
    dut.rst_n.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk27)
    dut.rst_n.value = 1

    got = []
    cocotb.start_soon(mon_tx(dut, got))

    # writes 4 banks x 4 rows x 256 words, then bursts them all back
    for _ in range(400_000):
        await RisingEdge(dut.clk27)
        if int(dut.u_dut.st.value) == 4:
            break
    else:
        raise AssertionError("self-test never reached DONE")

    errs = int(dut.u_dut.errs.value)
    assert errs == 0, f"{errs} mismatches, first at word {int(dut.u_dut.first_bad.value)}"

    while len(got) < 16:
        await RisingEdge(dut.clk27)
    line = "".join(chr(b) for b in got[:16])
    assert line.startswith("P "), f"report says {line!r}"
    assert int(dut.led.value) & 0b0100, f"pass LED not lit (led={int(dut.led.value):06b})"
    dut._log.info(f"PASS: SDRAM self-test 4096 words over 4 banks, report {line.strip()!r}")

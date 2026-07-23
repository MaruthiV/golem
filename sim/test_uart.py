import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

CLKS = 8


async def rx(dut, out):
    while True:
        await FallingEdge(dut.tx)
        await ClockCycles(dut.clk, CLKS + CLKS // 2)
        b = 0
        for i in range(8):
            b |= int(dut.tx.value) << i
            await ClockCycles(dut.clk, CLKS)
        out.append(b)


@cocotb.test()
async def send_bytes(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1; dut.send.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)
    got = []
    cocotb.start_soon(rx(dut, got))
    want = [0x41, 0x00, 0xB5, 0x0F, 0xFF]
    for byte in want:
        while int(dut.busy.value):
            await RisingEdge(dut.clk)
        dut.send.value = 1; dut.data.value = byte
        await RisingEdge(dut.clk)
        dut.send.value = 0
        await RisingEdge(dut.clk)
        while int(dut.busy.value):
            await RisingEdge(dut.clk)
    for _ in range(CLKS * 4):
        await RisingEdge(dut.clk)
    assert got == want, f"UART decode {got} != sent {want}"
    dut._log.info(f"UART TX bytes verified: {[hex(b) for b in got]}")

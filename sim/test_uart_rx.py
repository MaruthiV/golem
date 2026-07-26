import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

CLKS = 8


async def send_byte(dut, b):
    dut.rx.value = 0                      # start bit
    await ClockCycles(dut.clk, CLKS)
    for i in range(8):
        dut.rx.value = (b >> i) & 1       # LSB first
        await ClockCycles(dut.clk, CLKS)
    dut.rx.value = 1                       # stop bit
    await ClockCycles(dut.clk, CLKS)


async def mon(dut, out):
    while True:
        await RisingEdge(dut.clk)
        if int(dut.valid.value):
            out.append(int(dut.data.value))


@cocotb.test()
async def receive(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1; dut.rx.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    got = []
    cocotb.start_soon(mon(dut, got))
    want = [0x41, 0x00, 0xB5, 0x0F, 0xFF, 0x7E]
    for b in want:
        await send_byte(dut, b)
    await ClockCycles(dut.clk, CLKS * 2)
    assert got == want, f"UART RX {got} != {want}"
    dut._log.info(f"UART RX verified: {[hex(x) for x in got]}")

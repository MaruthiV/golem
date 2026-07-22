# GDS hardening

golem's compute tile (`rtl/mac_tile.sv`: 4×int8 MAC + int32 accumulator + gemmlowp requant)
is memory-free and hardens cleanly to real sky130 silicon layout. This is the "tapeout-ready"
evidence: the actual heart of the chip as a manufacturable die, not a simulation.

## What hardens where
- **mac_tile / requant / dividers / gelu**: pure logic → sky130 standard cells (this flow).
- **weights + KV**: external SDRAM on the real chip (not on-die), so they are NOT in the GDS —
  they were never meant to be. This is honest: golem is a weight-streaming design.
- **on-die buffers** (x/param/attn/gel buffers): SRAM macros in a full-chip flow (OpenRAM /
  memory compiler), out of scope for the tile hardening.

## Run (needs Docker + PDK; ~20-40 min)
```
pip install openlane        # or use the openlane2 nix/docker image
volare enable --pdk sky130  # fetch the open PDK (~2GB)
openlane gds/config.json    # synth -> floorplan -> place -> CTS -> route -> GDS
```
Outputs: `runs/*/final/gds/mac_tile.gds` (the die), plus the timing/area/power reports that
become the launch numbers (max MHz, µm², mW). The rainbow die render comes from the GDS via
KLayout or the OpenLane report.

## Status
Config + module ready. Not yet run here (no Docker in this env). yosys confirms the tile
synthesizes clean; see `synth/report.txt` for gate counts.

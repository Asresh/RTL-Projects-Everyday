# =============================================================================
# Day22 - Parameterized Parallel CRC-32 (Ethernet FCS) engine
# Run targets for the common simulators. Default: icarus.
# =============================================================================

TOP     := tb_crc32_parallel
RTL     := crc32_parallel.sv
TB      := tb_crc32_parallel.sv
SRCS    := $(RTL) $(TB)
VCD     := crc32_parallel.vcd

.PHONY: all icarus verilator vcs questa wave clean

all: icarus

# ---- Icarus Verilog -------------------------------------------------------
icarus:
	iverilog -g2012 -o sim_$(TOP).vvp $(SRCS)
	vvp sim_$(TOP).vvp

# ---- Verilator (lint + sim) ----------------------------------------------
verilator:
	verilator --binary --timing -Wall -Wno-fatal --top-module $(TOP) $(SRCS) -o sim_$(TOP)
	obj_dir/sim_$(TOP)

# ---- Synopsys VCS ---------------------------------------------------------
vcs:
	vcs -full64 -sverilog -timescale=1ns/1ps $(SRCS) -o simv_$(TOP)
	./simv_$(TOP)

# ---- Siemens Questa -------------------------------------------------------
questa:
	vlib work
	vlog -sv $(SRCS)
	vsim -c $(TOP) -do "run -all; quit"

# ---- View waveform --------------------------------------------------------
wave: $(VCD)
	gtkwave $(VCD) &

clean:
	rm -rf sim_*.vvp simv_* obj_dir work transcript *.vcd vsim.wlf

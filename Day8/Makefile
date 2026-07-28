# ============================================================================
#  Day 8 - I2C Master  |  simulator run targets
#
#  Default (icarus):   make            # compile + run with Icarus Verilog
#  Others:             make vcs / make questa / make verilator
#  Waveform image:     make wave       # regenerate docs PNGs from the VCD
#  View VCD:           make waves      # open the dumped VCD in GTKWave
#  Clean:              make clean
# ============================================================================

TOP      := tb_i2c_master
RTL      := i2c_master.sv
TB       := tb_i2c_master.sv
SRCS     := $(RTL) $(TB)
VCD      := i2c_master.vcd

# ---- Icarus Verilog (default) ---------------------------------------------
.PHONY: all icarus
all: icarus
icarus:
	iverilog -g2012 -o sim_i2c $(SRCS)
	vvp sim_i2c

# ---- Synopsys VCS ----------------------------------------------------------
.PHONY: vcs
vcs:
	vcs -full64 -sverilog +v2k -debug_access+all -o simv $(SRCS)
	./simv

# ---- Mentor Questa / ModelSim ---------------------------------------------
.PHONY: questa
questa:
	vlib work
	vlog -sv $(SRCS)
	vsim -c -do "run -all; quit" $(TOP)

# ---- Verilator (lint + sim; note: TB uses procedural bus model) -----------
.PHONY: verilator
verilator:
	verilator --binary --timing -Wall -Wno-fatal --top-module $(TOP) $(SRCS) -o sim_i2c_vl
	./obj_dir/sim_i2c_vl

# ---- regenerate the waveform + block-diagram PNGs from the captured VCD ----
.PHONY: wave
wave: $(VCD)
	cd docs && cp ../$(VCD) . && python3 make_waveform.py && python3 make_block.py

$(VCD): $(SRCS)
	$(MAKE) icarus

# ---- open VCD in GTKWave ---------------------------------------------------
.PHONY: waves
waves: $(VCD)
	gtkwave $(VCD) &

# ---- cleanup ---------------------------------------------------------------
.PHONY: clean
clean:
	rm -rf sim_i2c simv csrc *.daidir obj_dir work transcript \
	       *.vcd *.wlf ucli.key vc_hdrs.h docs/*.vcd

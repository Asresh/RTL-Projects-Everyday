# Day 40 : RISC-V Sv32 MMU - fully-associative TLB + hardware page-table walker
# Self-checking testbench run targets for the common simulators.

DESIGN  := mmu_sv32
RTL     := $(DESIGN).sv
TB      := tb_$(DESIGN).sv
TOP     := tb_$(DESIGN)
VCD     := $(DESIGN).vcd

# TLB depth to elaborate the testbench with, and the randomisation seed.
ENTRIES ?= 8
SEED    ?= 1

.PHONY: all icarus verilator vcs questa sweep waves gen clean

# Default: Icarus Verilog (open-source, installed on most machines)
all: icarus

# ---- Icarus Verilog -------------------------------------------------------
icarus:
	iverilog -g2012 -P $(TOP).TLB_ENTRIES=$(ENTRIES) \
	    -o $(DESIGN).vvp $(RTL) $(TB)
	vvp $(DESIGN).vvp +seed=$(SEED)

# ---- Verilator (lint + fast cycle sim) ------------------------------------
verilator:
	verilator --binary --timing -Wall -Wno-fatal \
	    --top-module $(TOP) $(RTL) $(TB) -o $(DESIGN)_vsim
	./obj_dir/$(DESIGN)_vsim

# ---- Synopsys VCS ---------------------------------------------------------
vcs:
	vcs -full64 -sverilog -debug_access+all -o $(DESIGN)_simv $(RTL) $(TB)
	./$(DESIGN)_simv

# ---- Cadence Xcelium / Mentor Questa --------------------------------------
questa:
	qrun -64 -sv -access +rwc -top $(TOP) $(RTL) $(TB)

# ---- regression: sweep TLB depths and seeds -------------------------------
sweep:
	@for n in 2 4 8 16 32; do \
	  for s in 1 7 42 1234 99991; do \
	    iverilog -g2012 -P $(TOP).TLB_ENTRIES=$$n -o sweep.vvp $(RTL) $(TB); \
	    printf "TLB_ENTRIES=%-3s seed=%-6s -> " $$n $$s; \
	    vvp sweep.vvp +seed=$$s | grep RESULT; \
	  done; \
	done; rm -f sweep.vvp

# ---- regenerate the figures from the VCD / model --------------------------
gen: $(VCD)
	python3 gen_waveform.py
	python3 gen_block.py

$(VCD): icarus

# ---- open the waveform ----------------------------------------------------
waves: $(VCD)
	gtkwave $(VCD) &

clean:
	rm -rf $(DESIGN).vvp $(DESIGN)_simv $(DESIGN)_vsim obj_dir sweep.vvp \
	       csrc *.daidir simv* ucli.key vc_hdrs.h $(VCD) *.fst probe.*

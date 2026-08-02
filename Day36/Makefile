# Day 36 : Hard-Decision Viterbi Decoder (rate-1/2, K=3, (7,5) code)
# Self-checking testbench run targets for the common simulators.

DESIGN  := viterbi_decoder
RTL     := $(DESIGN).sv
TB      := tb_$(DESIGN).sv
TOP     := tb_$(DESIGN)
VCD     := $(DESIGN).vcd

.PHONY: all icarus verilator vcs questa waves gen clean

# Default: Icarus Verilog (open-source, installed on most machines)
all: icarus

# ---- Icarus Verilog -------------------------------------------------------
icarus:
	iverilog -g2012 -o $(DESIGN).vvp $(RTL) $(TB)
	vvp $(DESIGN).vvp

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

# ---- regenerate the figures from the VCD / model --------------------------
gen: $(VCD)
	python3 gen_waveform.py
	python3 gen_block.py

# ---- open the waveform ----------------------------------------------------
waves: $(VCD)
	gtkwave $(VCD) &

clean:
	rm -rf $(DESIGN).vvp $(DESIGN)_simv $(DESIGN)_vsim obj_dir \
	       csrc *.daidir simv* ucli.key vc_hdrs.h $(VCD) *.fst probe.*

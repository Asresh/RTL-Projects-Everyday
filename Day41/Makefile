# Day 41 : Out-of-order Tomasulo engine - rename + reservation stations + ROB
# Self-checking testbench run targets for the common simulators.

DESIGN  := ooo_tomasulo
RTL     := $(DESIGN).sv
TB      := tb_$(DESIGN).sv
TOP     := tb_$(DESIGN)
VCD     := $(DESIGN).vcd

# Machine size to elaborate the testbench with, and the randomisation seed.
ROB     ?= 8
RS      ?= 6
MUL     ?= 3
NRAND   ?= 400
SEED    ?= 1

PARAMS  := -P $(TOP).ROB_DEPTH=$(ROB) -P $(TOP).RS_DEPTH=$(RS) \
           -P $(TOP).MUL_STAGES=$(MUL) -P $(TOP).NRAND=$(NRAND)

.PHONY: all icarus verilator vcs questa sweep seeds waves gen clean

# Default: Icarus Verilog (open-source, installed on most machines)
all: icarus

# ---- Icarus Verilog -------------------------------------------------------
icarus:
	iverilog -g2012 $(PARAMS) -o $(DESIGN).vvp $(RTL) $(TB)
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

# ---- regression: sweep the machine geometry -------------------------------
sweep:
	@for r in 4 8 16; do \
	  for s in 2 4 6 10; do \
	    for m in 1 3 5; do \
	      iverilog -g2012 -P $(TOP).ROB_DEPTH=$$r -P $(TOP).RS_DEPTH=$$s \
	          -P $(TOP).MUL_STAGES=$$m -P $(TOP).NRAND=120 \
	          -o sweep.vvp $(RTL) $(TB); \
	      printf "ROB=%-3s RS=%-3s MUL_STAGES=%-2s -> " $$r $$s $$m; \
	      vvp sweep.vvp +seed=7 | grep RESULT; \
	    done; \
	  done; \
	done; rm -f sweep.vvp

# ---- regression: sweep seeds at the default geometry ----------------------
seeds:
	@iverilog -g2012 $(PARAMS) -o seeds.vvp $(RTL) $(TB); \
	for s in 1 7 42 1234 99991 2026 31337; do \
	  printf "seed=%-8s -> " $$s; \
	  vvp seeds.vvp +seed=$$s | grep RESULT; \
	done; rm -f seeds.vvp

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
	       seeds.vvp csrc *.daidir simv* ucli.key vc_hdrs.h $(VCD) *.fst probe.*

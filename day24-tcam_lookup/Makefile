# Makefile for Day 24 — tcam (Pipelined Ternary CAM lookup engine)
# Pick whichever simulator you have installed.

SRC = tcam.sv tb_tcam.sv
TOP = tb_tcam

# ---- Verilator (open source) --------------------------------------------
verilator:
	verilator --binary --timing -Wno-fatal --top-module $(TOP) $(SRC) -o simv
	./obj_dir/simv

# ---- Synopsys VCS ---------------------------------------------------------
vcs:
	vcs -full64 -sverilog -debug_access+all $(SRC) -o simv
	./simv

# ---- Siemens Questa / ModelSim -------------------------------------------
questa:
	vlib work
	vlog -sv $(SRC)
	vsim -c $(TOP) -do "run -all; quit"

# ---- Icarus Verilog (open source) ----------------------------------------
icarus:
	iverilog -g2012 -o simv.vvp $(SRC)
	vvp simv.vvp

# ---- regenerate the docs images from a fresh simulation ------------------
waveform: icarus
	cd docs && python3 render_waveform.py ../tcam.vcd tcam_waveform.png
	cd docs && python3 render_block_diagram.py

clean:
	rm -rf obj_dir work simv simv.vvp *.vcd csrc *.daidir ucli.key transcript

.PHONY: verilator vcs questa icarus waveform clean

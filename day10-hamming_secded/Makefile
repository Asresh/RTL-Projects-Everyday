# Makefile for Day 10 — hamming_secded (SECDED Hamming ECC codec)
# Pick whichever simulator you have installed.

SRC = hamming_secded.sv tb_hamming_secded.sv
TOP = tb_hamming_secded

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
	iverilog -g2012 -Wall -o simv.vvp $(SRC)
	vvp simv.vvp

clean:
	rm -rf obj_dir work simv simv.vvp *.vcd csrc *.daidir ucli.key transcript

.PHONY: verilator vcs questa icarus clean

# Day 21 -- 2:4 Structured-Sparsity Dot-Product Engine
SRC = sparse_dot2of4.sv tb_sparse_dot2of4.sv
TOP = tb_sparse_dot2of4

verilator:
	verilator --binary --timing -Wno-fatal --top-module $(TOP) $(SRC) -o simv
	./obj_dir/simv

vcs:
	vcs -full64 -sverilog -debug_access+all $(SRC) -o simv
	./simv

questa:
	vlib work
	vlog -sv $(SRC)
	vsim -c $(TOP) -do "run -all; quit"

icarus:
	iverilog -g2012 -Wall -o simv.vvp $(SRC)
	vvp simv.vvp

clean:
	rm -rf obj_dir work simv simv.vvp *.vcd csrc *.daidir ucli.key transcript

.PHONY: verilator vcs questa icarus clean

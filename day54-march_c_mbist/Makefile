# Author: Asresh Kuricheti
DESIGN := march_c_mbist
TB := tb_march_c_mbist

.PHONY: all icarus verilator vcs questa clean
all: icarus

icarus:
	iverilog -g2012 -Wall -s $(TB) -o simv $(DESIGN).sv $(TB).sv
	vvp simv

verilator:
	verilator --binary --timing --trace --top-module $(TB) -Wall -Wno-fatal $(DESIGN).sv $(TB).sv
	./obj_dir/V$(TB)

vcs:
	vcs -full64 -sverilog -debug_access+all $(DESIGN).sv $(TB).sv -o simv
	./simv

questa:
	vlib work
	vlog -sv $(DESIGN).sv $(TB).sv
	vsim -c $(TB) -do "run -all; quit -f"

clean:
	rm -rf simv simv.daidir csrc obj_dir work transcript vsim.wlf *.vcd ucli.key

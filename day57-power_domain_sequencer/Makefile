# Author: Asresh Kuricheti
DESIGN := power_domain_sequencer
TB     := tb_power_domain_sequencer

.PHONY: all icarus verilator vcs questa clean

all: icarus

icarus:
	iverilog -g2012 -Wall -s $(TB) -o simv $(DESIGN).sv $(TB).sv
	vvp simv

verilator:
	verilator --binary --timing --trace --Wall -Wno-fatal --top-module $(TB) $(DESIGN).sv $(TB).sv
	./obj_dir/V$(TB)

vcs:
	vcs -full64 -sverilog -debug_access+all $(DESIGN).sv $(TB).sv -o simv
	./simv

questa:
	vlib work
	vlog -sv $(DESIGN).sv $(TB).sv
	vsim -c $(TB) -do "run -all; quit -f"

clean:
	rm -rf simv simv.daidir csrc obj_dir work transcript vsim.wlf *.vcd timing.csv ucli.key

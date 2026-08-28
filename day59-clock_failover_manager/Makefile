# Author: Asresh Kuricheti
DESIGN=clock_failover_manager
TB=tb_clock_failover_manager
.PHONY: icarus verilator vcs questa clean
icarus:
	iverilog -g2012 -Wall -s $(TB) -o simv $(DESIGN).sv $(TB).sv
	vvp simv
verilator:
	verilator --binary --timing --trace -Wall -Wno-fatal --top-module $(TB) $(DESIGN).sv $(TB).sv
	./obj_dir/V$(TB)
vcs:
	vcs -sverilog -full64 -debug_access+all $(DESIGN).sv $(TB).sv -o simv
	./simv
questa:
	vlib work
	vlog -sv $(DESIGN).sv $(TB).sv
	vsim -c $(TB) -do "run -all; quit -f"
clean:
	rm -rf simv simv.daidir csrc ucli.key obj_dir work transcript vsim.wlf *.vcd

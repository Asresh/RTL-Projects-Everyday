# Author: Asresh Kuricheti

DESIGN := pcie_credit_scheduler
TB := tb_pcie_credit_scheduler

.PHONY: all icarus verilator vcs questa clean

all: icarus

icarus:
	iverilog -g2012 -Wall -s $(TB) -o simv_icarus $(DESIGN).sv $(TB).sv
	vvp simv_icarus

verilator:
	verilator --binary --timing --trace -Wall -Wno-fatal --top-module $(TB) $(DESIGN).sv $(TB).sv
	./obj_dir/V$(TB)

vcs:
	vcs -sverilog -full64 -debug_access+all -top $(TB) $(DESIGN).sv $(TB).sv -o simv_vcs
	./simv_vcs

questa:
	vlib work
	vlog -sv $(DESIGN).sv $(TB).sv
	vsim -c $(TB) -do "run -all; quit -f"

clean:
	$(RM) simv_icarus simv_vcs pcie_credit_scheduler.vcd
	$(RM) -r simv_vcs.daidir csrc ucli.key obj_dir work transcript vsim.wlf

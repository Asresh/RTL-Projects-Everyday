# Author: Asresh Kuricheti
DESIGN := ddr_read_eye_trainer
TB := tb_$(DESIGN)

.PHONY: all icarus verilator vcs questa clean
all: icarus

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
	rm -rf simv simv.daidir csrc ucli.key vc_hdrs.h DVEfiles inter.vpd \
		work transcript vsim.wlf obj_dir *.vcd

# Author: Asresh Kuricheti

TOP := tb_serdes_deskew_buffer
RTL := serdes_deskew_buffer.sv
TB  := tb_serdes_deskew_buffer.sv

.PHONY: all icarus verilator vcs questa clean

all: icarus

icarus:
	iverilog -g2012 -Wall -s $(TOP) -o simv_icarus $(RTL) $(TB)
	vvp simv_icarus

verilator:
	verilator --binary --timing --trace -Wall -Wno-fatal --top-module $(TOP) $(RTL) $(TB)
	./obj_dir/V$(TOP)

vcs:
	vcs -sverilog -full64 -debug_access+all -top $(TOP) $(RTL) $(TB) -o simv_vcs
	./simv_vcs

questa:
	vlib work
	vlog -sv $(RTL) $(TB)
	vsim -c $(TOP) -do "run -all; quit -f"

clean:
	$(RM) simv_icarus simv_vcs simv_vcs.daidir serdes_deskew_buffer.vcd
	$(RM) -r obj_dir work transcript vsim.wlf csrc ucli.key

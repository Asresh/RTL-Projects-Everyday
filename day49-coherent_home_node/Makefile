# Author: Asresh Kuricheti
DESIGN := coherent_home_node
RTL    := $(DESIGN).sv
TB     := tb_$(DESIGN).sv
TOP    := tb_$(DESIGN)

.PHONY: all icarus verilator vcs questa lint clean

all: icarus

icarus:
	iverilog -g2012 -Wall -s $(TOP) -o $(DESIGN).vvp $(RTL) $(TB)
	vvp $(DESIGN).vvp

verilator:
	verilator --binary --timing -Wall -Wno-fatal --top-module $(TOP) \
		$(RTL) $(TB) -o $(DESIGN)_vsim
	./obj_dir/$(DESIGN)_vsim

vcs:
	vcs -full64 -sverilog -debug_access+all -top $(TOP) \
		-o $(DESIGN)_simv $(RTL) $(TB)
	./$(DESIGN)_simv

questa:
	vlog -sv $(RTL) $(TB)
	vsim -c $(TOP) -do "run -all; quit -f"

lint:
	verilator --lint-only --timing -Wall -Wno-fatal --top-module $(TOP) $(RTL) $(TB)

clean:
	rm -rf $(DESIGN).vvp $(DESIGN)_simv $(DESIGN)_simv.daidir obj_dir \
		csrc simv* ucli.key vc_hdrs.h transcript work *.wlf *.vcd

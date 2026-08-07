DESIGN := noc_vc_router
RTL    := $(DESIGN).sv
TB     := tb_$(DESIGN).sv
TOP    := tb_$(DESIGN)

.PHONY: all icarus verilator vcs questa lint seeds waves figures clean

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

seeds:
	iverilog -g2012 -Wall -s $(TOP) -o $(DESIGN).vvp $(RTL) $(TB)
	@for seed in 1 7 42 2026 31337 99991; do \
		vvp $(DESIGN).vvp +seed=$$seed | grep RESULT; \
	done

waves: $(DESIGN).vcd
	gtkwave $(DESIGN).vcd

figures: $(DESIGN).vcd
	python3 gen_figures.py

$(DESIGN).vcd: icarus

clean:
	rm -rf $(DESIGN).vvp $(DESIGN)_simv $(DESIGN)_simv.daidir obj_dir \
		csrc simv* ucli.key vc_hdrs.h transcript work *.wlf *.vcd

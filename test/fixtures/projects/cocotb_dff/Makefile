# Minimal Cocotb-style Makefile for the SimCrux Cocotb fixture.
#
# SimCrux's CocotbDriver invokes:
#   make SIM=<sim> TOPLEVEL=dff [TOPLEVEL_LANG=verilog] [MODULE=test_dff]
# from inside the per-test working directory the scheduler allocates.
#
# To run this fixture by hand:
#   cd test/fixtures/projects/cocotb_dff
#   make SIM=icarus
SIM            ?= icarus
TOPLEVEL_LANG  ?= verilog
TOPLEVEL       ?= dff
# Cocotb 2.x renamed MODULE to COCOTB_TEST_MODULES and warns when only the old
# name is set. Setting both to the same value silences that (its `deprecate`
# helper takes the new one without complaint when they match) while staying
# readable to Cocotb 1.x, which knows only MODULE.
MODULE             ?= test_dff
COCOTB_TEST_MODULES ?= $(MODULE)
# $(CURDIR), not $(shell pwd): under native Windows `make` the shell is cmd.exe
# and `pwd` either does not exist or returns an MSYS path like /c/Users/... that
# make cannot resolve, so the build fails with "No rule to make target". CURDIR
# is make's own and is correct on every platform.
VERILOG_SOURCES = $(CURDIR)/dff.v

# Skip the deliberately-failing test by default so a contributor running
# this fixture by hand sees a green run; flip to 0 to verify SimCrux's
# fail classification.
COCOTB_SKIP_FAIL ?= 1
export COCOTB_SKIP_FAIL

include $(shell cocotb-config --makefiles)/Makefile.sim

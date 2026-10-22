# GNU make defines CXX=g++ internally. On this macOS development host that name
# is Apple Clang without OpenMP, while Homebrew LLVM is available. Explicit
# command-line or environment CXX values always take precedence.
ifeq ($(origin CXX), default)
ifneq ($(wildcard /usr/local/opt/llvm/bin/clang++),)
CXX := /usr/local/opt/llvm/bin/clang++
else ifneq ($(wildcard /opt/homebrew/opt/llvm/bin/clang++),)
CXX := /opt/homebrew/opt/llvm/bin/clang++
else
CXX := g++
endif
endif
CPPFLAGS ?=
CXXFLAGS ?= -O2 -Wall -Wextra -Wpedantic
OPENMP_FLAGS ?=
LDFLAGS ?=
PYTHON ?= python3

# These flags are part of the project contract. Keep them separate from the
# user-configurable flags above so command-line overrides cannot remove them.
override PROJECT_CPPFLAGS := -Iinclude
override PROJECT_CXXFLAGS := -std=c++17
override PROJECT_OPENMP_FLAGS := -fopenmp

BUILD_DIR := build
SOLVER := $(BUILD_DIR)/wave_solver
TEST_RUNNER := $(BUILD_DIR)/test_wave
COMMON_SOURCE := src/wave.cpp

.PHONY: all test clean

all: $(SOLVER)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(SOLVER): src/main.cpp $(COMMON_SOURCE) include/wave.hpp | $(BUILD_DIR)
	$(CXX) $(PROJECT_CPPFLAGS) $(CPPFLAGS) $(PROJECT_CXXFLAGS) $(CXXFLAGS) $(PROJECT_OPENMP_FLAGS) $(OPENMP_FLAGS) src/main.cpp $(COMMON_SOURCE) $(LDFLAGS) $(PROJECT_OPENMP_FLAGS) $(OPENMP_FLAGS) -o $@

$(TEST_RUNNER): tests/test_wave.cpp $(COMMON_SOURCE) include/wave.hpp | $(BUILD_DIR)
	$(CXX) $(PROJECT_CPPFLAGS) $(CPPFLAGS) $(PROJECT_CXXFLAGS) $(CXXFLAGS) $(PROJECT_OPENMP_FLAGS) $(OPENMP_FLAGS) tests/test_wave.cpp $(COMMON_SOURCE) $(LDFLAGS) $(PROJECT_OPENMP_FLAGS) $(OPENMP_FLAGS) -o $@

test: $(SOLVER) $(TEST_RUNNER)
	$(TEST_RUNNER)
	sh tests/test_cli.sh $(SOLVER)
	$(PYTHON) tests/test_full_v1_benchmark.py

clean:
	rm -f $(SOLVER) $(TEST_RUNNER)

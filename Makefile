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

BUILD_DIR ?= build
SOLVER := $(BUILD_DIR)/wave_solver
OPTIMIZED_SOLVER := $(BUILD_DIR)/wave_solver_opt
TEST_RUNNER := $(BUILD_DIR)/test_wave
OPTIMIZED_TEST_RUNNER := $(BUILD_DIR)/test_wave_opt
COMMON_SOURCE := src/wave.cpp
OPTIMIZED_SOURCE := src/wave_optimized.cpp

.PHONY: all optimized test test-optimized test-all clean

all: $(SOLVER)

optimized: $(OPTIMIZED_SOLVER)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(SOLVER): src/main.cpp $(COMMON_SOURCE) include/wave.hpp | $(BUILD_DIR)
	$(CXX) $(PROJECT_CPPFLAGS) $(CPPFLAGS) $(PROJECT_CXXFLAGS) $(CXXFLAGS) $(PROJECT_OPENMP_FLAGS) $(OPENMP_FLAGS) src/main.cpp $(COMMON_SOURCE) $(LDFLAGS) $(PROJECT_OPENMP_FLAGS) $(OPENMP_FLAGS) -o $@

$(OPTIMIZED_SOLVER): src/main_optimized.cpp $(OPTIMIZED_SOURCE) $(COMMON_SOURCE) include/wave_optimized.hpp include/wave.hpp | $(BUILD_DIR)
	$(CXX) $(PROJECT_CPPFLAGS) $(CPPFLAGS) $(PROJECT_CXXFLAGS) $(CXXFLAGS) $(PROJECT_OPENMP_FLAGS) $(OPENMP_FLAGS) src/main_optimized.cpp $(OPTIMIZED_SOURCE) $(COMMON_SOURCE) $(LDFLAGS) $(PROJECT_OPENMP_FLAGS) $(OPENMP_FLAGS) -o $@

$(TEST_RUNNER): tests/test_wave.cpp $(COMMON_SOURCE) include/wave.hpp | $(BUILD_DIR)
	$(CXX) $(PROJECT_CPPFLAGS) $(CPPFLAGS) $(PROJECT_CXXFLAGS) $(CXXFLAGS) $(PROJECT_OPENMP_FLAGS) $(OPENMP_FLAGS) tests/test_wave.cpp $(COMMON_SOURCE) $(LDFLAGS) $(PROJECT_OPENMP_FLAGS) $(OPENMP_FLAGS) -o $@

$(OPTIMIZED_TEST_RUNNER): tests/test_wave_optimized.cpp $(OPTIMIZED_SOURCE) $(COMMON_SOURCE) include/wave_optimized.hpp include/wave.hpp | $(BUILD_DIR)
	$(CXX) $(PROJECT_CPPFLAGS) $(CPPFLAGS) $(PROJECT_CXXFLAGS) $(CXXFLAGS) $(PROJECT_OPENMP_FLAGS) $(OPENMP_FLAGS) tests/test_wave_optimized.cpp $(OPTIMIZED_SOURCE) $(COMMON_SOURCE) $(LDFLAGS) $(PROJECT_OPENMP_FLAGS) $(OPENMP_FLAGS) -o $@

test: $(SOLVER) $(TEST_RUNNER)
	$(TEST_RUNNER)
	sh tests/test_cli.sh $(SOLVER)
	$(PYTHON) tests/test_full_v1_benchmark.py

test-optimized: $(SOLVER) $(OPTIMIZED_SOLVER) $(OPTIMIZED_TEST_RUNNER)
	$(OPTIMIZED_TEST_RUNNER)
	sh tests/test_cli.sh $(OPTIMIZED_SOLVER)
	$(PYTHON) tests/test_optimized_equivalence.py $(SOLVER) $(OPTIMIZED_SOLVER)

test-all: test test-optimized

clean:
	rm -f $(SOLVER) $(OPTIMIZED_SOLVER) $(TEST_RUNNER) $(OPTIMIZED_TEST_RUNNER)

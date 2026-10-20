#ifndef WAVE_HPP
#define WAVE_HPP

#include <cstddef>
#include <string>
#include <vector>

namespace wave {

struct Config {
    std::size_t n = 0;
    double lx = 0.0;
    double ly = 0.0;
    double lz = 0.0;
    double final_time = 0.0;
    std::size_t steps = 0;
    int threads = 0;
};

struct Grid {
    std::size_t side = 0;
    std::size_t node_count = 0;
    double hx = 0.0;
    double hy = 0.0;
    double hz = 0.0;
};

struct Result {
    Grid grid;
    std::vector<double> final_layer;
    double elapsed_seconds = 0.0;
    int effective_threads = 0;
};

// Returns an empty string when the configuration is valid.
std::string validate_config(const Config& config);
Grid make_grid(const Config& config);
double exact_solution(double x, double y, double z, double time,
                      const Config& config);
Result solve(const Config& config);
double max_absolute_error(const Result& result, const Config& config);
std::size_t index(const Grid& grid, std::size_t i, std::size_t j,
                  std::size_t k);

}  // namespace wave

#endif

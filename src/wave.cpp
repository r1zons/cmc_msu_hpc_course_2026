#include "wave.hpp"

#include <algorithm>
#include <cmath>
#include <iomanip>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <utility>

#include <omp.h>

namespace wave {
namespace {

constexpr double pi = 3.141592653589793238462643383279502884;

bool multiply_overflows(std::size_t a, std::size_t b) {
    return a != 0 && b > std::numeric_limits<std::size_t>::max() / a;
}

double laplacian(const std::vector<double>& layer, const Grid& grid,
                 std::size_t i, std::size_t j, std::size_t k) {
    const std::size_t p = index(grid, i, j, k);
    const std::size_t stride_i = grid.side * grid.side;
    const std::size_t stride_j = grid.side;
    const double center = layer[p];
    return (layer[p - stride_i] - 2.0 * center + layer[p + stride_i]) /
               (grid.hx * grid.hx) +
           (layer[p - stride_j] - 2.0 * center + layer[p + stride_j]) /
               (grid.hy * grid.hy) +
           (layer[p - 1] - 2.0 * center + layer[p + 1]) /
               (grid.hz * grid.hz);
}

}  // namespace

std::string validate_config(const Config& config) {
    if (config.n < 2) {
        return "N must be at least 2";
    }
    if (config.steps < 1) {
        return "the number of time steps must be at least 1";
    }
    if (config.threads < 1) {
        return "the number of OpenMP threads must be at least 1";
    }
    if (!std::isfinite(config.lx) || config.lx <= 0.0 ||
        !std::isfinite(config.ly) || config.ly <= 0.0 ||
        !std::isfinite(config.lz) || config.lz <= 0.0) {
        return "all domain lengths must be positive and finite";
    }
    if (!std::isfinite(config.final_time) || config.final_time <= 0.0) {
        return "physical final time must be positive and finite";
    }

    if (config.n == std::numeric_limits<std::size_t>::max()) {
        return "N is too large";
    }
    const std::size_t side = config.n + 1;
    if (multiply_overflows(side, side) ||
        multiply_overflows(side * side, side)) {
        return "grid node count overflows size_t";
    }
    const std::size_t nodes = side * side * side;
    if (multiply_overflows(nodes, sizeof(double)) ||
        multiply_overflows(nodes * sizeof(double), 3)) {
        return "storage size for three layers overflows size_t";
    }

    const double hx = config.lx / static_cast<double>(config.n);
    const double hy = config.ly / static_cast<double>(config.n);
    const double hz = config.lz / static_cast<double>(config.n);
    const double tau = config.final_time / static_cast<double>(config.steps);
    if (hx == 0.0 || hy == 0.0 || hz == 0.0 || tau == 0.0) {
        return "grid spacing or time step underflows to zero";
    }
    const double cfl = tau * tau *
                       (1.0 / (hx * hx) + 1.0 / (hy * hy) +
                        1.0 / (hz * hz));
    if (!std::isfinite(cfl)) {
        return "CFL expression is not finite";
    }
    const double tolerance = 64.0 * std::numeric_limits<double>::epsilon();
    if (cfl > 1.0 + tolerance) {
        std::ostringstream message;
        message << "CFL stability condition violated: tau^2 * (1/hx^2 + "
                   "1/hy^2 + 1/hz^2) = "
                << std::setprecision(std::numeric_limits<double>::max_digits10)
                << cfl << " > 1";
        return message.str();
    }
    return {};
}

Grid make_grid(const Config& config) {
    const std::string error = validate_config(config);
    if (!error.empty()) {
        throw std::invalid_argument(error);
    }
    const std::size_t side = config.n + 1;
    return {side,
            side * side * side,
            config.lx / static_cast<double>(config.n),
            config.ly / static_cast<double>(config.n),
            config.lz / static_cast<double>(config.n)};
}

std::size_t index(const Grid& grid, std::size_t i, std::size_t j,
                  std::size_t k) {
    return (i * grid.side + j) * grid.side + k;
}

double exact_solution(double x, double y, double z, double time,
                      const Config& config) {
    const double frequency =
        pi * std::sqrt(1.0 / (config.lx * config.lx) +
                       1.0 / (config.ly * config.ly) +
                       1.0 / (config.lz * config.lz));
    return std::sin(pi * x / config.lx) * std::sin(pi * y / config.ly) *
           std::sin(pi * z / config.lz) * std::cos(frequency * time);
}

Result solve(const Config& config) {
    const Grid grid = make_grid(config);
    std::vector<double> previous(grid.node_count, 0.0);
    std::vector<double> current(grid.node_count, 0.0);
    std::vector<double> next(grid.node_count, 0.0);

    // Only interior nodes are initialized; all six faces stay exactly zero.
#pragma omp parallel for collapse(3) schedule(static) num_threads(config.threads)
    for (std::size_t i = 1; i < config.n; ++i) {
        for (std::size_t j = 1; j < config.n; ++j) {
            for (std::size_t k = 1; k < config.n; ++k) {
                const double x = static_cast<double>(i) * grid.hx;
                const double y = static_cast<double>(j) * grid.hy;
                const double z = static_cast<double>(k) * grid.hz;
                previous[index(grid, i, j, k)] =
                    std::sin(pi * x / config.lx) *
                    std::sin(pi * y / config.ly) *
                    std::sin(pi * z / config.lz);
            }
        }
    }

    int effective_threads = 1;
#pragma omp parallel num_threads(config.threads)
    {
#pragma omp single
        effective_threads = omp_get_num_threads();
    }

    const double tau = config.final_time / static_cast<double>(config.steps);
    const double tau_squared = tau * tau;
    const double start = omp_get_wtime();

#pragma omp parallel for collapse(3) schedule(static) num_threads(config.threads)
    for (std::size_t i = 1; i < config.n; ++i) {
        for (std::size_t j = 1; j < config.n; ++j) {
            for (std::size_t k = 1; k < config.n; ++k) {
                const std::size_t p = index(grid, i, j, k);
                current[p] = previous[p] +
                             0.5 * tau_squared *
                                 laplacian(previous, grid, i, j, k);
            }
        }
    }

    for (std::size_t time_step = 1; time_step < config.steps; ++time_step) {
#pragma omp parallel for collapse(3) schedule(static) num_threads(config.threads)
        for (std::size_t i = 1; i < config.n; ++i) {
            for (std::size_t j = 1; j < config.n; ++j) {
                for (std::size_t k = 1; k < config.n; ++k) {
                    const std::size_t p = index(grid, i, j, k);
                    next[p] = 2.0 * current[p] - previous[p] +
                              tau_squared *
                                  laplacian(current, grid, i, j, k);
                }
            }
        }
        previous.swap(current);
        current.swap(next);
    }

    const double elapsed = omp_get_wtime() - start;
    return {grid, std::move(current), elapsed, effective_threads};
}

double max_absolute_error(const Result& result, const Config& config) {
    double maximum = 0.0;
#pragma omp parallel for collapse(3) reduction(max : maximum) schedule(static) \
    num_threads(config.threads)
    for (std::size_t i = 0; i <= config.n; ++i) {
        for (std::size_t j = 0; j <= config.n; ++j) {
            for (std::size_t k = 0; k <= config.n; ++k) {
                const double x = static_cast<double>(i) * result.grid.hx;
                const double y = static_cast<double>(j) * result.grid.hy;
                const double z = static_cast<double>(k) * result.grid.hz;
                const double error =
                    std::abs(result.final_layer[index(result.grid, i, j, k)] -
                             exact_solution(x, y, z, config.final_time, config));
                maximum = std::max(maximum, error);
            }
        }
    }
    return maximum;
}

}  // namespace wave

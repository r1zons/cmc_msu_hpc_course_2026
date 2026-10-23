#include "wave_optimized.hpp"

#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>

namespace {

constexpr double pi = 3.141592653589793238462643383279502884;

void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

std::size_t at(std::size_t n, std::size_t i, std::size_t j, std::size_t k) {
    const std::size_t side = n + 1;
    return (i * side + j) * side + k;
}

void test_first_layer_and_boundaries() {
    const wave::Config config{2, 1.0, 1.0, 1.0, 0.01, 1, 2};
    const wave_opt::Result result = wave_opt::solve(config);
    require(std::abs(result.final_layer[at(2, 1, 1, 1)] - 0.9988) < 1.0e-14,
            "optimized K=1 hand check failed");
    for (std::size_t p = 0; p < result.final_layer.size(); ++p) {
        if (p != at(2, 1, 1, 1)) {
            require(result.final_layer[p] == 0.0,
                    "optimized boundary is nonzero");
        }
    }
}

void test_discrete_mode() {
    const wave::Config config{9, 1.0, 1.4, 1.8, 0.08, 7, 4};
    const wave_opt::Result result = wave_opt::solve(config);
    const double tau = config.final_time / config.steps;
    const double sine = std::sin(pi / (2.0 * config.n));
    const double eigenvalue =
        -4.0 * sine * sine *
        (1.0 / (result.grid.hx * result.grid.hx) +
         1.0 / (result.grid.hy * result.grid.hy) +
         1.0 / (result.grid.hz * result.grid.hz));
    double previous = 1.0;
    double current = 1.0 + 0.5 * tau * tau * eigenvalue;
    for (std::size_t step = 1; step < config.steps; ++step) {
        const double next = 2.0 * current - previous +
                            tau * tau * eigenvalue * current;
        previous = current;
        current = next;
    }
    double difference = 0.0;
    for (std::size_t i = 1; i < config.n; ++i) {
        for (std::size_t j = 1; j < config.n; ++j) {
            for (std::size_t k = 1; k < config.n; ++k) {
                const double mode =
                    std::sin(pi * i / config.n) *
                    std::sin(pi * j / config.n) *
                    std::sin(pi * k / config.n);
                difference = std::max(
                    difference,
                    std::abs(result.final_layer[at(config.n, i, j, k)] -
                             current * mode));
            }
        }
    }
    require(difference < 256.0 * std::numeric_limits<double>::epsilon(),
            "optimized kernel disagrees with the discrete mode recurrence");
}

void test_threads_are_deterministic() {
    wave::Config one{17, 1.0, 1.1, 1.3, 0.05, 8, 1};
    wave::Config four = one;
    four.threads = 4;
    const wave_opt::Result a = wave_opt::solve(one);
    const wave_opt::Result b = wave_opt::solve(four);
    require(a.final_layer.size() == b.final_layer.size(), "layer size changed");
    for (std::size_t p = 0; p < a.final_layer.size(); ++p) {
        require(a.final_layer[p] == b.final_layer[p],
                "optimized results differ across thread counts");
    }
}

}  // namespace

int main() {
    try {
        test_first_layer_and_boundaries();
        test_discrete_mode();
        test_threads_are_deterministic();
        std::cout << "All optimized numerical tests passed.\n";
    } catch (const std::exception& error) {
        std::cerr << "Test failure: " << error.what() << '\n';
        return 1;
    }
    return 0;
}

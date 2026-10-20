#include "wave.hpp"

#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>

namespace {

constexpr double pi = 3.141592653589793238462643383279502884;

void require(bool condition, const std::string& message) {
    if (!condition) {
        throw std::runtime_error(message);
    }
}

std::size_t test_index(std::size_t n, std::size_t i, std::size_t j,
                       std::size_t k) {
    const std::size_t side = n + 1;
    return (i * side + j) * side + k;
}

void test_first_layer_hand_check() {
    const wave::Config config{2, 1.0, 1.0, 1.0, 0.01, 1, 1};
    const wave::Result result = wave::solve(config);
    const double center = result.final_layer[test_index(config.n, 1, 1, 1)];
    require(std::abs(center - 0.9988) < 1.0e-14,
            "N=2 first-layer center value is not 0.9988");
}

void test_boundaries_are_zero() {
    const wave::Config config{7, 1.0, 1.2, 0.8, 0.02, 3, 2};
    const wave::Result result = wave::solve(config);
    for (std::size_t i = 0; i <= config.n; ++i) {
        for (std::size_t j = 0; j <= config.n; ++j) {
            for (std::size_t k = 0; k <= config.n; ++k) {
                if (i == 0 || i == config.n || j == 0 || j == config.n ||
                    k == 0 || k == config.n) {
                    require(result.final_layer[test_index(config.n, i, j, k)] ==
                                0.0,
                            "a boundary node is nonzero");
                }
            }
        }
    }
}

void test_thread_consistency() {
    wave::Config one_thread{9, 1.0, 1.1, 1.3, 0.1, 8, 1};
    wave::Config four_threads = one_thread;
    four_threads.threads = 4;
    const wave::Result sequential = wave::solve(one_thread);
    const wave::Result parallel = wave::solve(four_threads);
    require(sequential.final_layer == parallel.final_layer,
            "one-thread and four-thread layers differ");
}

void test_discrete_mode_recurrence() {
    const wave::Config config{6, 1.0, 1.4, 1.8, 0.08, 5, 2};
    const wave::Result result = wave::solve(config);
    const double tau = config.final_time / static_cast<double>(config.steps);
    const double angle = pi / (2.0 * static_cast<double>(config.n));
    const double sine_squared = std::sin(angle) * std::sin(angle);
    const double eigenvalue =
        -4.0 * sine_squared *
        (1.0 / (result.grid.hx * result.grid.hx) +
         1.0 / (result.grid.hy * result.grid.hy) +
         1.0 / (result.grid.hz * result.grid.hz));

    double previous_amplitude = 1.0;
    double current_amplitude = 1.0 + 0.5 * tau * tau * eigenvalue;
    for (std::size_t step = 1; step < config.steps; ++step) {
        const double next_amplitude =
            2.0 * current_amplitude - previous_amplitude +
            tau * tau * eigenvalue * current_amplitude;
        previous_amplitude = current_amplitude;
        current_amplitude = next_amplitude;
    }

    double largest_difference = 0.0;
    for (std::size_t i = 1; i < config.n; ++i) {
        for (std::size_t j = 1; j < config.n; ++j) {
            for (std::size_t k = 1; k < config.n; ++k) {
                const double mode =
                    std::sin(pi * static_cast<double>(i) / config.n) *
                    std::sin(pi * static_cast<double>(j) / config.n) *
                    std::sin(pi * static_cast<double>(k) / config.n);
                const double expected = current_amplitude * mode;
                const double actual =
                    result.final_layer[test_index(config.n, i, j, k)];
                largest_difference =
                    std::max(largest_difference, std::abs(actual - expected));
            }
        }
    }
    require(largest_difference < 64.0 * std::numeric_limits<double>::epsilon(),
            "multi-step result disagrees with the discrete mode recurrence");
}

void test_noncubic_valid_run() {
    const wave::Config config{8, 1.0, 1.5, 2.0, 0.1, 8, 3};
    const wave::Result result = wave::solve(config);
    const double error = wave::max_absolute_error(result, config);
    require(std::isfinite(error), "noncubic run has non-finite error");
    require(std::isfinite(result.elapsed_seconds) && result.elapsed_seconds >= 0.0,
            "elapsed time is invalid");
    require(result.effective_threads >= 1 && result.effective_threads <= 3,
            "effective thread count is invalid");
}

void test_validation() {
    require(!wave::validate_config({1, 1.0, 1.0, 1.0, 0.1, 2, 1}).empty(),
            "N=1 was accepted");
    require(!wave::validate_config({2, 1.0, 1.0, 1.0, 0.1, 0, 1}).empty(),
            "K=0 was accepted");
    require(!wave::validate_config({2, 1.0, 1.0, 1.0, 0.1, 2, 0}).empty(),
            "zero threads were accepted");
    require(!wave::validate_config({2, -1.0, 1.0, 1.0, 0.1, 2, 1}).empty(),
            "negative length was accepted");
    require(!wave::validate_config({10, 1.0, 1.0, 1.0, 1.0, 1, 1}).empty(),
            "unstable configuration was accepted");
}

}  // namespace

int main() {
    try {
        test_first_layer_hand_check();
        test_boundaries_are_zero();
        test_thread_consistency();
        test_discrete_mode_recurrence();
        test_noncubic_valid_run();
        test_validation();
        std::cout << "All numerical tests passed.\n";
    } catch (const std::exception& error) {
        std::cerr << "Test failure: " << error.what() << '\n';
        return 1;
    }
    return 0;
}

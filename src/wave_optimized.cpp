#include "wave_optimized.hpp"

#include <algorithm>
#include <cmath>
#include <new>
#include <utility>

#include <omp.h>

namespace wave_opt {
namespace {

constexpr std::size_t layer_alignment = 64;
constexpr double pi = 3.141592653589793238462643383279502884;

}  // namespace

AlignedLayer::AlignedLayer(std::size_t size)
    : size_(size),
      data_(static_cast<double*>(::operator new[](
          size * sizeof(double), std::align_val_t{layer_alignment}))) {}

void AlignedLayer::AlignedDelete::operator()(double* pointer) const noexcept {
    ::operator delete[](pointer, std::align_val_t{layer_alignment});
}

Result solve(const wave::Config& config) {
    const wave::Grid grid = wave::make_grid(config);
    AlignedLayer layer_a(grid.node_count);
    AlignedLayer layer_b(grid.node_count);
    AlignedLayer layer_c(grid.node_count);

    double* previous = layer_a.data();
    double* current = layer_b.data();
    double* next = layer_c.data();

    const std::size_t side = grid.side;
    const std::size_t stride_i = side * side;
    const std::size_t stride_j = side;
    const double tau = config.final_time / static_cast<double>(config.steps);
    const double tau_squared = tau * tau;
    const double weight_i = tau_squared / (grid.hx * grid.hx);
    const double weight_j = tau_squared / (grid.hy * grid.hy);
    const double weight_k = tau_squared / (grid.hz * grid.hz);
    const double first_center =
        1.0 - (weight_i + weight_j + weight_k);
    const double next_center =
        2.0 - 2.0 * (weight_i + weight_j + weight_k);

    int effective_threads = 1;
    double start = 0.0;
    double elapsed = 0.0;

#pragma omp parallel num_threads(config.threads) \
    shared(previous, current, next, effective_threads, start, elapsed)
    {
        // Allocate without value-initialization, then first-touch every layer
        // with the same outer-i partition used by the stencil. This distributes
        // pages across NUMA nodes instead of placing them all on the master CPU.
#pragma omp for schedule(static)
        for (std::size_t i = 0; i < side; ++i) {
            const std::size_t slab_begin = i * stride_i;
            const std::size_t slab_end = slab_begin + stride_i;
#pragma omp simd
            for (std::size_t p = slab_begin; p < slab_end; ++p) {
                previous[p] = 0.0;
                current[p] = 0.0;
                next[p] = 0.0;
            }
        }

        // Initial u^0 setup is intentionally outside the measured solve time.
#pragma omp for schedule(static)
        for (std::size_t i = 1; i < config.n; ++i) {
            const double sin_i =
                std::sin(pi * static_cast<double>(i) / config.n);
            for (std::size_t j = 1; j < config.n; ++j) {
                const double sin_ij =
                    sin_i * std::sin(pi * static_cast<double>(j) / config.n);
                const std::size_t row = (i * side + j) * side;
#pragma omp simd
                for (std::size_t k = 1; k < config.n; ++k) {
                    previous[row + k] =
                        sin_ij * std::sin(pi * static_cast<double>(k) / config.n);
                }
            }
        }

#pragma omp single
        {
            effective_threads = omp_get_num_threads();
            start = omp_get_wtime();
        }

#pragma omp for schedule(static)
        for (std::size_t i = 1; i < config.n; ++i) {
            for (std::size_t j = 1; j < config.n; ++j) {
                const std::size_t row = (i * side + j) * side;
#pragma omp simd
                for (std::size_t k = 1; k < config.n; ++k) {
                    const std::size_t p = row + k;
                    current[p] =
                        first_center * previous[p] +
                        0.5 * weight_i *
                            (previous[p - stride_i] + previous[p + stride_i]) +
                        0.5 * weight_j *
                            (previous[p - stride_j] + previous[p + stride_j]) +
                        0.5 * weight_k *
                            (previous[p - 1] + previous[p + 1]);
                }
            }
        }

        for (std::size_t time_step = 1; time_step < config.steps;
             ++time_step) {
#pragma omp for schedule(static)
            for (std::size_t i = 1; i < config.n; ++i) {
                for (std::size_t j = 1; j < config.n; ++j) {
                    const std::size_t row = (i * side + j) * side;
#pragma omp simd
                    for (std::size_t k = 1; k < config.n; ++k) {
                        const std::size_t p = row + k;
                        next[p] =
                            next_center * current[p] - previous[p] +
                            weight_i *
                                (current[p - stride_i] + current[p + stride_i]) +
                            weight_j *
                                (current[p - stride_j] + current[p + stride_j]) +
                            weight_k * (current[p - 1] + current[p + 1]);
                    }
                }
            }
#pragma omp single
            {
                std::swap(previous, current);
                std::swap(current, next);
            }
        }

#pragma omp single
        elapsed = omp_get_wtime() - start;
    }

    if (current == layer_a.data()) {
        return {grid, std::move(layer_a), elapsed, effective_threads};
    }
    if (current == layer_b.data()) {
        return {grid, std::move(layer_b), elapsed, effective_threads};
    }
    return {grid, std::move(layer_c), elapsed, effective_threads};
}

double max_absolute_error(const Result& result, const wave::Config& config) {
    double maximum = 0.0;
#pragma omp parallel for schedule(static) reduction(max : maximum) \
    num_threads(config.threads)
    for (std::size_t i = 0; i <= config.n; ++i) {
        for (std::size_t j = 0; j <= config.n; ++j) {
            for (std::size_t k = 0; k <= config.n; ++k) {
                const double x = static_cast<double>(i) * result.grid.hx;
                const double y = static_cast<double>(j) * result.grid.hy;
                const double z = static_cast<double>(k) * result.grid.hz;
                const std::size_t p = wave::index(result.grid, i, j, k);
                maximum = std::max(
                    maximum,
                    std::abs(result.final_layer[p] -
                             wave::exact_solution(x, y, z, config.final_time,
                                                  config)));
            }
        }
    }
    return maximum;
}

}  // namespace wave_opt

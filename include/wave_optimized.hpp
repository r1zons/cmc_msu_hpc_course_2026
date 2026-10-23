#ifndef WAVE_OPTIMIZED_HPP
#define WAVE_OPTIMIZED_HPP

#include "wave.hpp"

#include <cstddef>
#include <memory>

namespace wave_opt {

class AlignedLayer {
public:
    explicit AlignedLayer(std::size_t size);
    AlignedLayer(AlignedLayer&&) noexcept = default;
    AlignedLayer& operator=(AlignedLayer&&) noexcept = default;
    AlignedLayer(const AlignedLayer&) = delete;
    AlignedLayer& operator=(const AlignedLayer&) = delete;

    double* data() noexcept { return data_.get(); }
    const double* data() const noexcept { return data_.get(); }
    std::size_t size() const noexcept { return size_; }
    double& operator[](std::size_t position) noexcept { return data_[position]; }
    const double& operator[](std::size_t position) const noexcept {
        return data_[position];
    }

private:
    struct AlignedDelete {
        void operator()(double* pointer) const noexcept;
    };

    std::size_t size_ = 0;
    std::unique_ptr<double[], AlignedDelete> data_;
};

struct Result {
    wave::Grid grid;
    AlignedLayer final_layer;
    double elapsed_seconds = 0.0;
    int effective_threads = 0;
};

Result solve(const wave::Config& config);
double max_absolute_error(const Result& result, const wave::Config& config);

}  // namespace wave_opt

#endif

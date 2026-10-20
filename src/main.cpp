#include "wave.hpp"

#include <charconv>
#include <cmath>
#include <cstdlib>
#include <exception>
#include <iomanip>
#include <iostream>
#include <new>
#include <optional>
#include <stdexcept>
#include <string>
#include <system_error>

namespace {

void print_usage(std::ostream& output, const char* program) {
    output << "Usage: " << program
           << " --n N --lx LX --ly LY --lz LZ --time T --steps K"
              " --threads THREADS\n\n"
              "Solve variant 1 of the 3D wave equation with OpenMP.\n"
              "N is the number of intervals on each axis, so the grid has"
              " (N+1)^3 nodes. T is physical final time, not a runtime limit.\n";
}

std::size_t parse_size(const std::string& text, const std::string& option) {
    std::size_t value = 0;
    const char* begin = text.data();
    const char* end = begin + text.size();
    const auto parsed = std::from_chars(begin, end, value);
    if (text.empty() || parsed.ec != std::errc{} || parsed.ptr != end) {
        throw std::invalid_argument("invalid nonnegative integer for " + option +
                                    ": " + text);
    }
    return value;
}

int parse_int(const std::string& text, const std::string& option) {
    int value = 0;
    const char* begin = text.data();
    const char* end = begin + text.size();
    const auto parsed = std::from_chars(begin, end, value);
    if (text.empty() || parsed.ec != std::errc{} || parsed.ptr != end) {
        throw std::invalid_argument("invalid integer for " + option + ": " +
                                    text);
    }
    return value;
}

double parse_double(const std::string& text, const std::string& option) {
    std::size_t consumed = 0;
    double value = 0.0;
    try {
        value = std::stod(text, &consumed);
    } catch (const std::exception&) {
        throw std::invalid_argument("invalid floating-point value for " + option +
                                    ": " + text);
    }
    if (consumed != text.size()) {
        throw std::invalid_argument("invalid floating-point value for " + option +
                                    ": " + text);
    }
    return value;
}

template <typename T>
void set_once(std::optional<T>& destination, T value,
              const std::string& option) {
    if (destination.has_value()) {
        throw std::invalid_argument("duplicate option: " + option);
    }
    destination = value;
}

wave::Config parse_arguments(int argc, char** argv) {
    std::optional<std::size_t> n;
    std::optional<double> lx;
    std::optional<double> ly;
    std::optional<double> lz;
    std::optional<double> final_time;
    std::optional<std::size_t> steps;
    std::optional<int> threads;

    for (int argument = 1; argument < argc; ++argument) {
        const std::string option = argv[argument];
        if (option == "--help") {
            print_usage(std::cout, argv[0]);
            std::exit(0);
        }
        if (option != "--n" && option != "--lx" && option != "--ly" &&
            option != "--lz" && option != "--time" && option != "--steps" &&
            option != "--threads") {
            throw std::invalid_argument("unknown argument: " + option);
        }
        if (++argument == argc) {
            throw std::invalid_argument("missing value for " + option);
        }
        const std::string value = argv[argument];
        if (option == "--n") {
            set_once(n, parse_size(value, option), option);
        } else if (option == "--lx") {
            set_once(lx, parse_double(value, option), option);
        } else if (option == "--ly") {
            set_once(ly, parse_double(value, option), option);
        } else if (option == "--lz") {
            set_once(lz, parse_double(value, option), option);
        } else if (option == "--time") {
            set_once(final_time, parse_double(value, option), option);
        } else if (option == "--steps") {
            set_once(steps, parse_size(value, option), option);
        } else {
            set_once(threads, parse_int(value, option), option);
        }
    }

    if (!n || !lx || !ly || !lz || !final_time || !steps || !threads) {
        throw std::invalid_argument(
            "all of --n, --lx, --ly, --lz, --time, --steps, and --threads "
            "are required");
    }
    return {*n, *lx, *ly, *lz, *final_time, *steps, *threads};
}

}  // namespace

int main(int argc, char** argv) {
    try {
        const wave::Config config = parse_arguments(argc, argv);
        const std::string validation_error = wave::validate_config(config);
        if (!validation_error.empty()) {
            throw std::invalid_argument(validation_error);
        }

        wave::Result result = wave::solve(config);
        const double error = wave::max_absolute_error(result, config);
        const double tau = config.final_time / static_cast<double>(config.steps);

        std::cout << std::setprecision(17)
                  << "n=" << config.n << '\n'
                  << "node_count=" << result.grid.node_count << '\n'
                  << "lx=" << config.lx << '\n'
                  << "ly=" << config.ly << '\n'
                  << "lz=" << config.lz << '\n'
                  << "physical_final_time=" << config.final_time << '\n'
                  << "time_steps=" << config.steps << '\n'
                  << "tau=" << tau << '\n'
                  << "openmp_threads=" << result.effective_threads << '\n'
                  << "solve_wall_seconds=" << result.elapsed_seconds << '\n'
                  << "max_absolute_error=" << error << '\n';
    } catch (const std::bad_alloc&) {
        std::cerr << "error: unable to allocate the three grid layers\n";
        return 1;
    } catch (const std::exception& error) {
        std::cerr << "error: " << error.what() << '\n';
        std::cerr << "Use --help for usage.\n";
        return 1;
    }
    return 0;
}

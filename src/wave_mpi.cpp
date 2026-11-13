#include "wave.hpp"

#define OMPI_SKIP_MPICXX 1
#include <mpi.h>
#include <omp.h>

#include <algorithm>
#include <array>
#include <charconv>
#include <cmath>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr double pi = 3.14159265358979323846;
using Axes = std::array<int, 3>;

int positive(const std::string& s) {
    int n = 0;
    const auto end = s.data() + s.size();
    const auto result = std::from_chars(s.data(), end, n);
    if (result.ec != std::errc{} || result.ptr != end || n < 1)
        throw std::invalid_argument("expected a positive integer: " + s);
    return n;
}

double real(const std::string& s) {
    std::size_t end = 0;
    const double x = std::stod(s, &end);
    if (end != s.size() || !std::isfinite(x) || x <= 0)
        throw std::invalid_argument("expected a positive finite number: " + s);
    return x;
}

struct Options {
    wave::Config config{128, 1, 1, 1, 0, 20, 1};
    Axes dims{};
    bool verify = false;
    bool help = false;
};

Options parse(int argc, char** argv) {
    Options o;
    auto& c = o.config;
    double cfl = 0.5;
    bool supplied_time = false;
    bool supplied_cfl = false;
    for (int a = 1; a < argc; ++a) {
        const std::string key = argv[a];
        if (key == "--help") { o.help = true; return o; }
        if (key == "--verify") { o.verify = true; continue; }
        if (++a == argc) throw std::invalid_argument("missing value for " + key);
        const std::string value = argv[a];
        if (key == "--n") c.n = positive(value);
        else if (key == "--lx") c.lx = real(value);
        else if (key == "--ly") c.ly = real(value);
        else if (key == "--lz") c.lz = real(value);
        else if (key == "--steps") c.steps = positive(value);
        else if (key == "--threads") c.threads = positive(value);
        else if (key == "--time") { c.final_time = real(value); supplied_time = true; }
        else if (key == "--cfl") { cfl = real(value); supplied_cfl = true; }
        else if (key == "--dims") {
            const auto x = value.find('x');
            const auto y = x == std::string::npos ? x : value.find('x', x + 1);
            if (y == std::string::npos) throw std::invalid_argument("expected Px x Py x Pz");
            o.dims = {positive(value.substr(0, x)), positive(value.substr(x + 1, y - x - 1)),
                      positive(value.substr(y + 1))};
        } else throw std::invalid_argument("unknown argument: " + key);
    }
    if ((supplied_time && supplied_cfl) || cfl > 1.0)
        throw std::invalid_argument("use either --time or --cfl in (0,1]");
    if (!supplied_time) {
        const double x = c.n / c.lx, y = c.n / c.ly, z = c.n / c.lz;
        c.final_time = c.steps * (cfl / std::sqrt(x*x + y*y + z*z));
    }
    return o;
}

struct Block {
    MPI_Comm cart = MPI_COMM_NULL;
    Axes dims, n{}, offset{}, extent{};
    std::array<int, 6> neighbors{};
    std::array<MPI_Datatype, 6> send{}, recv{};
    int rank = 0, ranks = 0;

    Block(int interior, Axes requested) : dims(requested) {
        MPI_Comm_size(MPI_COMM_WORLD, &ranks);
        if (dims[0] != 0) {
            if (ranks % dims[0] || (ranks / dims[0]) % dims[1] ||
                (ranks / dims[0] / dims[1]) != dims[2])
                throw std::invalid_argument("--dims product must equal MPI rank count");
        }
        MPI_Dims_create(ranks, 3, dims.data());
        for (int d : dims)
            if (d > interior) throw std::invalid_argument("process grid has empty blocks");
        const Axes periods{};
        MPI_Cart_create(MPI_COMM_WORLD, 3, dims.data(), periods.data(), 0, &cart);
        MPI_Comm_rank(cart, &rank);
        Axes coord{};
        MPI_Cart_coords(cart, rank, 3, coord.data());
        for (int a = 0; a < 3; ++a) {
            const int q = interior / dims[a], r = interior % dims[a];
            n[a] = q + (coord[a] < r);
            offset[a] = coord[a] * q + std::min(coord[a], r);
            extent[a] = n[a] + 2;
            MPI_Cart_shift(cart, a, 1, &neighbors[2*a], &neighbors[2*a+1]);
        }
        for (int f = 0; f < 6; ++f) {
            if (neighbors[f] == MPI_PROC_NULL) continue;
            const int a = f / 2;
            Axes sizes = n, origin{1,1,1};
            sizes[a] = 1;
            origin[a] = f % 2 ? n[a] : 1;
            face_type(sizes, origin, send[f]);
            origin[a] = f % 2 ? n[a]+1 : 0;
            face_type(sizes, origin, recv[f]);
        }
    }

    ~Block() {
        for (int f = 0; f < 6; ++f) {
            if (neighbors[f] == MPI_PROC_NULL) continue;
            MPI_Type_free(&send[f]);
            MPI_Type_free(&recv[f]);
        }
        MPI_Comm_free(&cart);
    }

    std::size_t at(int i, int j, int k) const {
        return (std::size_t(i) * extent[1] + j) * extent[2] + k;
    }

    void exchange(double* u) const {
        std::array<MPI_Request,12> requests;
        int count = 0;
        for (int f = 0; f < 6; ++f)
            if (neighbors[f] != MPI_PROC_NULL)
                MPI_Irecv(u, 1, recv[f], neighbors[f], f ^ 1, cart, &requests[count++]);
        for (int f = 0; f < 6; ++f)
            if (neighbors[f] != MPI_PROC_NULL)
                MPI_Isend(u, 1, send[f], neighbors[f], f, cart, &requests[count++]);
        MPI_Waitall(count, requests.data(), MPI_STATUSES_IGNORE);
    }

    template<class Check>
    void visit_faces(Check check) const {
        for (int f = 0; f < 6; ++f) {
            const int a = f / 2;
            Axes lo{1,1,1}, hi = n;
            lo[a] = hi[a] = f % 2 ? n[a]+1 : 0;
            for (int i = lo[0]; i <= hi[0]; ++i)
                for (int j = lo[1]; j <= hi[1]; ++j)
                    for (int k = lo[2]; k <= hi[2]; ++k)
                        check(f, i, j, k);
        }
    }

private:
    void face_type(const Axes& sizes, const Axes& origin, MPI_Datatype& type) const {
        MPI_Type_create_subarray(3, extent.data(), sizes.data(), origin.data(),
                                 MPI_ORDER_C, MPI_DOUBLE, &type);
        MPI_Type_commit(&type);
    }
};

double max_all(double local, MPI_Comm comm) {
    double global = 0;
    MPI_Allreduce(&local, &global, 1, MPI_DOUBLE, MPI_MAX, comm);
    return global;
}

void verify_halos(const Block& b, double* layer, int n) {
    const auto value = [&](int i, int j, int k) {
        const double side = double(n) + 1.0;
        return 1.0 + ((b.offset[0]+i)*side + b.offset[1]+j)*side + b.offset[2]+k;
    };
    for (int i = 1; i <= b.n[0]; ++i)
        for (int j = 1; j <= b.n[1]; ++j)
            for (int k = 1; k <= b.n[2]; ++k)
                layer[b.at(i,j,k)] = value(i,j,k);
    b.exchange(layer);
    double bad = 0;
    b.visit_faces([&](int f, int i, int j, int k) {
        const double expected = b.neighbors[f] == MPI_PROC_NULL ? 0 : value(i,j,k);
        if (layer[b.at(i,j,k)] != expected) bad = 1;
    });
    if (max_all(bad, b.cart) != 0) throw std::runtime_error("halo check failed");
}

void solve(const Options& o, int mpi_thread_level) {
    const auto& c = o.config;
    const auto grid = wave::make_grid(c);
    const Block b(static_cast<int>(c.n - 1), o.dims);
    const auto size = b.at(b.extent[0], 0, 0);
    if (size > std::numeric_limits<std::size_t>::max() / sizeof(double) / 3)
        throw std::length_error("local block is too large");
    std::unique_ptr<double[]> a(new double[size]), d(new double[size]), e(new double[size]);
    double* prev = a.get();
    double* cur = d.get();
    double* next = e.get();
    int threads = 1;
    omp_set_dynamic(0);
#pragma omp parallel if(c.threads > 1) num_threads(c.threads)
    {
#pragma omp single
        threads = omp_get_num_threads();
#pragma omp for schedule(static)
        for (int i = 0; i < b.extent[0]; ++i)
            for (std::size_t p = b.at(i,0,0); p < b.at(i+1,0,0); ++p)
                prev[p] = cur[p] = next[p] = 0;
    }
    if (max_all(double(threads != c.threads), b.cart))
        throw std::runtime_error("OpenMP team size differs from request");
    if (o.verify) verify_halos(b, next, static_cast<int>(c.n));

    const auto mode = [&](int i, int j, int k) {
        return std::sin(pi*(b.offset[0]+i)/c.n) * std::sin(pi*(b.offset[1]+j)/c.n) *
               std::sin(pi*(b.offset[2]+k)/c.n);
    };
#pragma omp parallel for if(c.threads > 1) num_threads(c.threads) schedule(static)
    for (int i = 1; i <= b.n[0]; ++i)
        for (int j = 1; j <= b.n[1]; ++j)
            for (int k = 1; k <= b.n[2]; ++k)
                cur[b.at(i,j,k)] = mode(i,j,k);

    const double dt = c.final_time / c.steps;
    const auto sx = std::ptrdiff_t(b.at(1,0,0)), sy = std::ptrdiff_t(b.at(0,1,0));
    const double wx = (dt*dt)/(grid.hx*grid.hx), wy = (dt*dt)/(grid.hy*grid.hy);
    const double wz = (dt*dt)/(grid.hz*grid.hz);
    MPI_Barrier(b.cart);
    const double start = MPI_Wtime();
    for (std::size_t step = 0; step < c.steps; ++step) {
        b.exchange(cur);
        const double factor = step == 0 ? 0.5 : 1.0;
        const double x = factor*wx, y = factor*wy, z = factor*wz;
        const double center = (step == 0 ? 1.0 : 2.0) - 2*(x+y+z);
        const double old = step == 0 ? 0.0 : 1.0;
#pragma omp parallel for if(c.threads > 1) num_threads(c.threads) schedule(static)
        for (int i = 1; i <= b.n[0]; ++i)
            for (int j = 1; j <= b.n[1]; ++j) {
                const auto row = std::ptrdiff_t(b.at(i,j,0));
#pragma omp simd
                for (int k = 1; k <= b.n[2]; ++k) {
                    const auto p = row + k;
                    next[p] = center*cur[p] - old*prev[p] +
                              x*(cur[p-sx]+cur[p+sx]) +
                              y*(cur[p-sy]+cur[p+sy]) + z*(cur[p-1]+cur[p+1]);
                }
            }
        std::swap(prev, cur);
        std::swap(cur, next);
    }
    const double elapsed = max_all(MPI_Wtime() - start, b.cart);

    const double ix = 1/c.lx, iy = 1/c.ly, iz = 1/c.lz;
    const double exact_amp = std::cos(pi*std::sqrt(ix*ix+iy*iy+iz*iz)*c.final_time);
    const double theta = 2*std::asin(std::sin(pi/(2*c.n))*std::sqrt(wx+wy+wz));
    const double discrete_amp = std::cos(c.steps*theta);
    double error = 0, discrete_error = 0, boundary_error = 0;
#pragma omp parallel for if(c.threads > 1) num_threads(c.threads) schedule(static) reduction(max:error,discrete_error)
    for (int i = 1; i <= b.n[0]; ++i)
        for (int j = 1; j <= b.n[1]; ++j)
            for (int k = 1; k <= b.n[2]; ++k) {
                const double u = cur[b.at(i,j,k)], phi = mode(i,j,k);
                error = std::max(error, std::isfinite(u) ? std::abs(u-phi*exact_amp) : INFINITY);
                if (o.verify)
                    discrete_error = std::max(discrete_error, std::abs(u-phi*discrete_amp));
            }
    b.visit_faces([&](int f, int i, int j, int k) {
        if (b.neighbors[f] == MPI_PROC_NULL && cur[b.at(i,j,k)] != 0) boundary_error = 1;
    });
    error = max_all(error, b.cart);
    discrete_error = max_all(discrete_error, b.cart);
    boundary_error = max_all(boundary_error, b.cart);
    const double tolerance = 8 * std::numeric_limits<double>::epsilon() *
                             double(c.steps+1) * double(c.steps+1);
    if (!std::isfinite(error) || boundary_error || (o.verify && discrete_error > tolerance))
        throw std::runtime_error("final solution verification failed");

    std::array<char,MPI_MAX_PROCESSOR_NAME> host{};
    int host_len = 0;
    MPI_Get_processor_name(host.data(), &host_len);
    std::vector<char> hosts(b.rank == 0 ? host.size()*b.ranks : 0);
    MPI_Gather(host.data(), host.size(), MPI_CHAR, hosts.data(), host.size(), MPI_CHAR, 0, b.cart);
    if (b.rank == 0) {
        std::array<char,MPI_MAX_LIBRARY_VERSION_STRING> library{};
        int len = 0;
        MPI_Get_library_version(library.data(), &len);
        std::string version(library.data());
        std::replace(version.begin(), version.end(), '\n', ' ');
        std::cout << std::setprecision(17)
                  << "n=" << c.n << "\nnode_count=" << grid.node_count
                  << "\nlx=" << c.lx << "\nly=" << c.ly << "\nlz=" << c.lz
                  << "\nphysical_final_time=" << c.final_time << "\ntau=" << dt
                  << "\ntime_steps=" << c.steps << "\nmpi_ranks=" << b.ranks
                  << "\nprocess_grid=" << b.dims[0] << 'x' << b.dims[1] << 'x' << b.dims[2]
                  << "\nopenmp_threads=" << threads << "\nmpi_thread_level=" << mpi_thread_level
                  << "\nmpi_library=" << version << "\nhosts=";
        for (int r = 0; r < b.ranks; ++r)
            std::cout << (r == 0 ? "" : ",") << hosts.data()+r*host.size();
        std::cout << "\nsolve_wall_seconds=" << elapsed << "\nmax_absolute_error=" << error
                  << "\nboundary_check=passed\n";
        if (o.verify) std::cout << "halo_check=passed\ndiscrete_max_error=" << discrete_error << '\n';
    }
}

}  // namespace

int main(int argc, char** argv) {
    int provided = MPI_THREAD_SINGLE;
    if (MPI_Init_thread(&argc, &argv, MPI_THREAD_FUNNELED, &provided) != MPI_SUCCESS) return 1;
    int rank = 0;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    try {
        if (provided < MPI_THREAD_FUNNELED) throw std::runtime_error("MPI_THREAD_FUNNELED unavailable");
        const auto o = parse(argc, argv);
        if (o.help) {
            if (rank == 0)
                std::cout << "wave_solver_mpi [--n N] [--lx L --ly L --lz L] [--steps K]\n"
                             "  [--cfl F | --time T] [--threads P] [--dims PxXPyXPz] [--verify]\n";
        } else solve(o, provided);
    } catch (const std::exception& ex) {
        std::cerr << "rank " << rank << ": " << ex.what() << '\n';
        MPI_Abort(MPI_COMM_WORLD, 1);
        return 1;
    }
    MPI_Finalize();
}

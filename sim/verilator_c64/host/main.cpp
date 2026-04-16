#include <array>
#include <cctype>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "verilated.h"
#if VM_TRACE
#include "verilated_fst_c.h"
#endif
#include "Vverilator_c64_top.h"

#ifdef HAVE_SDL2
#include <SDL2/SDL.h>
#endif

namespace {

struct Options {
    std::string rom_path = "../../C64_MiSTer/rtl/roms/std_C64.mif";
    std::optional<std::string> prg_path;
    std::optional<std::string> trace_path;
    uint64_t cycles = 5'000'000;
    bool headless = false;
};

std::string to_lower(std::string s) {
    for (char& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

bool ends_with_ci(const std::string& s, const std::string& suffix) {
    if (suffix.size() > s.size()) return false;
    return to_lower(s.substr(s.size() - suffix.size())) == to_lower(suffix);
}

[[noreturn]] void usage(const char* argv0) {
    std::cerr
        << "Usage: " << argv0 << " [options]\n"
        << "  --rom <path>      ROM image (.mif or 16KB .bin)\n"
        << "  --prg <path>      PRG to inject after ROM streaming\n"
        << "  --cycles <n>      Half-cycles to run after setup (default 5000000)\n"
        << "  --trace <path>    Write FST waveform\n"
        << "  --headless        Disable SDL window\n";
    std::exit(1);
}

Options parse_args(int argc, char** argv) {
    Options opt;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto need_value = [&](const char* name) -> std::string {
            if (i + 1 >= argc) {
                std::cerr << "Missing value for " << name << "\n";
                std::exit(1);
            }
            return argv[++i];
        };

        if (arg == "--rom") opt.rom_path = need_value("--rom");
        else if (arg == "--prg") opt.prg_path = need_value("--prg");
        else if (arg == "--cycles") opt.cycles = std::stoull(need_value("--cycles"));
        else if (arg == "--trace") opt.trace_path = need_value("--trace");
        else if (arg == "--headless") opt.headless = true;
        else if (arg == "-h" || arg == "--help") usage(argv[0]);
        else {
            std::cerr << "Unknown argument: " << arg << "\n";
            usage(argv[0]);
        }
    }
    return opt;
}

std::vector<uint8_t> read_binary_file(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("Failed to open file: " + path);
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}

int hex_value(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

std::vector<uint8_t> read_mif_16k(const std::string& path) {
    std::ifstream f(path);
    if (!f) throw std::runtime_error("Failed to open MIF: " + path);

    std::vector<uint8_t> rom(16 * 1024, 0xea);
    std::string line;
    bool in_content = false;
    size_t count = 0;

    while (std::getline(f, line)) {
        const auto comment = line.find("--");
        if (comment != std::string::npos) line.resize(comment);
        if (line.find("CONTENT") != std::string::npos) {
            in_content = true;
            continue;
        }
        if (!in_content) continue;
        if (line.find("END") != std::string::npos) break;

        const auto colon = line.find(':');
        const auto semi = line.find(';');
        if (colon == std::string::npos || semi == std::string::npos || colon > semi) continue;

        auto trim = [](std::string s) {
            while (!s.empty() && std::isspace(static_cast<unsigned char>(s.front()))) s.erase(s.begin());
            while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back()))) s.pop_back();
            return s;
        };

        const std::string addr_s = trim(line.substr(0, colon));
        const std::string data_s = trim(line.substr(colon + 1, semi - colon - 1));
        if (addr_s.empty() || data_s.empty()) continue;

        unsigned addr = 0;
        for (char c : addr_s) {
            const int v = hex_value(c);
            if (v < 0) { addr = 0xffff'ffffu; break; }
            addr = (addr << 4) | static_cast<unsigned>(v);
        }
        unsigned data = 0;
        for (char c : data_s) {
            const int v = hex_value(c);
            if (v < 0) { data = 0xffff'ffffu; break; }
            data = (data << 4) | static_cast<unsigned>(v);
        }

        if (addr < rom.size() && data <= 0xff) {
            rom[addr] = static_cast<uint8_t>(data);
            ++count;
        }
    }

    if (count < 16000) {
        throw std::runtime_error("MIF parse yielded too few bytes: " + std::to_string(count));
    }
    return rom;
}

std::vector<uint8_t> load_rom_image(const std::string& path) {
    if (ends_with_ci(path, ".mif")) return read_mif_16k(path);
    auto data = read_binary_file(path);
    if (data.size() < 16 * 1024) {
        throw std::runtime_error("ROM file too small (need 16KB): " + path);
    }
    data.resize(16 * 1024);
    return data;
}

struct Rasterizer {
#ifdef HAVE_SDL2
    SDL_Window* window = nullptr;
    SDL_Renderer* renderer = nullptr;
    SDL_Texture* texture = nullptr;
#endif
    static constexpr int kWidth = 640;
    static constexpr int kHeight = 312;
    bool enabled = false;
    int h = 0;
    int v = 0;
    int prev_hsync = 1;
    int prev_vsync = 1;
    std::vector<uint32_t> pixels = std::vector<uint32_t>(kWidth * kHeight, 0xff000000u);

    explicit Rasterizer(bool want_window) {
#ifdef HAVE_SDL2
        if (!want_window) return;
        if (SDL_Init(SDL_INIT_VIDEO) != 0) {
            std::cerr << "SDL init failed: " << SDL_GetError() << "\n";
            return;
        }
        window = SDL_CreateWindow("MiSTer C64 Verilator", SDL_WINDOWPOS_CENTERED,
                                  SDL_WINDOWPOS_CENTERED, kWidth * 2, kHeight * 2, 0);
        if (!window) {
            std::cerr << "SDL_CreateWindow failed: " << SDL_GetError() << "\n";
            SDL_Quit();
            return;
        }
        renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
        texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ARGB8888,
                                    SDL_TEXTUREACCESS_STREAMING, kWidth, kHeight);
        enabled = (renderer && texture);
#else
        (void)want_window;
#endif
    }

    ~Rasterizer() {
#ifdef HAVE_SDL2
        if (texture) SDL_DestroyTexture(texture);
        if (renderer) SDL_DestroyRenderer(renderer);
        if (window) SDL_DestroyWindow(window);
        if (window || renderer || texture) SDL_Quit();
#endif
    }

    void poll_events(bool& running) {
#ifdef HAVE_SDL2
        if (!enabled) return;
        SDL_Event ev;
        while (SDL_PollEvent(&ev)) {
            if (ev.type == SDL_QUIT) running = false;
        }
#else
        (void)running;
#endif
    }

    void sample(const Vverilator_c64_top& top) {
        const int hs = top.hsync ? 1 : 0;
        const int vs = top.vsync ? 1 : 0;

        if (prev_hsync == 1 && hs == 0) {
            h = 0;
            ++v;
        } else {
            ++h;
        }

        if (prev_vsync == 1 && vs == 0) {
            present();
            v = 0;
        }

        if (h >= 0 && h < kWidth && v >= 0 && v < kHeight) {
            const uint32_t r = static_cast<uint32_t>(top.red & 0xffu);
            const uint32_t g = static_cast<uint32_t>(top.green & 0xffu);
            const uint32_t b = static_cast<uint32_t>(top.blue & 0xffu);
            pixels[v * kWidth + h] = 0xff000000u | (r << 16) | (g << 8) | b;
        }

        prev_hsync = hs;
        prev_vsync = vs;
    }

    void present() {
#ifdef HAVE_SDL2
        if (!enabled) return;
        SDL_UpdateTexture(texture, nullptr, pixels.data(), kWidth * sizeof(uint32_t));
        SDL_RenderClear(renderer);
        SDL_RenderCopy(renderer, texture, nullptr, nullptr);
        SDL_RenderPresent(renderer);
#endif
    }
};

struct Sim {
    Vverilator_c64_top top;
    uint64_t ticks = 0;
#if VM_TRACE
    VerilatedFstC* trace = nullptr;
#endif
    Rasterizer raster;
    bool running = true;

    explicit Sim(bool want_window) : raster(want_window) {
        top.clk32 = 0;
        top.reset = 1;
        top.rom_wr = 0;
        top.rom_addr = 0;
        top.rom_data = 0;
        top.ioctl_download = 0;
        top.ioctl_wr = 0;
        top.ioctl_addr = 0;
        top.ioctl_data = 0;
        top.ioctl_index = 1;
        top.ps2_key = 0;
        top.kbd_reset = 0;
        top.shift_mod = 0;
        top.joyA = 0;
        top.joyB = 0;
        top.pot1 = 0;
        top.pot2 = 0;
        top.pot3 = 0;
        top.pot4 = 0;
        top.probe_addr = 0;
        top.bram_probe_addr = 0;
    }

    void eval() {
        top.eval();
#if VM_TRACE
        if (trace) trace->dump(ticks);
#endif
        raster.sample(top);
        raster.poll_events(running);
        ++ticks;
    }

    void tick() {
        top.clk32 = 0;
        eval();
        top.clk32 = 1;
        eval();
    }

    uint8_t probe(uint32_t addr) {
        top.probe_addr = addr & 0x00ffffffu;
        top.eval();
        return static_cast<uint8_t>(top.probe_data & 0xffu);
    }

    uint8_t probe_bram(uint16_t addr) {
        top.bram_probe_addr = addr;
        top.eval();
        return static_cast<uint8_t>(top.bram_probe_data & 0xffu);
    }

    void hold_reset_cycles(unsigned n) {
        top.reset = 1;
        for (unsigned i = 0; i < n; ++i) tick();
    }

    void release_reset_cycles(unsigned n) {
        top.reset = 0;
        for (unsigned i = 0; i < n; ++i) tick();
    }

    void pulse_rom_write(uint16_t addr, uint8_t data) {
        top.rom_addr = addr;
        top.rom_data = data;
        top.rom_wr = 1;
        tick();
        top.rom_wr = 0;
        tick();
    }

    void stream_rom(const std::vector<uint8_t>& rom) {
        for (size_t i = 0; i < rom.size(); ++i) {
            pulse_rom_write(static_cast<uint16_t>(i), rom[i]);
        }
    }

    void stream_prg(const std::vector<uint8_t>& prg) {
        if (prg.size() < 2) throw std::runtime_error("PRG too small");
        top.ioctl_index = 0x01;
        top.ioctl_download = 1;
        for (size_t i = 0; i < prg.size(); ++i) {
            top.ioctl_addr = static_cast<uint16_t>(i);
            top.ioctl_data = prg[i];
            top.ioctl_wr = 1;
            tick();
            top.ioctl_wr = 0;
            tick();
        }
        top.ioctl_download = 0;
        tick();
    }
};

void dump_text_screen(Sim& sim) {
    std::cout << "\n-- BRAM screen $0400..$07E7 --\n";
    for (int row = 0; row < 25; ++row) {
        std::ostringstream line;
        for (int col = 0; col < 40; ++col) {
            const auto addr = static_cast<uint16_t>(0x0400 + row * 40 + col);
            char c = static_cast<char>(sim.probe_bram(addr) & 0x7f);
            if (c < 32 || c > 126) c = '.';
            line << c;
        }
        std::cout << line.str() << '\n';
    }
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const Options opt = parse_args(argc, argv);

    try {
        const auto rom = load_rom_image(opt.rom_path);
        Sim sim(!opt.headless);

#if VM_TRACE
        if (opt.trace_path) {
            Verilated::traceEverOn(true);
            sim.trace = new VerilatedFstC();
            sim.top.trace(sim.trace, 99);
            sim.trace->open(opt.trace_path->c_str());
        }
#endif

        sim.hold_reset_cycles(64);
        std::cout << "Streaming ROM under reset: " << opt.rom_path << "\n";
        sim.stream_rom(rom);
        sim.release_reset_cycles(64);

        if (opt.prg_path) {
            std::cout << "Streaming PRG: " << *opt.prg_path << "\n";
            sim.stream_prg(read_binary_file(*opt.prg_path));
        }

        std::cout << "Running " << opt.cycles << " half-cycles...\n";
        for (uint64_t i = 0; i < opt.cycles && sim.running; ++i) {
            sim.tick();
            if ((i % 500000) == 0) {
                std::cout << "tick=" << i
                          << " pc=$" << std::hex << static_cast<unsigned>(sim.top.dbg_pc)
                          << " ir=$" << static_cast<unsigned>(sim.top.dbg_ir)
                          << " pbr=$" << static_cast<unsigned>(sim.top.dbg_pbr)
                          << std::dec << "\n";
            }
        }

        dump_text_screen(sim);

#if VM_TRACE
        if (sim.trace) {
            sim.trace->close();
            delete sim.trace;
            sim.trace = nullptr;
        }
#endif
        sim.top.final();
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "fatal: " << e.what() << "\n";
        return 1;
    }
}

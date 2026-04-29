#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "verilated.h"
#if VM_TRACE
#include "verilated_fst_c.h"
#endif
#include "Vverilator_c64_vanilla_top.h"

#ifdef HAVE_SDL2
#include <SDL2/SDL.h>
#endif

namespace {

struct Options {
    std::string rom_path = "../../C64_MiSTer/rtl/roms/std_C64.mif";
    std::optional<std::string> prg_path;
    std::optional<std::string> trace_path;
    uint64_t cycles = 5'000'000;
    uint64_t prg_delay_cycles = 64;
    uint64_t log_every = 500'000;
    uint64_t snapshot_every = 0;
    std::string powerup_init = "vice";
    bool headless = false;
    bool stop_on_ready = false;
    bool skip_ramtest = false;
    uint64_t ready_poll_interval = 50'000;
    std::optional<std::string> screenshot_path;
    std::optional<std::string> text_screenshot_path;
    std::string chargen_path = "../../C64_MiSTer/rtl/roms/chargen.mif";
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
        << "  --rom <path>           ROM image (.mif or 16KB .bin)\n"
        << "  --prg <path>           PRG to inject after ROM streaming\n"
        << "  --cycles <n>           Half-cycles to run after setup (default 5000000)\n"
        << "  --prg-delay <n>        Half-cycles to wait after reset release before PRG inject\n"
        << "  --log-every <n>        Periodic CPU/status log interval in half-cycles\n"
        << "  --snapshot-every <n>   Periodic BASIC/PRG memory snapshots (0 disables)\n"
        << "  --powerup-init <mode>  off | zero | vice (default vice)\n"
        << "  --trace <path>         Write FST waveform\n"
        << "  --stop-on-ready        Stop once BRAM screen contains READY\n"
        << "  --ready-poll <n>       Half-cycles between READY checks (default 50000)\n"
        << "  --skip-ramtest         Patch KERNAL RAMTAS to skip RAM scan (saves ~24M cycles)\n"
        << "  --screenshot <path>    Write last VIC-II frame as PPM on exit\n"
        << "  --text-screenshot <p>  Write BRAM-rendered text-mode screen as PPM (uses chargen.mif)\n"
        << "  --chargen <path>       Path to chargen.mif (default ../../C64_MiSTer/rtl/roms/chargen.mif)\n"
        << "  --headless             Disable SDL window\n";
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
        else if (arg == "--prg-delay") opt.prg_delay_cycles = std::stoull(need_value("--prg-delay"));
        else if (arg == "--log-every") opt.log_every = std::stoull(need_value("--log-every"));
        else if (arg == "--snapshot-every") opt.snapshot_every = std::stoull(need_value("--snapshot-every"));
        else if (arg == "--powerup-init") opt.powerup_init = to_lower(need_value("--powerup-init"));
        else if (arg == "--trace") opt.trace_path = need_value("--trace");
        else if (arg == "--headless") opt.headless = true;
        else if (arg == "--stop-on-ready") opt.stop_on_ready = true;
        else if (arg == "--ready-poll") opt.ready_poll_interval = std::stoull(need_value("--ready-poll"));
        else if (arg == "--skip-ramtest") opt.skip_ramtest = true;
        else if (arg == "--screenshot") opt.screenshot_path = need_value("--screenshot");
        else if (arg == "--text-screenshot") opt.text_screenshot_path = need_value("--text-screenshot");
        else if (arg == "--chargen") opt.chargen_path = need_value("--chargen");
        else if (arg == "-h" || arg == "--help") usage(argv[0]);
        else {
            std::cerr << "Unknown argument: " << arg << "\n";
            usage(argv[0]);
        }
    }
    if (opt.powerup_init != "off" && opt.powerup_init != "zero" && opt.powerup_init != "vice") {
        throw std::runtime_error("Invalid --powerup-init mode: " + opt.powerup_init);
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
            if (v < 0) {
                addr = 0xffff'ffffu;
                break;
            }
            addr = (addr << 4) | static_cast<unsigned>(v);
        }
        unsigned data = 0;
        for (char c : data_s) {
            const int v = hex_value(c);
            if (v < 0) {
                data = 0xffff'ffffu;
                break;
            }
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

// Patch the KERNAL RAMTAS routine ($FD50) so cold boot skips the 38KB RAM
// byte scan. In a Verilator run the scan alone costs ~24M half-cycles and
// is the dominant term before first READY.
//
// Layout: the 16KB ROM image holds BASIC at file offset $0000-$1FFF and
// KERNAL at $2000-$3FFF. RAMTAS lives at $FD50 = file offset $3D50.
//
// We keep the original ZP/page2/page3 clear loop ($FD50-$FD5E, 15 bytes,
// fast) and replace the RAM scan body ($FD5F onward) with a direct pointer
// setup matching the post-RAMTAS state the caller expects:
//   $B2/$B3       = $03/$3C (tape buffer pointer -> $033C)
//   $0281/$0282   = $00/$08 (MEMBOT = $0800)
//   $0283/$0284   = $00/$A0 (MEMSIZ = $A000)
//   $0288         = $04     (HIBASE / screen page)
// Then RTS. MEMBOT-lo / MEMSIZ-lo / HIBASE-lo are left at $00 by the
// preceding clear loop.
//
// Sanity-checked against std_C64.mif: RESET vector at $3FFC/$3FFD = E2 FC,
// RAMTAS start at $3D50..$3D5E matches the stock A9 00 A8 99 02 00 99 00
// 02 99 00 03 C8 D0 F4 clear-loop signature.
bool patch_kernal_skip_ramtest(std::vector<uint8_t>& rom) {
    if (rom.size() != 16 * 1024) return false;
    if (rom[0x3FFC] != 0xE2 || rom[0x3FFD] != 0xFC) return false;

    static const uint8_t signature[] = {
        0xA9, 0x00, 0xA8, 0x99, 0x02, 0x00, 0x99, 0x00,
        0x02, 0x99, 0x00, 0x03, 0xC8, 0xD0, 0xF4
    };
    if (std::memcmp(rom.data() + 0x3D50, signature, sizeof(signature)) != 0) {
        return false;
    }

    static const uint8_t patch[] = {
        0xA9, 0x3C,             // FD5F  LDA #$3C
        0x85, 0xB2,             // FD61  STA $B2
        0xA9, 0x03,             // FD63  LDA #$03
        0x85, 0xB3,             // FD65  STA $B3
        0xA9, 0x08,             // FD67  LDA #$08
        0x8D, 0x82, 0x02,       // FD69  STA $0282  (MEMBOT hi)
        0xA9, 0xA0,             // FD6C  LDA #$A0
        0x8D, 0x84, 0x02,       // FD6E  STA $0284  (MEMSIZ hi)
        0xA9, 0x04,             // FD71  LDA #$04
        0x8D, 0x88, 0x02,       // FD73  STA $0288  (HIBASE / screen page)
        0x60                    // FD76  RTS
    };
    std::memcpy(rom.data() + 0x3D5F, patch, sizeof(patch));
    return true;
}

struct PrgInfo {
    uint16_t load_addr = 0;
    std::vector<uint8_t> payload;
};

PrgInfo decode_prg(const std::vector<uint8_t>& prg) {
    if (prg.size() < 2) throw std::runtime_error("PRG too small");
    PrgInfo info;
    info.load_addr = static_cast<uint16_t>(prg[0] | (static_cast<uint16_t>(prg[1]) << 8));
    info.payload.assign(prg.begin() + 2, prg.end());
    return info;
}

uint8_t encode_powerup_init_mode(const std::string& mode) {
    if (mode == "off") return 0;
    if (mode == "zero") return 1;
    return 2;  // vice
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
    bool capture = false;
    int h = 0;
    int v = 0;
    int prev_hsync = 1;
    int prev_vsync = 1;
    uint64_t hsync_edges = 0;
    uint64_t vsync_edges = 0;
    uint64_t samples = 0;
    uint64_t nonblack_samples = 0;
    std::vector<uint32_t> pixels = std::vector<uint32_t>(kWidth * kHeight, 0xff000000u);

    explicit Rasterizer(bool want_window, bool want_capture = false) {
        capture = want_capture;
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

    void sample(const Vverilator_c64_vanilla_top& top) {
        if (!enabled && !capture) return;
        const int hs = top.hsync ? 1 : 0;
        const int vs = top.vsync ? 1 : 0;

        if (prev_hsync == 1 && hs == 0) {
            h = 0;
            ++v;
            ++hsync_edges;
        } else {
            ++h;
        }

        if (prev_vsync == 1 && vs == 0) {
            present();
            v = 0;
            ++vsync_edges;
        }

        const uint32_t r = static_cast<uint32_t>(top.red & 0xffu);
        const uint32_t g = static_cast<uint32_t>(top.green & 0xffu);
        const uint32_t b = static_cast<uint32_t>(top.blue & 0xffu);
        if ((r | g | b) != 0) ++nonblack_samples;
        ++samples;

        const int px = h >> 3;
        if (px >= 0 && px < kWidth && v >= 0 && v < kHeight) {
            pixels[v * kWidth + px] = 0xff000000u | (r << 16) | (g << 8) | b;
        }

        prev_hsync = hs;
        prev_vsync = vs;
    }

    void dump_stats() const {
        std::cout << "Rasterizer: samples=" << samples
                  << " hsync_edges=" << hsync_edges
                  << " vsync_edges=" << vsync_edges
                  << " nonblack_samples=" << nonblack_samples << "\n";
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

    bool save_ppm(const std::string& path) const {
        std::ofstream f(path, std::ios::binary);
        if (!f) return false;
        f << "P6\n" << kWidth << " " << kHeight << "\n255\n";
        for (int y = 0; y < kHeight; ++y) {
            for (int x = 0; x < kWidth; ++x) {
                const uint32_t px = pixels[y * kWidth + x];
                const unsigned char rgb[3] = {
                    static_cast<unsigned char>((px >> 16) & 0xff),
                    static_cast<unsigned char>((px >> 8) & 0xff),
                    static_cast<unsigned char>(px & 0xff)};
                f.write(reinterpret_cast<const char*>(rgb), 3);
            }
        }
        return static_cast<bool>(f);
    }
};

struct Sim {
    Vverilator_c64_vanilla_top top;
    uint64_t ticks = 0;
#if VM_TRACE
    VerilatedFstC* trace = nullptr;
#endif
    Rasterizer raster;
    bool running = true;

    explicit Sim(bool want_window, uint8_t powerup_init_mode, bool want_capture = false)
        : raster(want_window, want_capture) {
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
        top.powerup_init_mode = powerup_init_mode;
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
    }

    ~Sim() {
#if VM_TRACE
        if (trace) {
            trace->close();
            delete trace;
            trace = nullptr;
        }
#endif
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

    uint8_t probe_bram(uint16_t /*addr*/) {
        // BRAM probe port removed to restore M10K inference in synthesis
        // (see docs/session_passover_2026_04_19.md). Vanilla harness features
        // that read bank $00 via this path are disabled until a synchronous
        // probe is wired in.
        return 0;
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

std::vector<uint8_t> probe_range(Sim& sim, uint32_t addr, size_t len, bool bram) {
    std::vector<uint8_t> out;
    out.reserve(len);
    for (size_t i = 0; i < len; ++i) {
        out.push_back(bram ? sim.probe_bram(static_cast<uint16_t>(addr + i))
                           : sim.probe(addr + static_cast<uint32_t>(i)));
    }
    return out;
}

std::string printable_byte(uint8_t v) {
    char c = static_cast<char>(v & 0x7f);
    if (c >= 32 && c <= 126) return std::string(1, c);
    return ".";
}

char c64_screen_code_to_ascii(uint8_t code) {
    code &= 0x7f;
    if (code == 0) return '@';
    if (code >= 1 && code <= 26) return static_cast<char>('A' + code - 1);
    if (code == 27) return '[';
    if (code == 28) return '#';
    if (code == 29) return ']';
    if (code == 30) return '^';
    if (code == 31) return '_';
    if (code >= 32 && code <= 63) return static_cast<char>(code);
    if (code >= 64 && code <= 90) return static_cast<char>('A' + (code - 64));
    if (code >= 96 && code <= 122) return static_cast<char>('a' + (code - 96));
    return '.';
}

void dump_hex_block(std::string_view label, uint32_t base, const std::vector<uint8_t>& data) {
    std::cout << std::right;
    std::cout << label << " @ $" << std::hex << std::setw(4) << std::setfill('0') << base << std::dec << "\n";
    for (size_t i = 0; i < data.size(); i += 16) {
        std::cout << "  $" << std::hex << std::setw(4) << std::setfill('0') << (base + i) << ": ";
        for (size_t j = 0; j < 16; ++j) {
            if (i + j < data.size()) {
                std::cout << std::setw(2) << static_cast<unsigned>(data[i + j]) << ' ';
            } else {
                std::cout << "   ";
            }
        }
        std::cout << " |";
        for (size_t j = 0; j < 16 && i + j < data.size(); ++j) {
            std::cout << printable_byte(data[i + j]);
        }
        std::cout << "|\n";
    }
    std::cout << std::dec << std::setfill(' ');
}

uint16_t read_le_bram(Sim& sim, uint16_t addr) {
    return static_cast<uint16_t>(sim.probe_bram(addr) | (static_cast<uint16_t>(sim.probe_bram(addr + 1)) << 8));
}

uint16_t read_le_sdram(Sim& sim, uint16_t addr) {
    return static_cast<uint16_t>(sim.probe(addr) | (static_cast<uint16_t>(sim.probe(addr + 1)) << 8));
}

void dump_basic_pointers(Sim& sim) {
    struct PtrDef {
        const char* name;
        uint16_t addr;
    } ptrs[] = {
        {"TXTTAB", 0x002B},
        {"VARTAB", 0x002D},
        {"ARYTAB", 0x002F},
        {"STREND", 0x0031},
        {"LOADPTR?", 0x00AC},
        {"PRGEND?", 0x00AE},
    };

    std::cout << "\n-- BASIC/ZP pointers --\n";
    for (const auto& ptr : ptrs) {
        const auto bram = read_le_bram(sim, ptr.addr);
        const auto sdram = read_le_sdram(sim, ptr.addr);
        std::cout << "  " << std::left << std::setw(8) << ptr.name
                  << std::right
                  << " BRAM=$" << std::hex << std::setw(4) << std::setfill('0') << bram
                  << " SDRAM=$" << std::setw(4) << sdram << std::dec << std::setfill(' ') << '\n';
    }
}

void wait_for_powerup_init_complete(Sim& sim, uint64_t max_cycles = 2'000'000) {
    if (!sim.top.status_powerup_busy) return;
    for (uint64_t i = 0; i < max_cycles && sim.running; ++i) {
        sim.tick();
        if (!sim.top.status_powerup_busy) {
            std::cout << "Power-up init completed after " << i + 1 << " half-cycles.\n";
            return;
        }
    }
    std::cerr << "warning: power-up init still busy after timeout\n";
}

void wait_for_injection_complete(Sim& sim, uint64_t max_cycles = 2'000'000) {
    if (!sim.top.status_inj_busy) return;
    for (uint64_t i = 0; i < max_cycles && sim.running; ++i) {
        sim.tick();
        if (!sim.top.status_inj_busy) {
            std::cout << "Injection meminit completed after " << i + 1 << " half-cycles.\n";
            return;
        }
    }
    std::cerr << "warning: injection meminit still busy after timeout\n";
}

std::vector<std::string> capture_text_screen(Sim& sim) {
    std::vector<std::string> rows;
    rows.reserve(25);
    for (int row = 0; row < 25; ++row) {
        std::ostringstream line;
        for (int col = 0; col < 40; ++col) {
            const auto addr = static_cast<uint16_t>(0x0400 + row * 40 + col);
            line << c64_screen_code_to_ascii(sim.probe_bram(addr));
        }
        rows.push_back(line.str());
    }
    return rows;
}

bool screen_has_ready(const std::vector<std::string>& rows) {
    for (const auto& row : rows) {
        if (row.find("READY") != std::string::npos) return true;
    }
    return false;
}

size_t count_nonzero_screen_bytes(Sim& sim) {
    size_t count = 0;
    for (uint16_t addr = 0x0400; addr <= 0x07e7; ++addr) {
        if (sim.probe_bram(addr) != 0) ++count;
    }
    return count;
}

void dump_text_screen(Sim& sim) {
    std::cout << "\n-- BRAM screen $0400..$07E7 (decoded screen codes) --\n";
    const auto rows = capture_text_screen(sim);
    for (const auto& row : rows) std::cout << row << '\n';
    std::cout << "screen_nonzero_bytes=" << count_nonzero_screen_bytes(sim)
              << " ready_detected=" << (screen_has_ready(rows) ? 1 : 0) << "\n";
    std::cout << "\n-- BRAM screen raw first 3 rows --\n";
    for (int row = 0; row < 3; ++row) {
        std::ostringstream label;
        label << "row " << row;
        dump_hex_block(label.str(), 0x0400 + row * 40, probe_range(sim, 0x0400 + row * 40, 40, true));
    }

    std::cout << "\n-- Editor / screen ZP state --\n";
    const auto pnt_lo = sim.probe_bram(0x00D1);
    const auto pnt_hi = sim.probe_bram(0x00D2);
    const auto pntr   = sim.probe_bram(0x00D3);
    const auto lnmx   = sim.probe_bram(0x00D5);
    const auto tblx   = sim.probe_bram(0x00D6);
    const auto hibase = sim.probe_bram(0x0288);
    const auto p01    = sim.probe_bram(0x0001);
    std::cout << std::hex << std::setfill('0');
    std::cout << "  $D1/$D2 (PNT)   = $" << std::setw(2) << static_cast<unsigned>(pnt_hi)
              << std::setw(2) << static_cast<unsigned>(pnt_lo) << "\n";
    std::cout << "  $D3 (PNTR col)  = $" << std::setw(2) << static_cast<unsigned>(pntr) << "\n";
    std::cout << "  $D5 (LNMX)      = $" << std::setw(2) << static_cast<unsigned>(lnmx) << "\n";
    std::cout << "  $D6 (TBLX row)  = $" << std::setw(2) << static_cast<unsigned>(tblx) << "\n";
    std::cout << "  $0288 (HIBASE)  = $" << std::setw(2) << static_cast<unsigned>(hibase) << "\n";
    std::cout << "  $0001 (PORT)    = $" << std::setw(2) << static_cast<unsigned>(p01) << "\n";
    std::cout << std::dec << std::setfill(' ');

    std::cout << "\n-- BRAM scan for any readable ASCII in bank-$00 pages $00-$07 --\n";
    for (int page = 0; page < 8; ++page) {
        int printable = 0;
        for (int off = 0; off < 256; ++off) {
            const uint8_t b = sim.probe_bram(static_cast<uint16_t>(page * 256 + off));
            if (b >= 0x20 && b <= 0x7e) printable++;
        }
        std::cout << "  page $" << std::hex << std::setw(2) << std::setfill('0') << page
                  << std::dec << std::setfill(' ')
                  << ": printable-ASCII bytes = " << printable << "\n";
    }
}

std::vector<uint8_t> load_chargen_mif(const std::string& path) {
    std::ifstream f(path);
    if (!f) throw std::runtime_error("chargen open: " + path);
    std::vector<uint8_t> data(4096, 0);
    std::string line;
    bool in_content = false;
    while (std::getline(f, line)) {
        const auto cc = line.find("--");
        if (cc != std::string::npos) line.resize(cc);
        if (line.find("CONTENT") != std::string::npos) { in_content = true; continue; }
        if (!in_content) continue;
        if (line.find("END") != std::string::npos) break;
        const auto colon = line.find(':');
        if (colon == std::string::npos) continue;
        const auto semi = line.find(';', colon);
        if (semi == std::string::npos) continue;
        auto addr_str = line.substr(0, colon);
        auto val_str = line.substr(colon + 1, semi - colon - 1);
        auto trim = [](std::string& s) {
            while (!s.empty() && std::isspace(static_cast<unsigned char>(s.front()))) s.erase(s.begin());
            while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back()))) s.pop_back();
        };
        trim(addr_str);
        trim(val_str);
        size_t val = 0;
        try { val = std::stoul(val_str, nullptr, 16); } catch (...) { continue; }
        size_t lo = 0, hi = 0;
        if (!addr_str.empty() && addr_str.front() == '[') {
            const auto dots = addr_str.find("..");
            if (dots == std::string::npos) continue;
            auto lo_s = addr_str.substr(1, dots - 1);
            auto hi_s = addr_str.substr(dots + 2);
            if (!hi_s.empty() && hi_s.back() == ']') hi_s.pop_back();
            trim(lo_s); trim(hi_s);
            try { lo = std::stoul(lo_s, nullptr, 16); hi = std::stoul(hi_s, nullptr, 16); }
            catch (...) { continue; }
        } else {
            try { lo = hi = std::stoul(addr_str, nullptr, 16); } catch (...) { continue; }
        }
        for (size_t a = lo; a <= hi && a < data.size(); ++a) data[a] = static_cast<uint8_t>(val);
    }
    return data;
}

bool render_text_screen_ppm(Sim& sim, const std::string& path, const std::string& chargen_path) {
    auto chars = load_chargen_mif(chargen_path);
    constexpr int kCols = 40;
    constexpr int kRows = 25;
    constexpr int kCharW = 8;
    constexpr int kCharH = 8;
    constexpr int kTextW = kCols * kCharW;  // 320
    constexpr int kTextH = kRows * kCharH;  // 200
    constexpr int kBorderW = 24;
    constexpr int kBorderH = 20;
    constexpr int kImgW = kTextW + 2 * kBorderW;  // 368
    constexpr int kImgH = kTextH + 2 * kBorderH;  // 240
    static const uint8_t kPaletteRGB[16][3] = {
        {0x00,0x00,0x00}, {0xff,0xff,0xff}, {0x68,0x37,0x2b}, {0x70,0xa4,0xb2},
        {0x6f,0x3d,0x86}, {0x58,0x8d,0x43}, {0x35,0x28,0x79}, {0xb8,0xc7,0x6f},
        {0x6f,0x4f,0x25}, {0x43,0x39,0x00}, {0x9a,0x67,0x59}, {0x44,0x44,0x44},
        {0x6c,0x6c,0x6c}, {0x9a,0xd2,0x84}, {0x6c,0x5e,0xb5}, {0x95,0x95,0x95}};
    const uint8_t bg = 6;    // dark blue
    const uint8_t fg = 14;   // light blue
    const uint8_t bd = 14;   // light blue border
    std::vector<uint8_t> img(kImgW * kImgH * 3, 0);
    auto put = [&](int x, int y, uint8_t c) {
        const uint8_t* rgb = kPaletteRGB[c & 0x0f];
        const size_t off = (y * kImgW + x) * 3;
        img[off + 0] = rgb[0];
        img[off + 1] = rgb[1];
        img[off + 2] = rgb[2];
    };
    for (int y = 0; y < kImgH; ++y)
        for (int x = 0; x < kImgW; ++x)
            put(x, y, bd);
    for (int r = 0; r < kRows; ++r) {
        for (int c = 0; c < kCols; ++c) {
            const uint8_t code = sim.probe_bram(static_cast<uint16_t>(0x0400 + r * kCols + c));
            for (int py = 0; py < kCharH; ++py) {
                const uint8_t row_bits = chars[code * kCharH + py];
                for (int px = 0; px < kCharW; ++px) {
                    const bool on = (row_bits >> (7 - px)) & 1;
                    put(kBorderW + c * kCharW + px,
                        kBorderH + r * kCharH + py,
                        on ? fg : bg);
                }
            }
        }
    }
    std::ofstream f(path, std::ios::binary);
    if (!f) return false;
    f << "P6\n" << kImgW << " " << kImgH << "\n255\n";
    f.write(reinterpret_cast<const char*>(img.data()), img.size());
    return static_cast<bool>(f);
}

void dump_prg_views(Sim& sim, const PrgInfo& prg, const std::string& tag, size_t bytes = 64) {
    const size_t dump_len = std::min(bytes, prg.payload.size());
    if (dump_len == 0) return;
    std::cout << "\n== " << tag << " ==\n";
    dump_basic_pointers(sim);
    dump_hex_block("SDRAM payload view", prg.load_addr, probe_range(sim, prg.load_addr, dump_len, false));
    dump_hex_block("BRAM payload view ", prg.load_addr, probe_range(sim, prg.load_addr, dump_len, true));
}

void log_status(Sim& sim, uint64_t step, const char* prefix) {
    const auto zp_c1 = sim.probe_bram(0x00c1);
    const auto zp_c2 = sim.probe_bram(0x00c2);
    const auto zp_0283 = sim.probe_bram(0x0283);
    const auto zp_0284 = sim.probe_bram(0x0284);
    const auto pc = static_cast<unsigned>(sim.top.dbg_pc);
    const char* phase = "other";
    if (pc >= 0xfce2 && pc <= 0xfd14) phase = "kernal_reset";
    else if (pc >= 0xfd15 && pc <= 0xfd4f) phase = "kernal_cint";
    else if (pc >= 0xfd50 && pc <= 0xfd8d) phase = "kernal_ramtas";
    else if (pc >= 0xfd8e && pc <= 0xfda2) phase = "kernal_restor";
    else if (pc >= 0xfda3 && pc <= 0xfddc) phase = "kernal_ioinit";
    else if (pc >= 0xe394 && pc <= 0xe3bf) phase = "basic_cold";
    else if (pc >= 0xe453) phase = "basic_ready";
    std::cout << prefix
              << " tick=" << step
              << " phase=" << phase
              << " cpu_addr=$" << std::hex << std::setw(4) << std::setfill('0') << static_cast<unsigned>(sim.top.dbg_addr)
              << " pbr=$" << std::setw(2) << static_cast<unsigned>(sim.top.dbg_pbr)
              << " ir=$" << std::setw(2) << static_cast<unsigned>(sim.top.dbg_ir)
              << " din=$" << std::setw(2) << static_cast<unsigned>(sim.top.dbg_data_in)
              << std::dec << std::setfill(' ')
              << " we=" << static_cast<unsigned>(sim.top.dbg_we)
              << " bus=" << static_cast<unsigned>(sim.top.cpu_has_bus)
              << " emul=" << static_cast<unsigned>(sim.top.supercpu_emul)
              << " scpu_cyc=" << static_cast<unsigned>(sim.top.supercpu_cycle)
              << " inj_busy=" << static_cast<unsigned>(sim.top.status_inj_busy)
              << " inval=" << static_cast<unsigned>(sim.top.status_bram_inval)
              << " screen_nz=" << count_nonzero_screen_bytes(sim)
              << " zp_c1=$" << std::hex << std::setw(2) << std::setfill('0') << static_cast<unsigned>(zp_c1)
              << " zp_c2=$" << std::setw(2) << static_cast<unsigned>(zp_c2)
              << " memtop=$" << std::setw(2) << static_cast<unsigned>(zp_0283)
              << std::setw(2) << static_cast<unsigned>(zp_0284)
              << " inj_end=$" << std::setw(4) << static_cast<unsigned>(sim.top.status_inj_end)
              << " scr_wr=$" << std::setw(4) << static_cast<unsigned>(sim.top.dbg_scr_wr_addr)
              << " scr_pc=$" << std::setw(4) << static_cast<unsigned>(sim.top.dbg_scr_wr_pc)
              << " scr_d=$" << std::setw(2) << static_cast<unsigned>(sim.top.dbg_scr_wr_data)
              << " scr_ir=$" << std::setw(2) << static_cast<unsigned>(sim.top.dbg_scr_wr_ir)
              << std::dec << std::setfill(' ')
              << " scr_zero=" << static_cast<unsigned>(sim.top.dbg_scr_zero_hit)
              << "\n";
}

struct Milestone {
    uint16_t pc;
    const char* name;
};

void run_cycles(Sim& sim, uint64_t cycles, const Options& opt,
                const std::optional<PrgInfo>& prg_info, const char* label) {
    std::cout << "Running " << cycles << " half-cycles for " << label << "...\n";

    static const Milestone kMilestones[] = {
        {0xfce2, "RESET"},
        {0xfd02, "check_cart"},
        {0xfd15, "RESTOR"},
        {0xfd50, "RAMTAS"},
        {0xfd76, "RAMTAS_stub_exit"},
        {0xfda3, "IOINIT"},
        {0xff5b, "CINT"},
        {0xe518, "editor_init"},
        {0xe544, "clrscr"},
        {0xfcfe, "RESET_CLI"},
        {0xfcff, "RESET_JMP_A000"},
        {0xe394, "BASIC_cold"},
        {0xe453, "BASIC_init"},
        {0xe3bf, "BASIC_var_init"},
        {0xe422, "BASIC_banner"},
        {0xa474, "BASIC_main"},
        {0xa483, "BASIC_ready"},
        {0xea31, "IRQ_entry"},
    };
    constexpr size_t kN = sizeof(kMilestones) / sizeof(kMilestones[0]);
    static std::array<uint64_t, kN> first_seen;
    static std::array<uint64_t, kN> hit_count;
    first_seen.fill(UINT64_MAX);
    hit_count.fill(0);
    uint64_t first_basic_rom_pc_tick = UINT64_MAX;
    uint16_t first_basic_rom_pc = 0;
    uint16_t prev_pc = 0xffff;

    constexpr size_t kRing = 128;
    std::array<std::pair<uint64_t, uint16_t>, kRing> pc_ring;
    size_t ring_head = 0;
    pc_ring.fill({UINT64_MAX, 0});

    for (uint64_t i = 0; i < cycles && sim.running; ++i) {
        sim.tick();

        const uint16_t pc = static_cast<uint16_t>(sim.top.dbg_pc);
        if (pc != prev_pc) {
            for (size_t m = 0; m < kN; ++m) {
                if (pc == kMilestones[m].pc) {
                    if (first_seen[m] == UINT64_MAX) {
                        first_seen[m] = i;
                        std::cout << "[milestone] tick=" << i << " pc=$"
                                  << std::hex << std::setw(4) << std::setfill('0') << pc
                                  << std::dec << std::setfill(' ')
                                  << " " << kMilestones[m].name << "\n";
                    }
                    ++hit_count[m];
                }
            }
            if (first_basic_rom_pc_tick == UINT64_MAX && pc >= 0xa000 && pc < 0xc000) {
                first_basic_rom_pc_tick = i;
                first_basic_rom_pc = pc;
                std::cout << "[milestone] tick=" << i << " pc=$"
                          << std::hex << std::setw(4) << std::setfill('0') << pc
                          << std::dec << std::setfill(' ')
                          << " first_basic_rom_exec\n";
            }
            pc_ring[ring_head] = {i, pc};
            ring_head = (ring_head + 1) % kRing;
            prev_pc = pc;
        }

        static unsigned last_scr_addr = 0xffffu;
        static unsigned last_scr_pc = 0xffffu;
        static unsigned last_scr_data = 0xffu;
        if (static_cast<unsigned>(sim.top.dbg_scr_wr_addr) != last_scr_addr ||
            static_cast<unsigned>(sim.top.dbg_scr_wr_pc) != last_scr_pc ||
            static_cast<unsigned>(sim.top.dbg_scr_wr_data) != last_scr_data) {
            last_scr_addr = static_cast<unsigned>(sim.top.dbg_scr_wr_addr);
            last_scr_pc = static_cast<unsigned>(sim.top.dbg_scr_wr_pc);
            last_scr_data = static_cast<unsigned>(sim.top.dbg_scr_wr_data);
            if (last_scr_addr >= 0x0400 && last_scr_addr <= 0x07ff) {
                std::cout << "[scr] tick=" << i
                          << " addr=$" << std::hex << std::setw(4) << std::setfill('0') << last_scr_addr
                          << " pc=$" << std::setw(4) << last_scr_pc
                          << " data=$" << std::setw(2) << last_scr_data
                          << " ir=$" << std::setw(2) << static_cast<unsigned>(sim.top.dbg_scr_wr_ir)
                          << std::dec << std::setfill(' ')
                          << " char='" << c64_screen_code_to_ascii(static_cast<uint8_t>(last_scr_data)) << "'\n";
            }
        }

        if (opt.log_every != 0 && ((i % opt.log_every) == 0 || i + 1 == cycles)) {
            log_status(sim, i, "[run]");
        }

        if (opt.snapshot_every != 0 && prg_info && ((i % opt.snapshot_every) == 0 || i + 1 == cycles)) {
            std::ostringstream tag;
            tag << label << " snapshot at tick " << i;
            dump_prg_views(sim, *prg_info, tag.str(), 32);
        }

        if (opt.stop_on_ready && opt.ready_poll_interval != 0
            && ((i % opt.ready_poll_interval) == 0 || i + 1 == cycles)) {
            const auto rows = capture_text_screen(sim);
            if (screen_has_ready(rows)) {
                std::cout << "READY detected on BRAM text screen at tick " << i << ".\n";
                break;
            }
        }
    }

    std::cout << "\n-- Milestone hit counts --\n";
    for (size_t m = 0; m < kN; ++m) {
        std::cout << "  " << std::left << std::setw(18) << kMilestones[m].name
                  << " hits=" << std::right << std::setw(6) << hit_count[m];
        if (first_seen[m] != UINT64_MAX) {
            std::cout << "  first_tick=" << first_seen[m];
        } else {
            std::cout << "  (never)";
        }
        std::cout << "\n";
    }
    if (first_basic_rom_pc_tick != UINT64_MAX) {
        std::cout << "  first_basic_rom_exec first_tick=" << first_basic_rom_pc_tick
                  << " pc=$" << std::hex << std::setw(4) << std::setfill('0')
                  << first_basic_rom_pc << std::dec << std::setfill(' ') << "\n";
    } else {
        std::cout << "  first_basic_rom_exec (never)\n";
    }

    std::cout << "\n-- Last " << kRing << " unique PCs (most recent last) --\n";
    for (size_t k = 0; k < kRing; ++k) {
        const auto& e = pc_ring[(ring_head + k) % kRing];
        if (e.first == UINT64_MAX) continue;
        std::cout << "  tick=" << std::setw(10) << e.first
                  << " pc=$" << std::hex << std::setw(4) << std::setfill('0') << e.second
                  << std::dec << std::setfill(' ') << "\n";
    }
    std::cout << std::left;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const Options opt = parse_args(argc, argv);

    try {
        auto rom = load_rom_image(opt.rom_path);
        if (opt.skip_ramtest) {
            if (patch_kernal_skip_ramtest(rom)) {
                std::cout << "KERNAL patch: RAMTAS replaced with fast stub "
                             "(MEMBOT=$0800 MEMSIZ=$A000 HIBASE=$04).\n";
            } else {
                std::cerr << "warning: --skip-ramtest requested but ROM signature "
                             "did not match at $FD50; running unpatched.\n";
            }
        }
        const auto prg_bytes = opt.prg_path ? read_binary_file(*opt.prg_path) : std::vector<uint8_t>{};
        const auto prg_info = opt.prg_path ? std::optional<PrgInfo>(decode_prg(prg_bytes)) : std::nullopt;
        Sim sim(!opt.headless, encode_powerup_init_mode(opt.powerup_init),
                opt.screenshot_path.has_value());

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
        wait_for_powerup_init_complete(sim);
        log_status(sim, 0, "[boot]");

        if (prg_info) {
            if (opt.prg_delay_cycles != 0) {
                run_cycles(sim, opt.prg_delay_cycles, opt, std::nullopt, "pre-injection delay");
            }

            std::cout << "Streaming PRG: " << *opt.prg_path
                      << " load=$" << std::hex << std::setw(4) << std::setfill('0') << prg_info->load_addr
                      << std::dec << std::setfill(' ') << " bytes=" << prg_info->payload.size() << "\n";
            sim.stream_prg(prg_bytes);
            wait_for_injection_complete(sim);
            log_status(sim, 0, "[post-prg]");
            dump_prg_views(sim, *prg_info, "After PRG inject + meminit");
        }

        run_cycles(sim, opt.cycles, opt, prg_info, "main run");

        if (prg_info) {
            dump_prg_views(sim, *prg_info, "Final PRG state");
        }
        dump_text_screen(sim);

        sim.raster.dump_stats();

        if (opt.screenshot_path) {
            if (sim.raster.save_ppm(*opt.screenshot_path)) {
                std::cout << "Screenshot written to " << *opt.screenshot_path
                          << " (" << Rasterizer::kWidth << "x" << Rasterizer::kHeight << " PPM).\n";
            } else {
                std::cerr << "warning: failed to write screenshot to " << *opt.screenshot_path << "\n";
            }
        }

        if (opt.text_screenshot_path) {
            try {
                if (render_text_screen_ppm(sim, *opt.text_screenshot_path, opt.chargen_path)) {
                    std::cout << "Text-mode screenshot written to " << *opt.text_screenshot_path
                              << " (368x240 PPM).\n";
                } else {
                    std::cerr << "warning: failed to write text screenshot\n";
                }
            } catch (const std::exception& e) {
                std::cerr << "warning: text screenshot: " << e.what() << "\n";
            }
        }

        sim.top.final();
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "fatal: " << e.what() << "\n";
        return 1;
    }
}

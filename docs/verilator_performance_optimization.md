# Verilator / Build Performance Optimization Notes

Date: 2026-04-17

This document captures practical ways to make the desktop C64 harness workflow faster on a high-end machine with:
- RTX 5090 GPU
- 12-core CPU
- 96 GB RAM

The main conclusion is:

> For this project, the biggest gains come from CPU, filesystem, linker, caching, and reduced debug overhead.
> The GPU is generally **not** the main accelerator for GHDL/Verilator/C++ build or RTL simulation.

---

## 1. Reality check: what uses GPU vs CPU

### CPU-bound tasks
These are the main heavy steps in the current workflow and are primarily CPU-bound:
- `ghdl --synth --out=verilog`
- Verilator translation/elaboration
- generated C++ compilation
- linking the Verilated executable
- normal Verilator RTL simulation runtime

### GPU relevance
The RTX 5090 is **not expected to materially speed up**:
- GHDL synthesis
- Verilator code generation
- C++ compilation
- standard Verilator simulation

Possible GPU uses are only indirect, such as:
- external visualization tools
- SDL/rendering overhead outside core simulation
- AI/research/tooling support around development

For the actual harness, prioritize CPU/RAM/filesystem work first.

---

## 2. Highest-value likely wins

The most promising optimization levers are:

1. **Build from WSL native ext4, not `/mnt/c`**
2. **Use more compile parallelism**
3. **Create a fast/no-trace runtime build mode**
4. **Try Verilator multithreading**
5. **Put `obj_dir` and generated files on tmpfs/RAM disk**
6. **Use `ccache` or `sccache`**
7. **Use a faster linker (`mold` or `lld`)**
8. **Benchmark GCC vs Clang**
9. **Reduce host-side logging/probe overhead during long runs**

---

## 3. Move builds off `/mnt/c`

If the repo is built from a Windows-mounted path like:

```bash
/mnt/c/LLM/C64/MiSTerSuperCPU
```

then build performance is often much worse than from WSL native storage.

### Recommendation
Use a WSL-local clone, for example:

```bash
mkdir -p ~/src
cd ~/src
git clone <repo> MiSTerSuperCPU
```

or mirror the existing repo into WSL-native storage.

### Why this matters
DrvFS (`/mnt/c`) is slow for metadata-heavy workloads involving many small files.
Verilator builds generate and compile many such files in `obj_dir/`.

### Expected benefit
Often one of the biggest build-time improvements available.

---

## 4. Use more CPU during compile

The project machine has a 12-core CPU, likely with SMT/hyperthreading.
That means compilation should make better use of available cores.

### Recommendation
Parameterize job count in the Makefiles:

```make
JOBS ?= 24
...
$(MAKE) -C obj_dir -f V$(TOP).mk -j$(JOBS) V$(TOP)
```

Then test:
- `JOBS=12`
- `JOBS=16`
- `JOBS=20`
- `JOBS=24`

### Notes
- Build scaling is usually good for generated C++ compile.
- Watch RAM usage and diminishing returns.
- This helps build time, not necessarily simulation runtime.

---

## 5. Create separate debug and fast simulation modes

Current harnesses mix useful debug features with normal execution. For long boot tests, a lighter binary should run faster.

### Debug mode
Keep for development:
- tracing support
- SDL support
- verbose logs
- extra probes
- screen dumps

### Fast mode
Use for long runs:
- no trace support compiled in
- no SDL if not needed
- reduced host logging
- fewer expensive probe scans
- aggressive optimization flags

### Suggested Makefile pattern
```make
FAST ?= 0
VL_THREADS ?= 1

ifeq ($(FAST),1)
  CXXFLAGS += -O3 -march=native -mtune=native -DNDEBUG
  VERILATOR_FLAGS := --language 1364-2001 -Wno-fatal --x-assign fast --x-initial fast --threads $(VL_THREADS)
else
  CXXFLAGS += -O2
  VERILATOR_FLAGS := --language 1364-2001 -Wno-fatal --x-assign fast --x-initial fast --trace-fst --threads $(VL_THREADS)
endif
```

### Important point
Even if trace output is not written at runtime, compiling trace support into the binary still increases build complexity and may hurt runtime somewhat.

---

## 6. Try Verilator multithreading

Verilator can use multiple CPU threads during simulation if the design partitions well enough.

### Recommendation
Benchmark simulation runtime with:
- `VL_THREADS=1`
- `VL_THREADS=2`
- `VL_THREADS=4`
- `VL_THREADS=8`

Example:
```make
VERILATOR_FLAGS += --threads $(VL_THREADS)
```

### Caveats
- Scaling is design-dependent.
- Some designs benefit a lot; some do not.
- 2–4 threads may be the best point even on a larger CPU.

### Expected benefit
Potential runtime improvement, but must be measured.

---

## 7. Use RAM-backed storage for build artifacts

With 96 GB RAM, it is practical to place high-churn build directories on tmpfs.

### Good candidates
- `obj_dir/`
- `flow/generated/`
- possibly `flow/build_staging/`

### Example using `/dev/shm`
```bash
mkdir -p /dev/shm/verilator_c64_vanilla_obj
mkdir -p /dev/shm/verilator_c64_vanilla_gen
```

Then make the build configurable:

```make
OBJ_DIR ?= obj_dir
GENERATED_DIR ?= flow/generated
BIN := $(OBJ_DIR)/V$(TOP)
```

Run with:

```bash
make OBJ_DIR=/dev/shm/verilator_c64_vanilla_obj GENERATED_DIR=/dev/shm/verilator_c64_vanilla_gen
```

### Expected benefit
Mostly improves build iteration speed, especially file-heavy rebuilds.
Runtime improvement is usually smaller.

---

## 8. Use `ccache` or `sccache`

Incremental rebuild speed can improve significantly with a compiler cache.

### Install
```bash
sudo apt install ccache
```

### Example usage
```bash
export CC="ccache gcc"
export CXX="ccache g++"
```

Or directly in the Makefile:

```make
CXX := ccache g++
```

### Notes
This is especially helpful when:
- host code changes often
- generated code is stable across repeated builds
- similar rebuilds happen frequently

---

## 9. Use a faster linker

Large Verilator-generated binaries can spend significant time in linking.

### Best candidates
- `mold`
- `lld`

### Recommended first try: `mold`
```bash
sudo apt install mold
```

Add:
```make
LDFLAGS += -fuse-ld=mold
```

### Alternative: `lld`
```make
LDFLAGS += -fuse-ld=lld
```

### Expected benefit
Mostly reduces build/link time, not simulation runtime.

---

## 10. Benchmark GCC vs Clang

For generated Verilator C++, either compiler may win depending on the code and toolchain version.

### Test matrix
Benchmark combinations like:
- GCC + mold
- GCC + LTO
- Clang + lld
- Clang + LTO

### Possible flags
```make
CXXFLAGS += -O3 -march=native -mtune=native
```

### Recommendation
Do not assume one is best; measure wallclock build time and sim runtime.

---

## 11. Reduce host-side logging and probing for long runs

Host diagnostics are useful, but they can add nontrivial overhead during long simulations.

### Potential runtime costs
- repeated BRAM probing
- full-screen nonzero counts every log interval
- frequent formatted `std::cout`
- decoded screen dumps
- snapshot generation during run

### Recommendation
For long-run speed mode:
- log less often
- avoid full screen scans except at the end
- avoid expensive status probes inside tight logging loops
- make debug-heavy features conditional on a fast/debug mode switch

### Example
Only compute `screen_nonzero_bytes`:
- at final dump
- or every few million cycles
- not at every status print

---

## 12. Consider a stripped wrapper for speed runs

The existing wrapper exposes many debug/status paths. That is ideal for debugging, but not necessarily for max throughput.

### Speed-run wrapper idea
A separate wrapper or build profile with:
- essential ROM/PRG injection only
- minimal debug outputs
- no screen-write tracing
- no extra probes except final-state inspection

### Benefit
This may improve runtime speed modestly, especially when paired with a quiet host.

---

## 13. Tune WSL resource allocation

Make sure WSL2 is allowed to use enough CPU and memory.

### Example `.wslconfig`
In the Windows user profile:

```ini
[wsl2]
memory=64GB
processors=12
swap=16GB
localhostForwarding=true
```

Then restart WSL:

```powershell
wsl --shutdown
```

### Notes
- Do not starve Windows completely.
- If tmpfs is used heavily, ensure WSL has enough RAM budget.

---

## 14. LTO and PGO

### LTO
Link-time optimization can sometimes improve runtime speed of the final simulator.

Example:
```make
CXXFLAGS += -flto
LDFLAGS += -flto
```

Tradeoff:
- slower builds
- potentially faster runtime

### PGO
Profile-guided optimization may help if the same harness is run frequently with similar workloads.

Recommended only if the harness becomes a long-term daily tool, since setup complexity is higher.

---

## 15. What is most likely to help simulation runtime?

Most promising runtime-speed levers:
1. no-trace fast binary
2. reduced host logging/probe overhead
3. Verilator `--threads` benchmarking
4. `-O3 -march=native`
5. possibly LTO

Least likely to help runtime meaningfully:
- moving to RAM disk alone
- GPU involvement
- exotic system tuning without measurement

---

## 16. Recommended optimization experiment order

### Phase 1: easiest / highest confidence
1. Move build to WSL ext4
2. Add `JOBS ?=` and test `-j` values
3. Add `ccache`
4. Add `mold`
5. Put `obj_dir` on `/dev/shm`

### Phase 2: runtime-focused
6. Add `FAST=1` mode without trace support
7. Reduce host logging/probing in fast mode
8. Benchmark `VL_THREADS=1/2/4/8`

### Phase 3: compiler tuning
9. Benchmark GCC vs Clang
10. Try `-O3 -march=native`
11. Try LTO

### Phase 4: advanced
12. Consider stripped speed wrapper
13. Consider PGO

---

## 17. Concrete recommended next implementation set

If only a few changes are made first, the recommended set is:

1. **Build from WSL-native filesystem**
2. **Parameterize compile jobs (`JOBS ?= 24`)**
3. **Add `FAST=1` mode removing trace support**
4. **Add `VL_THREADS ?=` and benchmark 1/2/4/8**
5. **Use `mold` linker**
6. **Use `ccache`**
7. **Allow `OBJ_DIR`/`GENERATED_DIR` to live on tmpfs**

That should provide the best practical speedup per unit of effort.

---

## 18. Summary

For this project, the main speed strategy should be:
- maximize CPU usage during compile
- reduce filesystem overhead
- reduce simulation overhead in speed runs
- exploit RAM for build artifacts
- benchmark multithreaded Verilator

The 5090 GPU is excellent hardware, but for this particular GHDL/Verilator/C++ workflow it is not the primary accelerator.

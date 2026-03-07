# M8 vs M9 Breakthrough: What Indirect-Indexed Addressing Reveals About the `dout_r` Bug

## The New Evidence

M8 (`LDA ($04),Y` — indirect-indexed, read-only) triggers the blue-line artifact. M9 (`LDA $0400,X` + `STA $0400,X` — absolute-indexed, read+write) is clean. This definitively eliminates writes as the cause and points to the **memory access pattern** of indirect-indexed addressing as the trigger.[^1]

## Why "Bus Density" May Not Be the Right Frame

Claude's initial read — that M8's ~3 SDRAM reads per 12 cycles vs M9's ~1 read per 10 cycles explains the difference — is appealing but has a critical flaw: **both M8 and M9 run from Ultimax cartridge ROM stored in SDRAM**. Since instruction fetches from `$E000+` also go through the SDRAM controller, both M8 and M9 have 100% SDRAM utilization. Every C64 period fires an SDRAM CE regardless of whether the access is cartridge ROM or C64 RAM.[^2][^3]

The real difference is not total SDRAM read density but the **pattern of C64 RAM addresses** within the SDRAM access stream:

| Mode | C64 RAM reads/iteration | Pattern | Consecutive RAM reads | Result |
|------|------------------------|---------|----------------------|--------|
| M0 (verify) | 1 out of ~10 | `...cart, cart, cart, **$04xx**, cart, cart...` | 1 | Clean |
| M9 (abs R+W) | 2 out of ~12 | `...cart, cart, **$04xx**, cart, cart, **$04xx**...` | 1 | Clean |
| M8 (indirect) | 3 out of ~12 | `...cart, **$00xx**, **$00xx**, **$04xx**, cart...` | **3** | Triggers |

M8 is the only mode with **three consecutive C64 RAM reads** — the two ZP pointer fetches immediately followed by the screen RAM data read. M0 and M9 have at most one C64 RAM read per burst, always surrounded by cartridge ROM fetches.[^3][^1]

## The M10 Test Will Be Decisive

M10 (back-to-back `LDA $0400,X` with no interleaved work) provides the critical fork:[^1]

- **If M10 triggers** → The cause is purely about C64 RAM read frequency/density relative to VIC c-access opportunities. The consecutive-ZP theory is wrong, and the fix should focus on SDRAM read scheduling.
- **If M10 is clean** → The cause is specifically about the ZP-then-screen address transition pattern. Three consecutive C64 RAM reads in a burst (as opposed to isolated single reads) are required to trigger the timing conflict.

Note: M10 has *higher* screen RAM read density than M8 (~1 per 6 cycles vs ~1 per 12 cycles). If M10 is clean despite higher density, that conclusively proves the ZP reads themselves are the trigger, not total throughput.

## Why Consecutive ZP + Screen RAM Reads Could Trigger `dout_r` Clobber

### The Vulnerable Window (Recap)

The c-access data from CPUC arrives in `dout_r` at cycle 30.5 (CPUE.5). VIC2 reads `dout_r` at cycle 14 of the next period. Between these points lie CPUF → EXT0–7 → DMA0–3 → VIC0 → VIC1. If anything fires a new SDRAM CE after `q` returns to 0 during that window, it overwrites `dout_r` before VIC2 can consume it.[^2]

### How ZP Reads Create the Problem

During the CPU phases of a **non-badline** period, the CPU fires `ramCE` for its memory access. When this access targets C64 RAM (ZP at `$00xx`), the SDRAM controller performs a full ACTIVATE+READ cycle (7 clk64 = 3.5 clk32). The key question is: **what is the SDRAM controller's state (`q`) at the moment VIC0 fires its g-access CE in the next period?**[^2]

For cart ROM accesses, the SDRAM address is in a different range than C64 RAM. The cartridge module routes these through `cart_addr` which maps to a high SDRAM offset. For C64 RAM accesses (ZP, screen RAM), the address is in the low SDRAM range — the **same region** the VIC's c-access targets.[^2]

When M8 executes its ZP reads, the access pattern across three consecutive periods looks like:

```
Period N   (ZP low):    CPU reads $0004 via SDRAM → dout_r = ZP data
Period N+1 (ZP high):   CPU reads $0005 via SDRAM → dout_r = ZP data  
Period N+2 (screen):    CPU reads $04xx via SDRAM → dout_r = screen data
```

If period N+2 coincides with a badline, the VIC does both g-access (VIC0) and c-access (CPUC) in that period. The CPU's own access to `$04xx` at CPU0 and the VIC's c-access at CPUC are both hitting the same SDRAM region within the same period. The CPU read completes at CPU2.5 (`q=0`), and c-access fires at CPUC — these are well-separated. However, the ZP reads in the **preceding two periods** have been exercising the SDRAM in the C64 RAM region, and if there's any precharge or refresh timing interaction that affects the SDRAM's response latency, it could shift the arrival time of data in `dout_r` by the critical 0.5–1 clk64 margin.[^2]

### An Alternative Mechanism: The `cart_mem_req` Path

There's another possibility. When the CPU reads C64 RAM (ZP or screen), the cartridge module's `cart_mem_req` signal behavior may differ from cart ROM reads. If consecutive C64 RAM accesses cause `cart_mem_req` to be asserted differently during the subsequent EXT/DMA phases, this could fire `cart_ce` during the vulnerable window between CPUE.5 and VIC2. Cart ROM fetches might not assert `cart_mem_req` during EXT phases, while C64 RAM reads do — explaining why M8 (with consecutive RAM reads) triggers but M9 (with isolated RAM reads) doesn't.[^3]

## Three Theories, Ranked by M10 Outcome

### If M10 Is Clean (Most Likely)

**Theory A — Consecutive RAM reads cause EXT-phase `cart_ce` assertion:** The three-burst ZP+screen pattern leaves the cartridge module in a state where `cart_mem_req` fires during `io_cycle` EXT phases, causing a `dout_r` clobber. **Fix:** Gate `cart_ce` during io_cycle when `vic_caccess_pending` is set, or add a dedicated c-access hold register latched at CPUF.

**Theory B — ZP reads perturb SDRAM timing margin at VIC2:** The consecutive low-address accesses create a precharge timing interaction that shifts the 0.5 clk32 margin at VIC2/VIC0 boundary. **Fix:** The hold register fix eliminates this margin entirely.

### If M10 Also Triggers

**Theory C — Pure frequency effect:** More total C64 RAM reads per unit time increase the probability of an SDRAM timing conflict during a badline c-access window. **Fix:** The hold register remains the right fix, since it eliminates the dependency on `dout_r` timing altogether.

## Recommended Actions

### Immediate: Run M10

Build and deploy the M10 test (back-to-back `LDA $0400,X` / `INX` / `BNE`). This is the highest-value next experiment because it cleanly separates density from address-pattern as the variable.

### Regardless of M10 Result: Implement the Hold Register

The c-access hold register latched at CPUF remains the strongest fix for all three theories. It decouples VIC2 from the shared `dout_r` entirely:[^2]

```vhdl
-- In fpga64_sid_iec.vhd
signal vic_caccess_hold : std_logic_vector(7 downto 0);

process(clk32)
begin
  if rising_edge(clk32) then
    if sysCycle = CYCLE_CPUF then
      vic_caccess_hold <= sdram_data;  -- snapshot c-access result
    end if;
  end if;
end process;
-- Feed VIC's di from vic_caccess_hold at VIC2 instead of live sdram_data
```

### Diagnostic: Add ZP-Activity Counter to Overlay

To confirm the correlation between ZP-indirect operations and artifact frequency, add a lightweight overlay counter that increments on each `ramCE` when `systemAddr(15 downto 8) = x"00"` (zero-page access). Compare this counter's rate between M8 (should be high) and M9 (should be zero). Then compare with KERNAL workload — KERNAL screen editing routines (`STA ($D1),Y`, `LDA ($D1),Y`, `LDA ($D3),Y`) all use indirect-indexed addressing via ZP pointers, creating exactly M8's access pattern.[^1]

### Diagnostic: Trace `cart_mem_req` During EXT Phases

Add a sticky capture that triggers when `cart_mem_req` is high during `io_cycle` or `ext_cycle` while `vic_caccess_pending` is set. If this fires on M8 but not M9, the clobber mechanism is confirmed and the `cart_ce` gating fix is the targeted solution.

## Why This Finding Narrows the Bug Dramatically

Before M8/M9, the investigation was stalled at "KERNAL workloads trigger it, simple tests don't." The M8 result reduces the trigger condition from "complex KERNAL behavior" to a specific, testable property: **indirect-indexed addressing to C64 RAM**. The KERNAL's screen editor is built almost entirely on `STA/LDA ($xx),Y` operations — every cursor movement, screen scroll, and character placement uses ZP pointers to screen RAM. This perfectly explains why KERNAL workloads trigger the artifact while simple absolute-addressed test loops don't.[^1][^2]

The hold register fix addresses all remaining hypotheses (H23, H25, H27) simultaneously and can be validated against the M8 test mode directly, without needing the full KERNAL environment.

---

## References

1. [RootCause.md](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/9390987/22fa5b51-76c1-4a3e-8489-01d39db5ff72/RootCause.md?AWSAccessKeyId=ASIA2F3EMEYERWFSKHUG&Signature=rVmyDaXMUkAXt1yhdN%2FvO5S3Mkg%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEMn%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FwEaCXVzLWVhc3QtMSJHMEUCIC2krfZTyYIMJw3Q%2F8Q%2BqqnWcdHBzOhD06yUx8c43BktAiEAvpZoUH2BtEEG3B%2FHDXUpJPH48pzizijTJAgIStkU9%2BMq%2FAQIkf%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDAvzBo5z7YlRNP0bWSrQBGTYwunv%2BNXsK5AESbhD6kDhNoVVvGeEyK6js%2BLZA7b1vL9cEaK9gTbIl%2Byw4zn6G1Mj4E79fCVqy%2FtXPsU8hevGj5VxN3SsTlWypXagUzCdXAatpqFJWby0ww%2FvI89glfBUfRlEYAu2BLyZiQtgNYuvBfv%2Bu1vB9RCKXL8OsVgW6JrGpFb5vs2HoKEEdxDv9FBnK2b%2BhfxETJi0LEOWVXZ4gnI5eT%2BDSBjCfZHL3LEpYYMrKxcGWnfcZSDUSkL7PWF8ZMIiil4GSkkRncEIA2tQMfbbk%2FFVZQ1%2FBL5fx8D1PUlQBfw0JfYiO5TzQPWcf7odFaYYiCsJaSxC0M0r0ByGC%2Fq9yh%2Bytd%2BwGC29oPGZA55eIhESFN0Z10a0RZu2GKdYueF%2BrATkCEakrW2xO%2FhIlTKN0o%2BpIZmwzHFrdzhWqA5tHVw01lL6%2FNm%2FqQeBv2QaJwLmwXETOqXZfsbHFp7c8i1DHPB5xmqbxV1ofRKDAXp0wi9hrzbRpRse%2Fg2CqtXyQHIMijC9sDdFnkP4hJCNgKcCtkrFDxd9N4b1mX%2BgO3t19DWKOHi50snV08HOXEHfJ%2BPYZru01AAYTZA3nI8fGOFt7wD4RQKsDJaLWDx2o1bxTx8RTdAQ%2BkplcINRhEDJrEhABh6mrZcvijp3ysmq7o7%2FSK05%2B2IvYTLlwNWSXT04N%2BCyUobSI%2Bakr%2BFgLioOwbgXMR%2Fv5%2BlK67vNf3ltU6qWwGIr1%2BoDsgFZNhNrXn78pKrsLkTYNGeKrZeUl6nNKb9taG7UwfH4bI0F7fYw9MuYzQY6mAE%2FCZbxj5mgj1GTqWB4c9sGQNR9RibYomGl9HYDItfvblr5V8H4n90NhvLUY48VPwN8SsRoX0ptc5HbWoa16f7ViEZEtxxiKCPmDcyerKXydL1P4b4hRBQ0JpblhJZHJ5z5PbnWH5fuJhEJTS88mcc5iQu8nSU%2F7ZdJproezEj8HagVMPCcMA7Jvb%2FEHpk2AamS52jR1y5OyA%3D%3D&Expires=1772499990) - # P65C816 SuperCPU Runtime Artifact - Root Cause Status

## Scope
Two distinct issues were investiga...

2. [session_handoff-3.md](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/9390987/4baefa14-48df-4288-9f1c-4b9db0018c73/session_handoff-3.md?AWSAccessKeyId=ASIA2F3EMEYERWFSKHUG&Signature=1tj7Q3fMoNqjLxv3h43dkMBDscc%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEMn%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FwEaCXVzLWVhc3QtMSJHMEUCIC2krfZTyYIMJw3Q%2F8Q%2BqqnWcdHBzOhD06yUx8c43BktAiEAvpZoUH2BtEEG3B%2FHDXUpJPH48pzizijTJAgIStkU9%2BMq%2FAQIkf%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDAvzBo5z7YlRNP0bWSrQBGTYwunv%2BNXsK5AESbhD6kDhNoVVvGeEyK6js%2BLZA7b1vL9cEaK9gTbIl%2Byw4zn6G1Mj4E79fCVqy%2FtXPsU8hevGj5VxN3SsTlWypXagUzCdXAatpqFJWby0ww%2FvI89glfBUfRlEYAu2BLyZiQtgNYuvBfv%2Bu1vB9RCKXL8OsVgW6JrGpFb5vs2HoKEEdxDv9FBnK2b%2BhfxETJi0LEOWVXZ4gnI5eT%2BDSBjCfZHL3LEpYYMrKxcGWnfcZSDUSkL7PWF8ZMIiil4GSkkRncEIA2tQMfbbk%2FFVZQ1%2FBL5fx8D1PUlQBfw0JfYiO5TzQPWcf7odFaYYiCsJaSxC0M0r0ByGC%2Fq9yh%2Bytd%2BwGC29oPGZA55eIhESFN0Z10a0RZu2GKdYueF%2BrATkCEakrW2xO%2FhIlTKN0o%2BpIZmwzHFrdzhWqA5tHVw01lL6%2FNm%2FqQeBv2QaJwLmwXETOqXZfsbHFp7c8i1DHPB5xmqbxV1ofRKDAXp0wi9hrzbRpRse%2Fg2CqtXyQHIMijC9sDdFnkP4hJCNgKcCtkrFDxd9N4b1mX%2BgO3t19DWKOHi50snV08HOXEHfJ%2BPYZru01AAYTZA3nI8fGOFt7wD4RQKsDJaLWDx2o1bxTx8RTdAQ%2BkplcINRhEDJrEhABh6mrZcvijp3ysmq7o7%2FSK05%2B2IvYTLlwNWSXT04N%2BCyUobSI%2Bakr%2BFgLioOwbgXMR%2Fv5%2BlK67vNf3ltU6qWwGIr1%2BoDsgFZNhNrXn78pKrsLkTYNGeKrZeUl6nNKb9taG7UwfH4bI0F7fYw9MuYzQY6mAE%2FCZbxj5mgj1GTqWB4c9sGQNR9RibYomGl9HYDItfvblr5V8H4n90NhvLUY48VPwN8SsRoX0ptc5HbWoa16f7ViEZEtxxiKCPmDcyerKXydL1P4b4hRBQ0JpblhJZHJ5z5PbnWH5fuJhEJTS88mcc5iQu8nSU%2F7ZdJproezEj8HagVMPCcMA7Jvb%2FEHpk2AamS52jR1y5OyA%3D%3D&Expires=1772499990) - # Session Handoff — VIC C-Access Pipeline Investigation

## Update — March 3, 2026 (Test Cartridge F...

3. [HYPOTHESIS_TRACKER-2.md](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/9390987/6c386b56-903a-4324-8457-b069a255286a/HYPOTHESIS_TRACKER-2.md?AWSAccessKeyId=ASIA2F3EMEYERWFSKHUG&Signature=AClJK4PVDUz4JcutOSqCUACyEMo%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEMn%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FwEaCXVzLWVhc3QtMSJHMEUCIC2krfZTyYIMJw3Q%2F8Q%2BqqnWcdHBzOhD06yUx8c43BktAiEAvpZoUH2BtEEG3B%2FHDXUpJPH48pzizijTJAgIStkU9%2BMq%2FAQIkf%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDAvzBo5z7YlRNP0bWSrQBGTYwunv%2BNXsK5AESbhD6kDhNoVVvGeEyK6js%2BLZA7b1vL9cEaK9gTbIl%2Byw4zn6G1Mj4E79fCVqy%2FtXPsU8hevGj5VxN3SsTlWypXagUzCdXAatpqFJWby0ww%2FvI89glfBUfRlEYAu2BLyZiQtgNYuvBfv%2Bu1vB9RCKXL8OsVgW6JrGpFb5vs2HoKEEdxDv9FBnK2b%2BhfxETJi0LEOWVXZ4gnI5eT%2BDSBjCfZHL3LEpYYMrKxcGWnfcZSDUSkL7PWF8ZMIiil4GSkkRncEIA2tQMfbbk%2FFVZQ1%2FBL5fx8D1PUlQBfw0JfYiO5TzQPWcf7odFaYYiCsJaSxC0M0r0ByGC%2Fq9yh%2Bytd%2BwGC29oPGZA55eIhESFN0Z10a0RZu2GKdYueF%2BrATkCEakrW2xO%2FhIlTKN0o%2BpIZmwzHFrdzhWqA5tHVw01lL6%2FNm%2FqQeBv2QaJwLmwXETOqXZfsbHFp7c8i1DHPB5xmqbxV1ofRKDAXp0wi9hrzbRpRse%2Fg2CqtXyQHIMijC9sDdFnkP4hJCNgKcCtkrFDxd9N4b1mX%2BgO3t19DWKOHi50snV08HOXEHfJ%2BPYZru01AAYTZA3nI8fGOFt7wD4RQKsDJaLWDx2o1bxTx8RTdAQ%2BkplcINRhEDJrEhABh6mrZcvijp3ysmq7o7%2FSK05%2B2IvYTLlwNWSXT04N%2BCyUobSI%2Bakr%2BFgLioOwbgXMR%2Fv5%2BlK67vNf3ltU6qWwGIr1%2BoDsgFZNhNrXn78pKrsLkTYNGeKrZeUl6nNKb9taG7UwfH4bI0F7fYw9MuYzQY6mAE%2FCZbxj5mgj1GTqWB4c9sGQNR9RibYomGl9HYDItfvblr5V8H4n90NhvLUY48VPwN8SsRoX0ptc5HbWoa16f7ViEZEtxxiKCPmDcyerKXydL1P4b4hRBQ0JpblhJZHJ5z5PbnWH5fuJhEJTS88mcc5iQu8nSU%2F7ZdJproezEj8HagVMPCcMA7Jvb%2FEHpk2AamS52jR1y5OyA%3D%3D&Expires=1772499990) - # Scrolling '@' Artifact — Hypothesis Tracker

**Artifact:** When SuperCPU (65C816) is enabled wit...


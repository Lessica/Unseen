#include "patchfinder.h"
#include "dobby.h"
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <string.h>
#include <os/log.h>

static os_log_t get_logger(void) {
    static os_log_t logger;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        logger = os_log_create("com.82flex.layerpropresearch", "patchfinder");
    });
    return logger;
}

/// Resolve prepare_layer0 using DobbySymbolResolver (handles local DSC symbols).
static void *resolve_prepare_layer0(void) {
    os_log_t log = get_logger();

    const char *image = "/System/Library/Frameworks/QuartzCore.framework/QuartzCore";

    // Mangled symbol candidates (non-const and const Layer* variants)
    const char *candidates[] = {
        "__ZN2CA6Render7Updater14prepare_layer0ERNS1_11GlobalStateEPNS0_9LayerNodeEPNS0_5LayerERNS1_11LocalState0Ey",
        "__ZN2CA6Render7Updater14prepare_layer0ERNS1_11GlobalStateEPNS0_9LayerNodeEPKNS0_5LayerERNS1_11LocalState0Ey",
    };

    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        void *sym = DobbySymbolResolver(image, candidates[i]);
        if (sym) {
            os_log(log, "Resolved prepare_layer0 via DobbySymbolResolver: %p", sym);
            return sym;
        }
    }

    os_log_error(log, "Could not resolve prepare_layer0 symbol");
    return NULL;
}

/// Check if a 32-bit instruction word is TST Xn, #<mask> where mask covers
/// the disableUpdateMask bitfield (bits 20-26 or 20-27 depending on version).
///
/// We match:
///   TST Xn, #0x7F00000  (7-bit field, iOS 18+): imms=6
///   TST Xn, #0xFF00000  (8-bit field, iOS 16): imms=7
///
/// Both share: sf=1, opc=11, fixed=100100, N=1, immr=44(0x2C), Rd=11111(XZR)
/// Difference is only imms (bits 15:10): 000110 vs 000111
///
/// Mask out Rn (bits 9:5) and imms bit0 (bit 10):
///   Fixed bits: 0xF26C1C1F with imms[5:1]=00011 (bits 15:11)
///   We check: (insn & 0xFFFFFC1F) & ~(1<<10) matches 0xF26C181F & ~(1<<10) = 0xF26C181F
///   Actually simpler: mask = 0xFFFFF81F (mask out Rn[9:5] and imms[12:10])
///   Then value = sf=1,opc=11,100100,N=1,immr=101100,imms_hi=000_xxx = 0xF26C001F
///   Nah, let's just check both values explicitly.
static inline int is_tst_xn_disableUpdateMask(uint32_t insn) {
    uint32_t masked = insn & 0xFFFFFC1F;  // mask out Rn (bits 9:5)
    // imms=6 (0x7F00000, 7-bit mask): 0xF26C181F with Rn=0
    // imms=7 (0xFF00000, 8-bit mask): 0xF26C1C1F with Rn=0
    return masked == 0xF26C181F || masked == 0xF26C1C1F;
}

/// Check if a 32-bit instruction word is B.NE (b.cond with cond=NE=0001).
///
/// Encoding: 0101 0100 imm19 0 0001
///   bits[31:24] = 0x54, bits[4] = 0, bits[3:0] = 0x1
static inline int is_b_ne(uint32_t insn) {
    return (insn & 0xFF00001F) == 0x54000001;
}

void *find_disableUpdateMask_branch(void) {
    os_log_t log = get_logger();

    // Step 1: Resolve the function symbol
    void *func_start = resolve_prepare_layer0();
    if (!func_start) {
        os_log_error(log, "Cannot resolve prepare_layer0 — aborting");
        return NULL;
    }

    // Step 2: Scan within the function for TST Xn, #0x(7F|FF)00000 followed
    // by B.NE within the next few instructions (compiler may schedule
    // other instructions between TST and B.NE).
    const size_t max_scan_size = 65536;
    const uint32_t *insns = (const uint32_t *)func_start;
    size_t count = max_scan_size / sizeof(uint32_t);

    os_log_info(log, "Scanning prepare_layer0 at %p (%zu instructions max)", func_start, count);

    for (size_t i = 0; i + 4 < count; i++) {
        if (is_tst_xn_disableUpdateMask(insns[i])) {
            os_log_info(log, "Found TST at %p (insn=0x%x)", (void *)&insns[i], insns[i]);
            // Search for B.NE within the next 4 instructions
            for (size_t j = 1; j <= 4 && (i + j) < count; j++) {
                if (is_b_ne(insns[i + j])) {
                    void *branch_addr = (void *)&insns[i + j];
                    os_log(log, "Found B.NE at %p (offset +%zu from TST)", branch_addr, j);
                    return branch_addr;
                }
            }
            os_log_error(log, "TST found but no B.NE within 4 instructions");
        }
    }

    os_log_error(log, "Pattern not found in prepare_layer0 (%zu instructions scanned)", count);
    return NULL;
}

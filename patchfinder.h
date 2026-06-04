#ifndef PATCHFINDER_H
#define PATCHFINDER_H

#include <stdint.h>
#include <stddef.h>

/// Find the address of the B.NE instruction that follows
/// TST Xn, #0x7F00000 in QuartzCore's __TEXT,__text section.
/// Returns the address of B.NE on success, NULL on failure.
void *find_disableUpdateMask_branch(void);

/// Find the per-build offset of display flags within get_display_info's typed
/// output structure. Returns 0 if the instruction pattern is not recognized.
uint32_t find_get_display_info_flags_offset(void);

#endif /* PATCHFINDER_H */

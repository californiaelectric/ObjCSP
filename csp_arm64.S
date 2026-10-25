// csp_arm64.S -- the context switch and the spin hint, for Apple Silicon
// Macs. Each CPU type gets its own; on others this file is empty.

#if defined(__arm64__)

// csp_switch(void **save, void *next): save this context's stack pointer
// in *save and continue on the context whose stack pointer is next.
// Saves what the arm64 ABI says a call preserves: x19-x28, fp, lr, the
// low halves of d8-d15, and FPCR. x18 is the platform's: never touched.
// The frame, 176 bytes, lowest address first:
//     x19 x20 x21 x22 x23 x24 x25 x26 x27 x28 fp lr d8-d15 fpcr pad
// procNew in CSPSched.m builds a process's first one to match.
        .text
        .globl  _csp_switch
        .p2align 2
_csp_switch:
        sub     sp, sp, #176
        stp     x19, x20, [sp, #0]
        stp     x21, x22, [sp, #16]
        stp     x23, x24, [sp, #32]
        stp     x25, x26, [sp, #48]
        stp     x27, x28, [sp, #64]
        stp     x29, x30, [sp, #80]
        stp     d8,  d9,  [sp, #96]
        stp     d10, d11, [sp, #112]
        stp     d12, d13, [sp, #128]
        stp     d14, d15, [sp, #144]
        mrs     x9, fpcr
        str     x9, [sp, #160]
        mov     x9, sp
        str     x9, [x0]
        mov     sp, x1
        ldr     x9, [sp, #160]
        msr     fpcr, x9
        ldp     d14, d15, [sp, #144]
        ldp     d12, d13, [sp, #128]
        ldp     d10, d11, [sp, #112]
        ldp     d8,  d9,  [sp, #96]
        ldp     x29, x30, [sp, #80]
        ldp     x27, x28, [sp, #64]
        ldp     x25, x26, [sp, #48]
        ldp     x23, x24, [sp, #32]
        ldp     x21, x22, [sp, #16]
        ldp     x19, x20, [sp, #0]
        add     sp, sp, #176
        ret

// The first code a new process runs: fn(arg), from x19 and x20. Marked as
// the bottom of the stack (no return address, fp 0), so the exception
// unwinder and the debugger stop here instead of walking into garbage.
        .globl  _csp_start
        .p2align 2
_csp_start:
        .cfi_startproc
        .cfi_undefined lr
        mov     x29, #0
        mov     x30, #0
        mov     x0, x20
        blr     x19
        brk     #1
        .cfi_endproc

// csp_relax(): a pause in a spin-wait. Apple's cores treat yield, the
// instruction meant for this, as a no-op; isb waits about 8 ns (M5 Max),
// as pause does on Intel.
        .globl  _csp_relax
        .p2align 2
_csp_relax:
        isb
        ret

#endif

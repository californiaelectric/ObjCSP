// csp_x86_64.S -- the context switch and the spin hint, for Intel Macs.
// Each CPU type gets its own; on others this file is empty and the
// library runs a thread per process.

#if defined(__x86_64__)

// csp_switch(void **save, void *next): save this context's stack pointer
// in *save and continue on the context whose stack pointer is next.
// Saves what the x86_64 ABI says a call preserves: rbp rbx r12-r15,
// MXCSR and the x87 control word.
        .text
        .globl  _csp_switch
        .p2align 4
_csp_switch:
        pushq   %rbp
        pushq   %rbx
        pushq   %r12
        pushq   %r13
        pushq   %r14
        pushq   %r15
        subq    $8, %rsp
        stmxcsr (%rsp)
        fnstcw  4(%rsp)
        movq    %rsp, (%rdi)
        movq    %rsi, %rsp
        ldmxcsr (%rsp)
        fldcw   4(%rsp)
        addq    $8, %rsp
        popq    %r15
        popq    %r14
        popq    %r13
        popq    %r12
        popq    %rbx
        popq    %rbp
        ret

// The first code a new process runs: fn(arg), from r13 and r12. Marked as
// the bottom of the stack (no return address), so the exception unwinder
// and the debugger stop here instead of walking into garbage.
        .globl  _csp_start
        .p2align 4
_csp_start:
        .cfi_startproc
        .cfi_undefined %rip
        pushq   $0
        movq    %r12, %rdi
        callq   *%r13
        ud2
        .cfi_endproc

// csp_relax(): a pause in a spin-wait.
        .globl  _csp_relax
        .p2align 4
_csp_relax:
        pause
        ret

#endif

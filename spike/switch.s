# csp_switch(void **save, void *next): save this context's stack pointer in
# *save, continue on the context whose stack pointer is next. Saves what the
# x86_64 ABI says a call preserves: rbp rbx r12-r15, MXCSR and the x87
# control word.
        .text
        .globl  _csp_switch
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

# First code a new context runs: call fn(arg), left in r13 and r12.
        .globl  _csp_start
_csp_start:
        pushq   $0
        movq    %r12, %rdi
        callq   *%r13
        ud2

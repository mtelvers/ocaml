/**************************************************************************/
/*                                                                        */
/*                                 OCaml                                  */
/*                                                                        */
/*                 Benedikt Meurer, University of Siegen                  */
/*                                                                        */
/*   Copyright 1998 Institut National de Recherche en Informatique et     */
/*     en Automatique.                                                    */
/*   Copyright 2012 Benedikt Meurer.                                      */
/*                                                                        */
/*   All rights reserved.  This file is distributed under the terms of    */
/*   the GNU Lesser General Public License version 2.1, with the          */
/*   special exception on linking described in the file LICENSE.          */
/*                                                                        */
/**************************************************************************/

/* Asm part of the runtime system, ARM processor */
/* Must be preprocessed by cpp */

#include "caml/m.h"
#include "caml/asm.h"

        .syntax unified
        .text
#if defined(SYS_linux_eabihf) && defined(MODEL_armv6)
        .arch   armv6
        .fpu    vfpv2
        .arm

    /* Compatibility macros */
        .macro  cbz reg, lbl
        cmp     \reg, #0
        beq     \lbl
        .endm
#elif defined(SYS_linux_eabihf)
        .arch   armv7-a
        .fpu    vfpv3-d16
        .thumb
#elif defined(SYS_linux_eabi)
        .arch   armv4t
        .arm

    /* Compatibility macros */
        .macro  blx reg
        mov     lr, pc
        bx      \reg
        .endm
        .macro  cbz reg, lbl
        cmp     \reg, #0
        beq     \lbl
        .endm
#elif defined(SYS_netbsd)

  #if defined(MODEL_armv6)
        .arch   armv6
        .fpu    vfpv2
        .arm

    /* Compatibility macros */
        .macro  cbz reg, lbl
        cmp     \reg, #0
        beq     \lbl
        .endm
  #elif defined(MODEL_armv7)
        .arch   armv7-a
        .fpu    vfpv3-d16
        .thumb
  #else
    #error "Only NetBSD eabihf supported"
  #endif

#elif defined(SYS_freebsd)
        .arch   armv6
        .arm

    /* Compatibility macros */
        .macro  cbz reg, lbl
        cmp     \reg, #0
        beq     \lbl
        .endm
#endif

trap_ptr          .req    r8
alloc_ptr         .req    r10
domain_state_ptr  .req    r11

/* CFI directives are provided by caml/asm.h */

#if defined(FUNCTION_SECTIONS)
#define TEXT_SECTION(name) .section .text.caml.##name,"ax",%progbits
#else
#define TEXT_SECTION(name)
#endif

#define FUNCTION(name) \
        TEXT_SECTION(name); \
        .align 2; \
        .globl name; \
        .type name, %function; \
name:

#if defined(FUNCTION_SECTIONS)
        TEXT_SECTION(caml_hot.code_begin)
        .globl  caml_hot.code_begin
caml_hot.code_begin:

        TEXT_SECTION(caml_hot.code_end)
        .globl  caml_hot.code_end
caml_hot.code_end:
#endif

        .set    domain_curr_field, 0
#define DOMAIN_STATE(c_type, name) \
        .equ    domain_field_caml_##name, domain_curr_field ; \
        .set    domain_curr_field, domain_curr_field + 1
#include "../runtime/caml/domain_state.tbl"
#undef DOMAIN_STATE

#define Caml_state(var) [domain_state_ptr, 8*domain_field_caml_##var]

/* Stack switching operations */

/* struct stack_info */
#define Stack_sp(reg)           [reg]
#define Stack_sp_offset         0
#define Stack_exception(reg)    [reg, #8]
#define Stack_handler(reg)      [reg, #16]
#define Stack_handler_from_cont(reg) [reg, #15]

/* struct c_stack_link */
#define Cstack_stack(reg)       [reg]
#define Cstack_sp(reg)          [reg, #8]
#define Cstack_sp_offset        8
#define Cstack_prev(reg)        [reg, #16]

/* struct stack_handler */
#define Handler_value(reg)      [reg]
#define Handler_exception(reg)  [reg, #8]
#define Handler_effect(reg)     [reg, #16]
#define Handler_parent(reg)     [reg, #24]
#define Handler_parent_offset   24

/* Switch from OCaml to C stack. */
.macro SWITCH_OCAML_TO_C
    /* Fill in Caml_state->current_stack->sp */
        ldr     r12, Caml_state(current_stack)
        mov     r7, sp
        str     r7, Stack_sp(r12)
    /* Fill in Caml_state->c_stack */
        ldr     r7, Caml_state(c_stack)
        str     r12, Cstack_stack(r7)
        mov     r12, sp
        str     r12, Cstack_sp(r7)
    /* Switch to C stack */
        mov     sp, r7
.endm

/* Switch from C to OCaml stack. */
.macro SWITCH_C_TO_OCAML
        ldr     r12, Cstack_sp(sp)
        mov     sp, r12
.endm

/* Save all of the registers that may be in use to a free gc_regs bucket
   and store alloc_ptr and trap_ptr back to Caml_state
   At the end the saved registers are placed in Caml_state(gc_regs)
 */
.macro SAVE_ALL_REGS
    /* First, save the young_ptr & exn_handler */
        str     alloc_ptr, Caml_state(young_ptr)
        str     trap_ptr, Caml_state(exn_handler)
    /* Now, use r12 to point to the gc_regs bucket */
        ldr     r12, Caml_state(gc_regs_buckets)
        ldr     r7, [r12, 0] /* next ptr */
        str     r7, Caml_state(gc_regs_buckets)
    /* Save allocatable integer registers (r0-r7, r12) */
        add     r7, r12, #4
        stmia   r7, {r0-r7}
        str     r12, [r12, 36]  /* save r12 itself */
#if defined(SYS_linux_eabihf) || defined(SYS_netbsd)
    /* Save caller-save floating-point registers (d0-d7, d16-d31 are caller-save on ARM) */
        add     r7, r12, #40
        vstmia  r7, {d0-d7}
#endif
        add     r12, r12, #4
        str     r12, Caml_state(gc_regs)
.endm

/* Undo SAVE_ALL_REGS by loading the registers saved in Caml_state(gc_regs)
   and refreshing alloc_ptr & trap_ptr from Caml_state */
.macro RESTORE_ALL_REGS
    /* Restore registers from gc_regs bucket */
        ldr     r12, Caml_state(gc_regs)
        sub     r12, r12, #4
    /* Restore integer registers (r0-r7) */
        add     r7, r12, #4
        ldmia   r7, {r0-r7}
#if defined(SYS_linux_eabihf) || defined(SYS_netbsd)
    /* Restore floating-point registers */
        add     r7, r12, #40
        vldmia  r7, {d0-d7}
#endif
    /* Put gc_regs struct back in bucket linked list */
        ldr     r7, Caml_state(gc_regs_buckets)
        str     r7, [r12, 0]  /* next ptr */
        str     r12, Caml_state(gc_regs_buckets)
    /* Reload new allocation pointer & exn handler */
        ldr     alloc_ptr, Caml_state(young_ptr)
        ldr     trap_ptr, Caml_state(exn_handler)
.endm

/* Allocation functions and GC interface */
        TEXT_SECTION(caml_system__code_begin)
        .globl  caml_system__code_begin
caml_system__code_begin:

FUNCTION(caml_call_realloc_stack)
        CFI_STARTPROC
    /* Save return address and frame pointer */
        push    {r4, lr}
        CFI_ADJUST(8)
    /* Save all registers (including alloc_ptr & trap_ptr) */
        SAVE_ALL_REGS
        ldr     r0, [sp, #8] /* argument */
        SWITCH_OCAML_TO_C
        bl      caml_try_realloc_stack
        SWITCH_C_TO_OCAML
        cmp     r0, #0
        beq     1f
        RESTORE_ALL_REGS
    /* Free stack space and return to caller */
        pop     {r4, pc}
1:      RESTORE_ALL_REGS
    /* Raise the Stack_overflow exception */
        pop     {r4, lr}
        add     sp, sp, #4 /* pop argument */
        ldr     r0, =caml_exn_Stack_overflow
        ldr     r0, [r0]
        b       caml_raise_exn
        CFI_ENDPROC
        .size   caml_call_realloc_stack, .-caml_call_realloc_stack

FUNCTION(caml_call_gc)
        CFI_STARTPROC
.Lcaml_call_gc:
    /* Save return address */
        push    {lr}
        CFI_ADJUST(4)
    /* Store all registers (including alloc_ptr & trap_ptr) */
        SAVE_ALL_REGS
        SWITCH_OCAML_TO_C
    /* Call the garbage collector */
        bl      caml_garbage_collection
        SWITCH_C_TO_OCAML
        RESTORE_ALL_REGS
    /* Free stack space and return to caller */
        pop     {pc}
        CFI_ENDPROC
        .size   caml_call_gc, .-caml_call_gc

FUNCTION(caml_alloc1)
        CFI_STARTPROC
        sub     alloc_ptr, alloc_ptr, 8
        ldr     r7, Caml_state(young_limit)
        cmp     alloc_ptr, r7
        bcc     .Lcaml_call_gc
        bx      lr
        CFI_ENDPROC
        .size   caml_alloc1, .-caml_alloc1

FUNCTION(caml_alloc2)
        CFI_STARTPROC
        sub     alloc_ptr, alloc_ptr, 12
        ldr     r7, Caml_state(young_limit)
        cmp     alloc_ptr, r7
        bcc     .Lcaml_call_gc
        bx      lr
        CFI_ENDPROC
        .size   caml_alloc2, .-caml_alloc2

FUNCTION(caml_alloc3)
        CFI_STARTPROC
        sub     alloc_ptr, alloc_ptr, 16
        ldr     r7, Caml_state(young_limit)
        cmp     alloc_ptr, r7
        bcc     .Lcaml_call_gc
        bx      lr
        CFI_ENDPROC
        .size   caml_alloc3, .-caml_alloc3

FUNCTION(caml_allocN)
        CFI_STARTPROC
        sub     alloc_ptr, alloc_ptr, r7
        ldr     r7, Caml_state(young_limit)
        cmp     alloc_ptr, r7
        bcc     .Lcaml_call_gc
        bx      lr
        CFI_ENDPROC
        .size   caml_allocN, .-caml_allocN

/* Call a C function from OCaml */
/* Function to call is in r7 */

FUNCTION(caml_c_call)
        CFI_STARTPROC
    /* Save return address */
        push    {lr}
        CFI_ADJUST(4)
    /* Switch from OCaml to C */
        SWITCH_OCAML_TO_C
    /* Make the exception handler alloc ptr available to the C code */
        str     alloc_ptr, Caml_state(young_ptr)
        str     trap_ptr, Caml_state(exn_handler)
    /* Call the function */
        blx     r7
    /* Reload new allocation pointer & exn handler */
        ldr     alloc_ptr, Caml_state(young_ptr)
        ldr     trap_ptr, Caml_state(exn_handler)
    /* Switch from C to OCaml */
        SWITCH_C_TO_OCAML
    /* Return */
        pop     {pc}
        CFI_ENDPROC
        .size   caml_c_call, .-caml_c_call

/* Start the OCaml program */

FUNCTION(caml_start_program)
        CFI_STARTPROC
    /* domain state is passed as arg from C */
        mov     r12, r0
        ldr     r7, =caml_program

/* Code shared with caml_callback* */
/* Address of domain state is in r12 */
/* Address of OCaml code to call is in r7 */
/* Arguments to the OCaml code are in r0...r3 */

.Ljump_to_caml:
    /* Set up stack frame and save callee-save registers */
#if defined(SYS_linux_eabihf) || defined(SYS_netbsd)
    /* Save callee-save floating-point registers */
        vpush   {d8-d15}; CFI_ADJUST(64)
#endif
    /* Save return address and callee-save integer registers */
        push    {r4-r8,r10,r11,lr}; CFI_ADJUST(32)
    /* Load domain state pointer from argument */
        mov     domain_state_ptr, r12
    /* Reload allocation pointer */
        ldr     alloc_ptr, Caml_state(young_ptr)
    /* Build struct c_stack_link on the C stack (24 bytes, 8-byte aligned) */
        ldr     r4, Caml_state(c_stack)
        push    {r4}; CFI_ADJUST(4)         /* C_stack_prev */
        sub     sp, sp, #4; CFI_ADJUST(4)   /* padding for 8-byte alignment */
        push    {r4, r5}; CFI_ADJUST(8)     /* C_stack_stack (unused), C_stack_sp (set later) */
        mov     r4, sp
        str     r4, Caml_state(c_stack)
    /* Load the OCaml stack */
        ldr     r4, Caml_state(current_stack)
        ldr     r4, Stack_sp(r4)
    /* Store the gc_regs for callbacks during a GC */
        ldr     r5, Caml_state(gc_regs)
        str     r5, [r4, #-4]!
    /* Store the C stack pointer to allow unwinding */
        str     sp, [r4, #-4]!  /* C_stack_sp */
    /* Setup a trap frame to catch exceptions escaping the OCaml code */
        ldr     r5, Caml_state(exn_handler)
        ldr     r6, =.Ltrap_handler
        str     r5, [r4, #-4]!
        str     r6, [r4, #-4]!
        mov     trap_ptr, r4
    /* Switch stacks and call the OCaml code */
        mov     sp, r4
    /* Call the OCaml code */
        blx     r7
.Lcaml_retaddr:
    /* Pop the trap frame, restoring Caml_state->exn_handler */
        ldr     r4, [sp], #8
        str     r4, Caml_state(exn_handler)
.Lreturn_result:
    /* Restore gc_regs and C stack pointer */
        ldr     r5, [sp], #4  /* C_stack_sp (not used here) */
        ldr     r5, [sp], #4  /* gc_regs */
        str     r5, Caml_state(gc_regs)
    /* Update allocation pointer */
        str     alloc_ptr, Caml_state(young_ptr)
    /* Return to C stack */
        ldr     r4, Caml_state(current_stack)
        str     sp, Stack_sp(r4)
        ldr     sp, Caml_state(c_stack)
    /* Pop the struct c_stack_link (24 bytes) */
        ldr     r4, Cstack_prev(sp)
        add     sp, sp, #16
        str     r4, Caml_state(c_stack)
    /* Reload callee-save registers */
        pop     {r4-r8,r10,r11,lr}
#if defined(SYS_linux_eabihf) || defined(SYS_netbsd)
    /* Reload callee-save floating-point registers */
        vpop    {d8-d15}
#endif
        bx      lr
        CFI_ENDPROC
        .type   .Lcaml_retaddr, %function
        .size   .Lcaml_retaddr, .-.Lcaml_retaddr
        .size   caml_start_program, .-caml_start_program

/* The trap handler */

        .align  2
.Ltrap_handler:
        CFI_STARTPROC
    /* Save exception handler */
        str     trap_ptr, Caml_state(exn_handler)
    /* Encode exception bucket as an exception result */
        orr     r0, r0, 2
    /* Return it */
        b       .Lreturn_result
        CFI_ENDPROC
        .type   .Ltrap_handler, %function
        .size   .Ltrap_handler, .-.Ltrap_handler

/* Raise an exception from OCaml */

FUNCTION(caml_raise_exn)
        CFI_STARTPROC
    /* Test if backtrace is active */
        ldr     r1, Caml_state(backtrace_active)
        cbz     r1, 1f
    /* Zero backtrace_pos */
        mov     r1, #0
        str     r1, Caml_state(backtrace_pos)
.Lcaml_reraise_exn_stash:
    /* Preserve exception bucket in callee-save register r4 */
        mov     r4, r0
    /* Stash the backtrace */
                                                /* arg1: exn bucket, already in r0 */
        mov     r1, lr                          /* arg2: pc of raise */
        mov     r2, sp                          /* arg3: sp of raise */
        mov     r3, trap_ptr                    /* arg4: sp of handler */
    /* Switch to C stack */
        ldr     r12, Caml_state(c_stack)
        mov     sp, r12
        bl      caml_stash_backtrace
    /* Restore exception bucket and raise */
        mov     r0, r4
1:  /* Cut stack at current trap handler */
        mov     sp, trap_ptr
    /* Pop previous handler and addr of trap, and jump to it */
        pop     {trap_ptr, pc}
        CFI_ENDPROC
        .size   caml_raise_exn, .-caml_raise_exn

FUNCTION(caml_reraise_exn)
        CFI_STARTPROC
        ldr     r1, Caml_state(backtrace_active)
        cmp     r1, #0
        bne     .Lcaml_reraise_exn_stash
        mov     sp, trap_ptr
        pop     {trap_ptr, pc}
        CFI_ENDPROC
        .size   caml_reraise_exn, .-caml_reraise_exn

/* Raise an exception from C */

FUNCTION(caml_raise_exception)
        CFI_STARTPROC
    /* Load the domain state ptr */
        mov     domain_state_ptr, r0
    /* Load exception bucket */
        mov     r0, r1
    /* Reload trap ptr and alloc ptr */
        ldr     trap_ptr, Caml_state(exn_handler)
        ldr     alloc_ptr, Caml_state(young_ptr)
    /* Test if backtrace is active */
        ldr     r1, Caml_state(backtrace_active)
        cbz     r1, 1f
    /* Preserve exception bucket in callee-save register r4 */
        mov     r4, r0
        mov     r1, lr                              /* arg2: pc of raise */
        mov     r2, sp                              /* arg3: sp of raise */
        mov     r3, trap_ptr                        /* arg4: sp of handler */
        bl      caml_stash_backtrace
    /* Restore exception bucket */
        mov     r0, r4
1:  /* Cut stack at current trap handler */
        mov     sp, trap_ptr
    /* Pop previous handler and addr of trap, and jump to it */
        pop     {trap_ptr, pc}
        CFI_ENDPROC
        .size   caml_raise_exception, .-caml_raise_exception

/* Callback from C to OCaml */

FUNCTION(caml_callback_asm)
        CFI_STARTPROC
    /* Initial shuffling of arguments */
    /* (r0 = Caml_state, r1 = closure, r2 = *args) */
        mov     r12, r0         /* r12 = Caml_state */
        ldr     r0, [r2]        /* r0 = first arg */
                                /* r1 = closure environment */
        ldr     r7, [r1]        /* r7 = code pointer */
        b       .Ljump_to_caml
        CFI_ENDPROC
        .size   caml_callback_asm, .-caml_callback_asm

FUNCTION(caml_callback2_asm)
        CFI_STARTPROC
    /* Initial shuffling of arguments */
    /* (r0 = Caml_state, r1 = closure, r2 = *args) */
        mov     r12, r0         /* r12 = Caml_state */
        mov     r7, r1          /* save closure */
        ldr     r0, [r2]        /* r0 = first arg */
        ldr     r1, [r2, #4]    /* r1 = second arg */
        mov     r2, r7          /* r2 = closure environment */
        ldr     r7, =caml_apply2
        b       .Ljump_to_caml
        CFI_ENDPROC
        .size   caml_callback2_asm, .-caml_callback2_asm

FUNCTION(caml_callback3_asm)
        CFI_STARTPROC
    /* Initial shuffling of arguments */
    /* (r0 = Caml_state, r1 = closure, r2 = *args) */
        mov     r12, r0         /* r12 = Caml_state */
        mov     r3, r1          /* r3 = closure environment */
        ldr     r0, [r2]        /* r0 = first arg */
        ldr     r1, [r2, #4]    /* r1 = second arg */
        ldr     r2, [r2, #8]    /* r2 = third arg */
        ldr     r7, =caml_apply3
        b       .Ljump_to_caml
        CFI_ENDPROC
        .size   caml_callback3_asm, .-caml_callback3_asm

FUNCTION(caml_ml_array_bound_error)
        CFI_STARTPROC
    /* Load address of [caml_array_bound_error_asm] in r7 */
        ldr     r7, =caml_array_bound_error_asm
    /* Call that function */
        b       caml_c_call
        CFI_ENDPROC
        .size   caml_ml_array_bound_error, .-caml_ml_array_bound_error

        TEXT_SECTION(caml_system__code_end)
        .globl  caml_system__code_end
caml_system__code_end:

/* GC roots for callback */

        .data
        .align  2
        .globl  caml_system.frametable
caml_system.frametable:
        .word   1               /* one descriptor */
        .word   .Lcaml_retaddr  /* return address into callback */
        .short  -1              /* negative frame size => use callback link */
        .short  0               /* no roots */
        .align  2
        .type   caml_system.frametable, %object
        .size   caml_system.frametable, .-caml_system.frametable

/* Mark stack as non-executable */
        .section .note.GNU-stack,"",%progbits

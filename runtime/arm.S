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
#elif defined(SYS_linux_eabihf) && defined(MODEL_armv8m)
        .arch   armv8-m.main
        .fpu    softvfp
        .thumb
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

/* Thumb function entry point marker - needed for correct interworking */
#if (defined(SYS_linux_eabihf) && !defined(MODEL_armv6)) || \
    (defined(SYS_netbsd) && defined(MODEL_armv7)) || \
    defined(MODEL_armv8m)
#define THUMB_FUNC .thumb_func
#else
#define THUMB_FUNC
#endif

trap_ptr          .req    r8
alloc_ptr         .req    r10
domain_state_ptr  .req    r11

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
        TEXT_SECTION(caml_hot__code_begin)
        .globl  caml_hot__code_begin
caml_hot__code_begin:

        TEXT_SECTION(caml_hot__code_end)
        .globl  caml_hot__code_end
caml_hot__code_end:
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
#define Stack_exception(reg)    [reg, #4]
#define Stack_handler(reg)      [reg, #8]
#define Stack_handler_from_cont(reg) [reg, #7]

/* struct c_stack_link */
#define Cstack_stack(reg)       [reg]
#define Cstack_sp(reg)          [reg, #4]
#define Cstack_prev(reg)        [reg, #8]

/* struct stack_handler */
#define Handler_value(reg)      [reg]
#define Handler_exception(reg)  [reg, #4]
#define Handler_effect(reg)     [reg, #8]
#define Handler_parent(reg)     [reg, #12]

/* Switch from OCaml to C stack.
   Callers must have done push {r4, lr} before invoking this macro. */
.macro SWITCH_OCAML_TO_C
    /* Fill in Caml_state->current_stack->sp */
        ldr     r5, Caml_state(current_stack)
        str     sp, Stack_sp(r5)
    /* Fill in Caml_state->c_stack */
        ldr     r6, Caml_state(c_stack)
        str     r5, Cstack_stack(r6)
        str     sp, Cstack_sp(r6)
    /* Switch to C stack */
        mov     sp, r6
.endm

/* Switch from C to OCaml stack. */
.macro SWITCH_C_TO_OCAML
        ldr     r5, Cstack_sp(sp)
        mov     sp, r5
.endm

/* Save all of the registers that may be in use to a free gc_regs bucket
   and store ALLOC_PTR and TRAP_PTR back to Caml_state
   At the end the saved registers are placed in Caml_state(gc_regs)
 */
.macro SAVE_ALL_REGS
    /* First, save the young_ptr & exn_handler */
        str     alloc_ptr, Caml_state(young_ptr)
        str     trap_ptr, Caml_state(exn_handler)
    /* Save r5, r6 to stack first since we need them as scratch */
        push    {r5, r6}
    /* Now, use r5 to point to the gc_regs bucket */
        ldr     r5, Caml_state(gc_regs_buckets)
        ldr     r6, [r5, 0] /* next ptr */
        str     r6, Caml_state(gc_regs_buckets)
    /* Save allocatable integer registers */
    /* Layout: [r5+4]=r0, [r5+8]=r1, ..., [r5+20]=r4, [r5+24]=r5, [r5+28]=r6, [r5+32]=r7, [r5+36]=r12 */
        str     r0, [r5, #4]
        str     r1, [r5, #8]
        str     r2, [r5, #12]
        str     r3, [r5, #16]
        str     r4, [r5, #20]
    /* Save ORIGINAL r5, r6 from stack */
        ldr     r6, [sp, #0]
        str     r6, [r5, #24]
        ldr     r6, [sp, #4]
        str     r6, [r5, #28]
        str     r7, [r5, #32]
        str     r12, [r5, #36]
#if (defined(SYS_linux_eabihf) || defined(SYS_netbsd)) && !defined(MODEL_armv8m)
    /* Save caller-save floating-point registers (not needed for soft float) */
        add     r6, r5, #40
        vstm    r6, {d0-d7}
#endif
        add     r5, r5, #4
        str     r5, Caml_state(gc_regs)
    /* Clean up stack */
        add     sp, sp, #8
.endm

/* Undo SAVE_ALL_REGS by loading the registers saved in Caml_state(gc_regs)
   and refreshing ALLOC_PTR & TRAP_PTR from Caml_state */
.macro RESTORE_ALL_REGS
    /* Restore registers */
        ldr     r5, Caml_state(gc_regs)
        sub     r5, r5, #4
    /* Save bucket pointer to stack before ldm clobbers r5 */
        push    {r5}
#if (defined(SYS_linux_eabihf) || defined(SYS_netbsd)) && !defined(MODEL_armv8m)
    /* Restore floating-point registers BEFORE ldm (so r6 isn't clobbered) */
        add     r6, r5, #40
        vldm    r6, {d0-d7}
#endif
        add     r6, r5, #4
        ldm     r6, {r0-r7,r12}
    /* Put gc_regs struct back in bucket linked list */
    /* Use alloc_ptr/trap_ptr as temps since they get reloaded below */
        pop     {alloc_ptr}     /* alloc_ptr = bucket pointer */
        ldr     trap_ptr, Caml_state(gc_regs_buckets)
        str     trap_ptr, [alloc_ptr, 0]  /* bucket->next = list head */
        str     alloc_ptr, Caml_state(gc_regs_buckets)  /* list head = bucket */
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
        push    {r4, lr}; CFI_ADJUST(8)
#if defined(SYS_linux_eabihf) || defined(SYS_netbsd)
        CFI_OFFSET(lr, -4)
#else
        CFI_OFFSET(lr, -4)
#endif
    /* Save all registers (including ALLOC_PTR & TRAP_PTR) */
        SAVE_ALL_REGS
        ldr     r0, [sp, #8] /* argument */
        SWITCH_OCAML_TO_C
        bl      caml_try_realloc_stack
        SWITCH_C_TO_OCAML
        cmp     r0, #0
        beq     1f
        RESTORE_ALL_REGS
    /* Free stack space and return to caller */
        add     sp, sp, #4  /* skip saved r4, restored by RESTORE_ALL_REGS */
        pop     {pc}
1:      RESTORE_ALL_REGS
    /* Raise the Stack_overflow exception */
        add     sp, sp, #4  /* skip saved r4, restored by RESTORE_ALL_REGS */
        pop     {lr}
        add     sp, sp, #4 /* pop argument */
        ldr     r0, =caml_exn_Stack_overflow
        b       caml_raise_exn
        CFI_ENDPROC
        .size   caml_call_realloc_stack, .-caml_call_realloc_stack

FUNCTION(caml_call_gc)
        CFI_STARTPROC
.Lcaml_call_gc:
    /* Save return address and frame pointer */
        push    {r4, lr}; CFI_ADJUST(8)
#if defined(SYS_linux_eabihf) || defined(SYS_netbsd)
        CFI_OFFSET(lr, -4)
#else
        CFI_OFFSET(lr, -4)
#endif
    /* Store all registers (including ALLOC_PTR & TRAP_PTR) */
        SAVE_ALL_REGS
        SWITCH_OCAML_TO_C
    /* Call the garbage collector */
        bl      caml_garbage_collection
        SWITCH_C_TO_OCAML
        RESTORE_ALL_REGS
    /* Free stack space and return to caller */
        add     sp, sp, #4  /* skip saved r4, restored by RESTORE_ALL_REGS */
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

/* Return from a C call. Check if there is some pending action.
   If so, poison young_limit to force a poll at the next allocation. */
.macro RET_FROM_C_CALL
        ldr     r7, Caml_state(action_pending)
        cbz     r7, 1f
        mov     r7, #-1
        str     r7, Caml_state(young_limit)
1:      bx      lr
.endm

FUNCTION(caml_c_call)
        CFI_STARTPROC
        push    {r4, lr}; CFI_ADJUST(8)
        CFI_OFFSET(lr, -4)
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
    /* Load ocaml stack */
        SWITCH_C_TO_OCAML
    /* Return */
        pop     {r4, lr}
        RET_FROM_C_CALL
        CFI_ENDPROC
        .size   caml_c_call, .-caml_c_call

FUNCTION(caml_c_call_stack_args)
        CFI_STARTPROC
    /* Arguments:
        C arguments  : r0 to r3, d0 to d7
        C function   : r7
        C stack args : begin=r9, end=r12 */
        push    {r4, lr}; CFI_ADJUST(8)
        CFI_OFFSET(lr, -4)
    /* Switch from OCaml to C */
        SWITCH_OCAML_TO_C
    /* Make the exception handler alloc ptr available to the C code */
        str     alloc_ptr, Caml_state(young_ptr)
        str     trap_ptr, Caml_state(exn_handler)
    /* Store sp to restore after call */
        mov     r4, sp
    /* Copy arguments from OCaml to C stack (r9=begin, r12=end) */
1:      sub     r12, r12, #8
        cmp     r12, r9
        blo     2f
        ldm     r12, {r5, r6}
        push    {r5, r6}; CFI_ADJUST(8)
        b       1b
2:  /* Call the function */
        blx     r7
    /* Restore stack */
        mov     sp, r4
    /* Reload new allocation pointer & exn handler */
        ldr     alloc_ptr, Caml_state(young_ptr)
        ldr     trap_ptr, Caml_state(exn_handler)
    /* Switch from C to OCaml */
        SWITCH_C_TO_OCAML
    /* Return */
        pop     {r4, lr}
        RET_FROM_C_CALL
        CFI_ENDPROC
        .size   caml_c_call_stack_args, .-caml_c_call_stack_args

/* Start the OCaml program */

FUNCTION(caml_start_program)
        CFI_STARTPROC
    /* Save original r11 (may be frame pointer in C code) and return address */
        push    {r11, lr}; CFI_ADJUST(8)
        CFI_OFFSET(r11, -8)
        CFI_OFFSET(lr, -4)
    /* domain state is passed as arg from C */
        mov     domain_state_ptr, r0
        ldr     r12, =caml_program
        bl      .Ljump_to_caml
    /* Restore original r11 and return to C caller */
        pop     {r11, pc}

/* Code shared with caml_callback* */
/* Address of domain state is in domain_state_ptr */
/* Address of OCaml code to call is in r12 */
/* Arguments to the OCaml code are in r0...r3 */

.Ljump_to_caml:
#if (defined(SYS_linux_eabihf) || defined(SYS_netbsd)) && !defined(MODEL_armv8m)
    /* Save callee-save floating-point registers (not needed for soft float) */
        vpush   {d8-d15}; CFI_ADJUST(64)
#endif
    /* Save return address and callee-save registers.
       r9 (platform/GOT register) must be saved because caml_c_call_stack_args
       uses it as a scratch register for stack arg passing, which would corrupt
       the C caller's GOT base in PIC/PIE code. */
        push    {r4-r11,lr}; CFI_ADJUST(36)
        sub     sp, sp, #4; CFI_ADJUST(4)               /* 8-byte alignment */
#if (defined(SYS_linux_eabihf) || defined(SYS_netbsd)) && !defined(MODEL_armv8m)
        CFI_OFFSET(lr, -72)
#else
        CFI_OFFSET(lr, -4)
#endif
    /* Reload allocation pointer */
        ldr     alloc_ptr, Caml_state(young_ptr)
    /* Build (8-byte aligned) struct c_stack_link on the C stack */
        ldr     r4, Caml_state(c_stack)
        push    {r4}; CFI_ADJUST(4) /* C_stack_prev */
        push    {r4}; CFI_ADJUST(4) /* pad */
        push    {r4}; CFI_ADJUST(4) /* C_stack_sp */
        push    {r4}; CFI_ADJUST(4) /* C_stack_stack */
        mov     r4, sp
        str     r4, Caml_state(c_stack)
    /* Load the OCaml stack */
        ldr     r4, Caml_state(current_stack)
        ldr     r4, Stack_sp(r4)
    /* Store the gc_regs for callbacks during a GC */
        ldr     r5, Caml_state(gc_regs)
        push    {r5}; CFI_ADJUST(4)
        sub     r4, r4, #4
        str     r5, [r4]
    /* Store the stack pointer to allow DWARF unwind */
        str     sp, [r4, #-4]!  /* C_stack_sp */
    /* Setup a trap frame to catch exceptions escaping the OCaml code */
        ldr     r5, Caml_state(exn_handler)
        ldr     r6, =.Ltrap_handler
#if (defined(SYS_linux_eabihf) && !defined(MODEL_armv6)) || \
    (defined(SYS_netbsd) && defined(MODEL_armv7))
    /* Set Thumb bit for interworking - literal pool doesn't preserve it */
        orr     r6, r6, #1
#endif
        push    {r5, r6}
        sub     r4, r4, #8
        stm     r4, {r5, r6}
        mov     trap_ptr, r4
    /* Switch stacks and call the OCaml code */
        mov     sp, r4
        CFI_REMEMBER_STATE
    /* Call the OCaml code */
        blx     r12
.Lcaml_retaddr:
    /* Pop the trap frame, restoring Caml_state->exn_handler */
        ldr     r4, [sp]
        str     r4, Caml_state(exn_handler)
        add     sp, sp, #8; CFI_ADJUST(-8)
.Lreturn_result:
    /* restore GC regs */
        ldm     sp, {r4, r5}
        add     sp, sp, #8; CFI_ADJUST(-8)
        str     r5, Caml_state(gc_regs)
    /* Update allocation pointer */
        str     alloc_ptr, Caml_state(young_ptr)
    /* Return to C stack */
        ldr     r4, Caml_state(current_stack)
        str     sp, Stack_sp(r4)
        ldr     r5, Caml_state(c_stack)
        mov     sp, r5
        CFI_RESTORE_STATE
    /* Pop the struct c_stack_link */
        ldr     r4, Cstack_prev(sp)
        add     sp, sp, #16; CFI_ADJUST(-16)
        str     r4, Caml_state(c_stack)
    /* Reload callee-save registers and return address */
        add     sp, sp, #4; CFI_ADJUST(-4)               /* undo alignment pad */
        pop     {r4-r11,lr}; CFI_ADJUST(-36)
#if (defined(SYS_linux_eabihf) || defined(SYS_netbsd)) && !defined(MODEL_armv8m)
    /* Reload callee-save floating-point registers (not needed for soft float) */
        vpop    {d8-d15}; CFI_ADJUST(-64)
#endif
        bx      lr
        CFI_ENDPROC
        .type   .Lcaml_retaddr, %function
        .size   .Lcaml_retaddr, .-.Lcaml_retaddr
        .size   caml_start_program, .-caml_start_program

/* The trap handler */

        .align  2
        THUMB_FUNC
.Ltrap_handler:
        CFI_STARTPROC
    /* Save exception pointer */
        str     trap_ptr, Caml_state(exn_handler)
    /* Encode exception bucket as an exception result */
        orr     r0, r0, 2
    /* Return it */
        b       .Lreturn_result
        CFI_ENDPROC
        .type   .Ltrap_handler, %function
        .size   .Ltrap_handler, .-.Ltrap_handler

/* Exceptions */

.macro JUMP_TO_TRAP_PTR
    /* Cut stack at current trap handler */
        mov     sp, trap_ptr
    /* Pop previous handler and addr of trap, and jump to it */
        pop     {trap_ptr, pc}
.endm

/* Raise an exception from OCaml */
FUNCTION(caml_raise_exn)
        CFI_STARTPROC
    /* Test if backtrace is active */
        ldr     r1, Caml_state(backtrace_active)
        cbz     r1, 1f
    /* Zero backtrace_pos */
        mov     r5, #0
        str     r5, Caml_state(backtrace_pos)
.Lcaml_reraise_exn_stash:
    /* Preserve exception bucket in callee-save register r4 */
        mov     r4, r0
    /* Stash the backtrace */
        mov     r1, lr                          /* arg2: pc of raise */
        mov     r2, sp                          /* arg3: sp of raise */
        mov     r3, trap_ptr                    /* arg4: sp of handler */
    /* Switch to C stack */
        ldr     r5, Caml_state(c_stack)
        mov     sp, r5
        bl      caml_stash_backtrace
    /* Restore exception bucket */
        mov     r0, r4
1:
        JUMP_TO_TRAP_PTR
        CFI_ENDPROC
        .size   caml_raise_exn, .-caml_raise_exn

FUNCTION(caml_reraise_exn)
        CFI_STARTPROC
        ldr     r1, Caml_state(backtrace_active)
        cmp     r1, #0
        bne     .Lcaml_reraise_exn_stash
        JUMP_TO_TRAP_PTR
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
    /* Discard the C stack pointer and reset to ocaml stack */
        ldr     r5, Caml_state(current_stack)
        ldr     r5, Stack_sp(r5)
        mov     sp, r5
    /* Restore frame and link on return to OCaml */
        pop     {r4, lr}
        b       caml_raise_exn
        CFI_ENDPROC
        .size   caml_raise_exception, .-caml_raise_exception

/* Callback from C to OCaml */

FUNCTION(caml_callback_asm)
        CFI_STARTPROC
    /* Save original r11 (may be frame pointer in C code) and return address */
        push    {r11, lr}; CFI_ADJUST(8)
        CFI_OFFSET(r11, -8)
        CFI_OFFSET(lr, -4)
    /* Initial shuffling of arguments */
    /* (r0 = Caml_state, r1 = closure, [r2] = first arg) */
        mov     domain_state_ptr, r0
        ldr     r0, [r2]        /* r0 = first arg */
                                /* r1 = closure environment */
        ldr     r12, [r1]       /* code pointer */
        bl      .Ljump_to_caml
    /* Restore original r11 and return to C caller */
        pop     {r11, pc}
        CFI_ENDPROC
        .size   caml_callback_asm, .-caml_callback_asm

FUNCTION(caml_callback2_asm)
        CFI_STARTPROC
    /* Save original r11 (may be frame pointer in C code) and return address */
        push    {r11, lr}; CFI_ADJUST(8)
        CFI_OFFSET(r11, -8)
        CFI_OFFSET(lr, -4)
    /* Initial shuffling of arguments */
    /* (r0 = Caml_state, r1 = closure, [r2] = arg1, [r2,4] = arg2) */
        mov     domain_state_ptr, r0
        mov     r12, r1
        ldr     r0, [r2]          /* r0 = first arg */
        ldr     r1, [r2,4]        /* r1 = second arg */
        mov     r2, r12           /* r2 = closure environment */
        ldr     r12, =caml_apply2
        bl      .Ljump_to_caml
    /* Restore original r11 and return to C caller */
        pop     {r11, pc}
        CFI_ENDPROC
        .size   caml_callback2_asm, .-caml_callback2_asm

FUNCTION(caml_callback3_asm)
        CFI_STARTPROC
    /* Save original r11 (may be frame pointer in C code) and return address */
        push    {r11, lr}; CFI_ADJUST(8)
        CFI_OFFSET(r11, -8)
        CFI_OFFSET(lr, -4)
    /* Initial shuffling of arguments */
    /* (r0 = Caml_state, r1 = closure, [r2] = arg1, [r2,4] = arg2,
        [r2,8] = arg3) */
        mov     domain_state_ptr, r0
        mov     r3, r1            /* r3 = closure environment */
        ldr     r0, [r2]          /* r0 = first arg */
        ldr     r1, [r2,4]        /* r1 = second arg */
        ldr     r2, [r2,8]        /* r2 = third arg */
        ldr     r12, =caml_apply3
        bl      .Ljump_to_caml
    /* Restore original r11 and return to C caller */
        pop     {r11, pc}
        CFI_ENDPROC
        .size   caml_callback3_asm, .-caml_callback3_asm

/* Fibers */

/* Switch between OCaml stacks. Clobbers r5 and switches TRAP_PTR
   Preserves old_stack and new_stack registers */
.macro SWITCH_OCAML_STACKS old_stack, new_stack
    /* Save frame pointer and return address for old_stack */
        push    {r4, lr}; CFI_ADJUST(8)
    /* Save OCaml SP and exn_handler in the stack info */
        str     sp, Stack_sp(\old_stack)
        str     trap_ptr, Stack_exception(\old_stack)
    /* switch stacks */
        str     \new_stack, Caml_state(current_stack)
        ldr     r5, Stack_sp(\new_stack)
        mov     sp, r5
    /* restore exn_handler for new stack */
        ldr     trap_ptr, Stack_exception(\new_stack)
    /* Restore frame pointer and return address for new_stack */
        pop     {r4, lr}
.endm

FUNCTION(caml_perform)
        CFI_STARTPROC
    /*  r0: effect to perform
        r1: freshly allocated continuation (1-word Cont_tag block)
        Following amd64 semantics: cont[0] = cont_tail (Val_ptr of last fiber).
        Handler_parent(Stack_handler(cont_tail)) = cont_head (first fiber). */
        ldr     r2, Caml_state(current_stack) /* r2 := current_stack */
        add     r3, r2, #1 /* r3 := Val_ptr(current_stack) */
        str     r3, [r1] /* cont[0] = Val_ptr(current_stack) */
        mov     r3, r2   /* r3 := cont_head */
.Ldo_perform:
    /*  r0: effect to perform
        r1: continuation
        r2: old_stack (the stack being captured)
        r3: cont_head (first fiber in continuation chain) */
        ldr     r5, Stack_handler(r2)  /* r5 := old stack -> handler */
        ldr     r6, Handler_parent(r5) /* r6 := parent stack */
        cbz     r6, 1f
        mov     r7, r5                 /* Save handler in r7 (not clobbered by SWITCH) */
        SWITCH_OCAML_STACKS r2, r6
    /* Update cont[0] with new cont_tail = Val_ptr(old_stack).
       r2 is preserved across SWITCH (old_stack). */
        add     r4, r2, #1             /* r4 := Val_ptr(old_stack) = new cont_tail */
        str     r4, [r1]               /* cont[0] = new cont_tail */
    /* Set handler's parent to cont_head (so resume can find cont_head) */
        str     r3, Handler_parent(r7)
    /* Get effect handler closure and call caml_apply2.
       caml_apply2 on ARM: r0=arg1(effect), r1=arg2(continuation), r2=closure */
        ldr     r2, Handler_effect(r7)
        ldr     r12, =caml_apply2
        bx      r12
1:
    /*  No parent stack. Switch back to cont_head and raise Unhandled.
        (no-op unless this is a reperform) */
        cmp     r2, r3
        beq     .Lperform_raise_unhandled
        SWITCH_OCAML_STACKS r2, r3
.Lperform_raise_unhandled:
    /* r0 already contains the effect to raise */
        ldr     r7, =caml_raise_unhandled_effect
        b       caml_c_call
        CFI_ENDPROC
        .size   caml_perform, .-caml_perform

FUNCTION(caml_reperform)
        CFI_STARTPROC
    /*  r0: effect to perform
        r1: continuation
        Following amd64 semantics: read cont[0] to get current cont_tail,
        derive cont_head, link current stack into chain. */
        ldr     r4, [r1]                              /* r4 = cont[0] = Val_ptr(cont_tail) */
        ldr     r5, Stack_handler_from_cont(r4)       /* r5 = handler of cont_tail */
        ldr     r3, Handler_parent(r5)                 /* r3 = cont_head */
        ldr     r2, Caml_state(current_stack)          /* r2 = current_stack */
        str     r2, Handler_parent(r5)                 /* link current into chain */
    /* r0=effect, r1=cont, r2=old_stack, r3=cont_head */
        b       .Ldo_perform
        CFI_ENDPROC
        .size   caml_reperform, .-caml_reperform

FUNCTION(caml_resume)
        CFI_STARTPROC
    /*  r0: Val_ptr(cont_tail) - tagged pointer to last fiber
        r1: fun (closure)
        r2: arg
        Derives cont_head from Handler_parent(Stack_handler(cont_tail)). */
        sub     r0, r0, #1 /* r0 = cont_tail (untagged) */
        ldr     r3, [r1]  /* r3 = code pointer */
    /* Check if stack null, then already used */
        cbz     r0, 2f
    /* Derive cont_head from cont_tail */
        ldr     r4, Stack_handler(r0)          /* r4 = handler of cont_tail */
        ldr     r6, Handler_parent(r4)         /* r6 = cont_head */
    /* Link current stack as parent of cont_tail's handler */
        ldr     r5, Caml_state(current_stack)
        str     r5, Handler_parent(r4)
    /* Switch to cont_head (r6) */
        SWITCH_OCAML_STACKS r5, r6
        mov     r0, r2
        bx      r3
2:      ldr     r7, =caml_raise_continuation_already_resumed
        b       caml_c_call
        CFI_ENDPROC
        .size   caml_resume, .-caml_resume

/* Run a function on a new stack, then either
   return the value or invoke exception handler */
FUNCTION(caml_runstack)
        CFI_STARTPROC
    /*  r0: stack
        r1: fun
        r2: arg */
        push    {r4, lr}; CFI_ADJUST(8)
        sub     r0, r0, #1  /* r0 := Ptr_val(r0) */
        ldr     r3, [r1]   /* code pointer */
    /*  save old stack pointer and exception handler */
        ldr     r4, Caml_state(current_stack) /* r4 := old stack */
        str     sp, Stack_sp(r4)
        str     trap_ptr, Stack_exception(r4)
    /* Load new stack pointer and set parent */
        ldr     r5, Stack_handler(r0)
        str     r4, Handler_parent(r5)
        str     r0, Caml_state(current_stack)
        ldr     r6, Stack_sp(r0) /* r6 := sp of new stack */
    /* Create an exception handler on the target stack
       after 8byte DWARF & gc_regs block (which is unused here) */
        sub     r6, r6, #16
    /* Initialize gc_regs slot: First_frame(r6) = r6+8, Saved_gc_regs(r6+8) reads *(r6+8+4) = r6+12 */
        ldr     r5, Caml_state(gc_regs)
        str     r5, [r6, #12]
        ldr     r5, =.Lfiber_exn_handler
#if (defined(SYS_linux_eabihf) && !defined(MODEL_armv6)) || \
    (defined(SYS_netbsd) && defined(MODEL_armv7))
    /* Set Thumb bit for interworking - literal pool doesn't preserve it */
        orr     r5, r5, #1
#endif
        str     r5, [r6, #4]
    /* link the previous exn_handler so that copying stacks works */
        ldr     r5, Stack_exception(r0)
        str     r5, [r6]
        mov     trap_ptr, r6
    /* Switch to the new stack */
        mov     sp, r6
        CFI_REMEMBER_STATE
    /* Call the function on the new stack */
        mov     r0, r2
        blx     r3
        THUMB_FUNC
.Lframe_runstack:
        add     r4, sp, #16 /* r4 := stack_handler */
        ldr     r7, Handler_value(r4) /* saved across C call */
1:
        mov     r6, r0     /* save return across C call */
        ldr     r0, Caml_state(current_stack) /* arg to caml_free_stack */
    /* restore parent stack and exn_handler into Caml_state */
        ldr     r5, Handler_parent(r4)
        str     r5, Caml_state(current_stack)
        ldr     trap_ptr, Stack_exception(r5)
        str     trap_ptr, Caml_state(exn_handler)
    /* free old stack by switching directly to c_stack;
       is a no-alloc call */
        ldr     r9, Stack_sp(r5) /* saved across C call */
        ldr     r5, Caml_state(c_stack)
        mov     sp, r5
        bl      caml_free_stack
    /* switch directly to parent stack with correct return */
        mov     r0, r6
        mov     r1, r7
        mov     sp, r9
        ldr     r5, [r7]  /* code pointer */
    /* Invoke handle_value (or handle_exn) */
        pop     {r4, lr}
        bx      r5
        THUMB_FUNC
.Lfiber_exn_handler:
        add     r4, sp, #8  /* r4 := stack_handler */
        ldr     r7, Handler_exception(r4)
        b       1b
        CFI_ENDPROC
        .type   .Lframe_runstack, %function
        .size   .Lframe_runstack, .-.Lframe_runstack
        .size   caml_runstack, .-caml_runstack

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
        .word   2               /* two descriptors */
        .word   .Lcaml_retaddr  /* return address into callback */
        .short  -1              /* negative frame size => use callback link */
        .short  0               /* no roots */
        .align  2
        .word   .Lframe_runstack /* return address into fiber handler */
        .short  -1              /* negative frame size => use callback link */
        .short  0               /* no roots here */
        .align 2
        .type   caml_system.frametable, %object
        .size   caml_system.frametable, .-caml_system.frametable

/* Mark stack as non-executable */
        .section .note.GNU-stack,"",%progbits

/**************************************************************************/
/*                                                                        */
/*                                 OCaml                                  */
/*                                                                        */
/*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           */
/*                                                                        */
/*   Copyright 1996 Institut National de Recherche en Informatique et     */
/*     en Automatique.                                                    */
/*                                                                        */
/*   All rights reserved.  This file is distributed under the terms of    */
/*   the GNU Lesser General Public License version 2.1, with the          */
/*   special exception on linking described in the file LICENSE.          */
/*                                                                        */
/**************************************************************************/

/* Asm part of the runtime system, Intel 386 processor */
/* Must be preprocessed by cpp */
/* Updated for OCaml 5.x multicore support */

#include "caml/m.h"

/* Linux/BSD with ELF binaries and Solaris do not prefix identifiers with _.
   Linux/BSD with a.out binaries and NextStep do. */

#if (defined(SYS_solaris) && !defined(__GNUC__))
#define CONCAT(a,b) a/**/b
#else
#define CONCAT(a,b) a##b
#endif

#if defined(SYS_linux_elf) || defined(SYS_linux) || defined(SYS_linux) || defined(SYS_bsd_elf) \
 || defined(SYS_solaris) || defined(SYS_beos) || defined(SYS_gnu)
#define G(x) x
#define LBL(x) CONCAT(.L,x)
#else
#define G(x) CONCAT(_,x)
#define LBL(x) CONCAT(L,x)
#endif

#if defined(SYS_linux_elf) || defined(SYS_linux) || defined(SYS_linux) || defined(SYS_bsd_elf) \
 || defined(SYS_solaris) || defined(SYS_beos) || defined(SYS_cygwin) \
 || defined(SYS_mingw) || defined(SYS_gnu)
#define FUNCTION_ALIGN 4
#else
#define FUNCTION_ALIGN 2
#endif

#if defined(FUNCTION_SECTIONS)
#if defined(SYS_macosx) || defined(SYS_mingw) || defined(SYS_cygwin)
#define TEXT_SECTION(name)
#else
#define TEXT_SECTION(name) .section .text.caml.##name,"ax",%progbits
#endif
#else
#define TEXT_SECTION(name)
#endif

#define FUNCTION(name) \
        TEXT_SECTION(name); \
        .globl G(name); \
        .align FUNCTION_ALIGN; \
        G(name):

#if defined(SYS_linux_elf) || defined(SYS_linux) || defined(SYS_bsd_elf) || defined(SYS_gnu)
#define ENDFUNCTION(name) \
        .type name,@function; \
        .size name, . - name
#else
#define ENDFUNCTION(name)
#endif

#ifdef ASM_CFI_SUPPORTED
#define CFI_STARTPROC .cfi_startproc
#define CFI_ENDPROC .cfi_endproc
#define CFI_ADJUST(n) .cfi_adjust_cfa_offset n
#define CFI_REMEMBER_STATE .cfi_remember_state
#define CFI_RESTORE_STATE .cfi_restore_state
#else
#define CFI_STARTPROC
#define CFI_ENDPROC
#define CFI_ADJUST(n)
#define CFI_REMEMBER_STATE
#define CFI_RESTORE_STATE
#endif

/* Define domain state field offsets (8 bytes per field for alignment) */
        .set    domain_curr_field, 0
#define DOMAIN_STATE(c_type, name) \
        .equ    domain_field_caml_##name, domain_curr_field ; \
        .set    domain_curr_field, domain_curr_field + 8
#include "../runtime/caml/domain_state.tbl"
#undef DOMAIN_STATE

/* Access a domain state field - offset is already in bytes */
#define Caml_state(var) domain_field_caml_##var

/*=========================================================================*/
/* Stack switching structures - must match runtime/caml/fiber.h            */
/*=========================================================================*/

/* struct stack_info {
     void* sp;              // offset 0
     void* exception_ptr;   // offset 4
     void* handler;         // offset 8
   } */
#define Stack_sp            0
#define Stack_exception     4
#define Stack_handler       8
/* For accessing handler from a tagged continuation pointer:
   Stack_handler_from_cont = Stack_handler - 1 (to account for tag bit) */
#define Stack_handler_from_cont 7

/* struct c_stack_link {
     struct stack_info* stack;  // offset 0
     void* sp;                   // offset 4
     struct c_stack_link* prev;  // offset 8
     // padding to 16 bytes for alignment
   } */
#define Cstack_stack        0
#define Cstack_sp           4
#define Cstack_prev         8
#define SIZEOF_C_STACK_LINK 16

/* struct stack_handler {
     value handle_value;     // offset 0
     value handle_exception; // offset 4
     value handle_effect;    // offset 8
     struct stack_info* parent; // offset 12
   } */
#define Handler_value       0
#define Handler_exception   4
#define Handler_effect      8
#define Handler_parent      12

/*=========================================================================*/
/* Domain state access                                                     */
/*=========================================================================*/

/* Load domain state pointer into a register via TLS.
   On Linux/ELF, we use the %gs segment for thread-local storage.
   The @ntpoff suffix computes the negative offset from the thread pointer.
   Clobbers: destination register only */
#if defined(SYS_linux_elf) || defined(SYS_linux) || defined(SYS_bsd_elf) || defined(SYS_gnu)
#define LOAD_DOMAIN_STATE(dst) \
        movl    %gs:G(caml_state)@ntpoff, dst
#else
#error "i386 backend requires TLS support for domain state access"
#endif

/*=========================================================================*/
/* Stack alignment macros                                                  */
/*=========================================================================*/

/* PR#6038: GCC and Clang seem to require 16-byte alignment nowadays,
   even if only MacOS X's ABI formally requires it. */
#define ALIGN_STACK(amount) subl $ amount, %esp ; CFI_ADJUST(amount)
#define UNDO_ALIGN_STACK(amount) addl $ amount, %esp ; CFI_ADJUST(-amount)

/*=========================================================================*/
/* Stack switching macros (following ARM32 pattern)                        */
/*=========================================================================*/

/* Switch from OCaml to C stack.
   Assumes Caml_state is in register 'caml_state'.
   Clobbers: scratch1, scratch2
   After this macro, %esp points to the c_stack_link structure. */
#define SWITCH_OCAML_TO_C(caml_state, scratch1, scratch2) \
    /* Fill in Caml_state->current_stack->sp */ \
        movl    Caml_state(current_stack)(caml_state), scratch1; \
        movl    %esp, Stack_sp(scratch1); \
    /* Fill in Caml_state->c_stack */ \
        movl    Caml_state(c_stack)(caml_state), scratch2; \
        movl    scratch1, Cstack_stack(scratch2); \
        movl    %esp, Cstack_sp(scratch2); \
    /* Switch to C stack */ \
        movl    scratch2, %esp

/* Switch from C to OCaml stack.
   Clobbers: scratch */
#define SWITCH_C_TO_OCAML(scratch) \
        movl    Cstack_sp(%esp), scratch; \
        movl    scratch, %esp

/*=========================================================================*/
/* Register save/restore macros for GC                                     */
/*=========================================================================*/

/* Save all registers that may be in use to a gc_regs bucket.
   This matches the ARM implementation and fiber.h documentation.
   On i386, the allocatable registers are: eax, ebx, ecx, edx, esi, edi, ebp.
   Note: young_ptr is NOT saved here (see comment in macro body).

   Bucket layout (Wosize_gc_regs = 8 words):
     bucket[0]  = next pointer (when in freelist) / unused when active
     bucket[4]  = eax (register 0)
     bucket[8]  = ebx (register 1)
     bucket[12] = ecx (register 2)
     bucket[16] = edx (register 3)
     bucket[20] = esi (register 4)
     bucket[24] = edi (register 5)
     bucket[28] = ebp (register 6)

   After this macro, Caml_state(gc_regs) = bucket + 4, so gc_regs[i] = register i.
   Clobbers: ebx (loaded with domain state from TLS)
   Stack is unchanged after this macro. */
#define SAVE_ALL_REGS \
    /* Save ebx, esi, edi to stack (we need them as scratch and ebx will be clobbered) */ \
        pushl   %ebx; CFI_ADJUST(4); \
        pushl   %esi; CFI_ADJUST(4); \
        pushl   %edi; CFI_ADJUST(4); \
    /* Note: We do NOT save eax to Caml_state(young_ptr) here because: \
       - For GC calls: young_ptr is already updated in Caml_state by caml_allocN \
       - For stack realloc: eax contains the stack size, not young_ptr \
       RESTORE_ALL_REGS will reload young_ptr from Caml_state (possibly updated by GC). */ \
        LOAD_DOMAIN_STATE(%ebx); \
    /* Pop a bucket from gc_regs_buckets freelist */ \
        movl    Caml_state(gc_regs_buckets)(%ebx), %esi; \
        movl    0(%esi), %edi; /* next ptr */ \
        movl    %edi, Caml_state(gc_regs_buckets)(%ebx); \
    /* Save registers to bucket */ \
        movl    %eax, 4(%esi); \
        movl    8(%esp), %edi; /* original ebx from stack (pushed first) */ \
        movl    %edi, 8(%esi); \
        movl    %ecx, 12(%esi); \
        movl    %edx, 16(%esi); \
    /* Save ORIGINAL esi, edi from stack */ \
        movl    4(%esp), %edi; /* original esi was pushed second, at esp+4 */ \
        movl    %edi, 20(%esi); \
        movl    0(%esp), %edi; /* original edi was pushed last, at esp+0 */ \
        movl    %edi, 24(%esi); \
        movl    %ebp, 28(%esi); \
    /* Set gc_regs = bucket + 4 (past the 'next' slot) */ \
        addl    $4, %esi; \
        movl    %esi, Caml_state(gc_regs)(%ebx); \
    /* Restore esi, edi from stack and clean up (keep ebx as domain_state) */ \
        popl    %edi; CFI_ADJUST(-4); \
        popl    %esi; CFI_ADJUST(-4); \
        addl    $4, %esp; CFI_ADJUST(-4) /* discard saved ebx, ebx now holds domain_state */

/* Restore all registers from the gc_regs bucket and return bucket to freelist.
   Reloads young_ptr from Caml_state (since GC may have moved it).
   All registers including ebx are restored to their original values. */
#define RESTORE_ALL_REGS \
    /* Load bucket base from gc_regs */ \
        LOAD_DOMAIN_STATE(%ebx); \
        movl    Caml_state(gc_regs)(%ebx), %eax; \
        subl    $4, %eax; /* eax = bucket base */ \
    /* Restore registers from bucket (except eax which we're using, ebx which we restore last) */ \
        movl    12(%eax), %ecx; \
        movl    16(%eax), %edx; \
        movl    20(%eax), %esi; \
        movl    24(%eax), %edi; \
        movl    28(%eax), %ebp; \
    /* Save ecx so we can use it as temp for freelist operation */ \
        pushl   %ecx; CFI_ADJUST(4); \
    /* Put bucket back in freelist (ebx still holds domain state) */ \
        movl    Caml_state(gc_regs_buckets)(%ebx), %ecx; \
        movl    %ecx, 0(%eax); /* bucket->next = freelist head */ \
        movl    %eax, Caml_state(gc_regs_buckets)(%ebx); /* freelist head = bucket */ \
    /* Restore ecx */ \
        popl    %ecx; CFI_ADJUST(-4); \
    /* Save bucket pointer to stack so we can restore ebx and still access young_ptr */ \
        pushl   %eax; CFI_ADJUST(4); \
    /* Reload young_ptr (ebx still has domain_state) */ \
        movl    Caml_state(young_ptr)(%ebx), %eax; \
    /* Now restore original ebx from bucket (bucket ptr is on stack) */ \
        xchgl   %eax, (%esp); /* swap: eax = bucket ptr, stack = young_ptr */ \
        movl    8(%eax), %ebx; /* restore original ebx */ \
        popl    %eax; CFI_ADJUST(-4) /* eax = young_ptr */

/*=========================================================================*/
/* Return from C call macro                                                */
/*=========================================================================*/

/* Check if there is a pending action after returning from C.
   If so, poison young_limit to force a poll at the next allocation.
   Clobbers: scratch register */
#define RET_FROM_C_CALL(caml_state, scratch) \
        movl    Caml_state(action_pending)(caml_state), scratch; \
        testl   scratch, scratch; \
        jz      1f; \
        movl    $-1, Caml_state(young_limit)(caml_state); \
1:

/*=========================================================================*/
/* Exception handling macros                                               */
/*=========================================================================*/

/* Jump to the current exception handler.
   Trap frame layout (8 bytes, matching ARM):
     [esp+0] prev_handler
     [esp+4] trap_addr

   Clobbers: esp, scratch */
#define JUMP_TO_TRAP_PTR(caml_state, scratch) \
    /* Cut stack at current trap handler */ \
        movl    Caml_state(exn_handler)(caml_state), %esp; \
    /* Pop previous handler */ \
        popl    Caml_state(exn_handler)(caml_state); CFI_ADJUST(-4); \
    /* Return to trap address (now at esp after pop) */ \
        ret

/*=========================================================================*/
/* Switch between OCaml stacks (for fibers)                                */
/*=========================================================================*/

/* Switch between two OCaml stacks.
   old_stack and new_stack are registers containing stack_info pointers.
   Saves sp and exn_handler to old_stack, loads from new_stack.
   Clobbers: scratch
   Note: Caller should have pushed return address before calling. */
#define SWITCH_OCAML_STACKS(old_stack, new_stack, caml_state, scratch) \
    /* Save OCaml SP and exn_handler in the old stack info */ \
        movl    %esp, Stack_sp(old_stack); \
        movl    Caml_state(exn_handler)(caml_state), scratch; \
        movl    scratch, Stack_exception(old_stack); \
    /* Switch stacks */ \
        movl    new_stack, Caml_state(current_stack)(caml_state); \
        movl    Stack_sp(new_stack), %esp; \
    /* Restore exn_handler for new stack */ \
        movl    Stack_exception(new_stack), scratch; \
        movl    scratch, Caml_state(exn_handler)(caml_state)

/*=========================================================================*/
/* Code section                                                            */
/*=========================================================================*/

        .text
#if defined(FUNCTION_SECTIONS)
        TEXT_SECTION(caml_hot.code_begin)
        .globl  G(caml_hot.code_begin)
G(caml_hot.code_begin):

        TEXT_SECTION(caml_hot.code_end)
        .globl  G(caml_hot.code_end)
G(caml_hot.code_end):
#endif

/*=========================================================================*/
/* Allocation functions                                                    */
/*=========================================================================*/

        TEXT_SECTION(caml_system__code_begin)
        .globl  G(caml_system__code_begin)
G(caml_system__code_begin):

FUNCTION(caml_call_gc)
        CFI_STARTPROC
LBL(caml_call_gc):
    /* Note: The old STACK_PROBE_SIZE check was removed because with OCaml 5.x
       multicore fiber-based stacks, stack overflow is handled by explicit checks
       at function entry (calling caml_call_realloc_stack), not by signal handlers.
       Probing 16KB below esp with fixed-size fiber stacks would corrupt memory. */
    /* Save all registers to gc_regs bucket */
        SAVE_ALL_REGS
    /* Get domain state and set up Stack_sp for scanning.
       Scanning uses: sp = First_frame(Stack_sp) = Stack_sp + 8
                      retaddr = Saved_return_address_raw(sp) = *(sp - 4) = *(Stack_sp + 4)
       So return address must be at Stack_sp + 4. Return addr is at esp, so Stack_sp = esp - 4. */
        LOAD_DOMAIN_STATE(%ebx)
        movl    Caml_state(current_stack)(%ebx), %ecx
        leal    -4(%esp), %eax
        movl    %eax, Stack_sp(%ecx)
    /* Set up Caml_state->c_stack */
        movl    Caml_state(c_stack)(%ebx), %edi
        movl    %ecx, Cstack_stack(%edi)
        movl    %esp, Cstack_sp(%edi)
    /* Switch to C stack */
        movl    %edi, %esp
    /* Call the garbage collector */
        call    G(caml_garbage_collection)
    /* Switch back to OCaml stack */
        movl    Cstack_sp(%esp), %eax
        movl    %eax, %esp
    /* Restore all registers */
        RESTORE_ALL_REGS
    /* Return to caller */
        ret
        CFI_ENDPROC
        ENDFUNCTION(caml_call_gc)

FUNCTION(caml_alloc1)
        CFI_STARTPROC
        LOAD_DOMAIN_STATE(%ebx)
        movl    Caml_state(young_ptr)(%ebx), %eax
        subl    $8, %eax
        movl    %eax, Caml_state(young_ptr)(%ebx)
        cmpl    Caml_state(young_limit)(%ebx), %eax
        jb      LBL(caml_call_gc)
        ret
        CFI_ENDPROC
        ENDFUNCTION(caml_alloc1)

FUNCTION(caml_alloc2)
        CFI_STARTPROC
        LOAD_DOMAIN_STATE(%ebx)
        movl    Caml_state(young_ptr)(%ebx), %eax
        subl    $12, %eax
        movl    %eax, Caml_state(young_ptr)(%ebx)
        cmpl    Caml_state(young_limit)(%ebx), %eax
        jb      LBL(caml_call_gc)
        ret
        CFI_ENDPROC
        ENDFUNCTION(caml_alloc2)

FUNCTION(caml_alloc3)
        CFI_STARTPROC
        LOAD_DOMAIN_STATE(%ebx)
        movl    Caml_state(young_ptr)(%ebx), %eax
        subl    $16, %eax
        movl    %eax, Caml_state(young_ptr)(%ebx)
        cmpl    Caml_state(young_limit)(%ebx), %eax
        jb      LBL(caml_call_gc)
        ret
        CFI_ENDPROC
        ENDFUNCTION(caml_alloc3)

FUNCTION(caml_allocN)
        CFI_STARTPROC
        LOAD_DOMAIN_STATE(%ebx)
        /* eax = size - Caml_state->young_ptr */
        subl    Caml_state(young_ptr)(%ebx), %eax
        negl    %eax              /* eax = Caml_state->young_ptr - size */
        movl    %eax, Caml_state(young_ptr)(%ebx)
        cmpl    Caml_state(young_limit)(%ebx), %eax
        jb      LBL(caml_call_gc)
        ret
        CFI_ENDPROC
        ENDFUNCTION(caml_allocN)

/*=========================================================================*/
/* Stack reallocation                                                      */
/*=========================================================================*/

FUNCTION(caml_call_realloc_stack)
        CFI_STARTPROC
    /* Save return address (already on stack) and callee-saves */
        pushl   %ebp; CFI_ADJUST(4)
        pushl   %edi; CFI_ADJUST(4)
        pushl   %esi; CFI_ADJUST(4)
        pushl   %ebx; CFI_ADJUST(4)
    /* Save all registers to gc_regs bucket */
        SAVE_ALL_REGS
    /* Get argument (desired stack size) from stack
       With bucket-based gc_regs, stack only has callee-saves:
       Stack layout: [16 bytes callee-saves] [ret addr] [arg]
       arg is at esp + 16 + 4 = esp + 20 */
        movl    20(%esp), %eax
    /* Switch to C stack (inline, not using SWITCH_OCAML_TO_C macro)
       Stack layout: [ebx][esi][edi][ebp][retaddr][arg]
       IMPORTANT: Stack_sp must be saved as %esp (not %esp + offset) so that
       when caml_try_realloc_stack copies the stack content, all pushed
       callee-save registers are included in the copy. */
        LOAD_DOMAIN_STATE(%ebx)
        movl    Caml_state(current_stack)(%ebx), %esi
        movl    %esp, Stack_sp(%esi)
        movl    Caml_state(c_stack)(%ebx), %edi
        movl    %esi, Cstack_stack(%edi)
        movl    %esp, Cstack_sp(%edi)
        movl    %edi, %esp
    /* Push argument onto C stack and call caml_try_realloc_stack */
        pushl   %eax; CFI_ADJUST(4)
        call    G(caml_try_realloc_stack)
        addl    $4, %esp; CFI_ADJUST(-4)        /* pop argument */
    /* Switch back to OCaml stack - esp still points to c_stack_link */
        movl    Cstack_sp(%esp), %ecx
        movl    %ecx, %esp
    /* Check result */
        testl   %eax, %eax
        jz      LBL(realloc_stack_failed)
    /* Success: restore registers and return */
        RESTORE_ALL_REGS
        popl    %ebx; CFI_ADJUST(-4)
        popl    %esi; CFI_ADJUST(-4)
        popl    %edi; CFI_ADJUST(-4)
        popl    %ebp; CFI_ADJUST(-4)
        ret
LBL(realloc_stack_failed):
    /* Failure: raise Stack_overflow */
        RESTORE_ALL_REGS
        popl    %ebx; CFI_ADJUST(-4)
        popl    %esi; CFI_ADJUST(-4)
        popl    %edi; CFI_ADJUST(-4)
        popl    %ebp; CFI_ADJUST(-4)
        addl    $4, %esp; CFI_ADJUST(-4)  /* pop return address */
        addl    $4, %esp; CFI_ADJUST(-4)  /* pop argument */
        movl    $G(caml_exn_Stack_overflow), %eax
        jmp     G(caml_raise_exn)
        CFI_ENDPROC
        ENDFUNCTION(caml_call_realloc_stack)

/*=========================================================================*/
/* Call a C function from OCaml                                            */
/*=========================================================================*/

/* Function address is in %eax, end of stack args is in %ecx
   Following ARM32 pattern:
   1. Save OCaml registers onto OCaml stack
   2. Save current_stack->sp and c_stack info for GC stack walking
   3. Switch to C stack
   4. Copy C args from OCaml stack to C stack
   5. Call C function
   6. Switch back to OCaml stack
   7. Restore OCaml registers
   8. Check for pending actions */

FUNCTION(caml_c_call)
        CFI_STARTPROC
    /* Arguments: eax = C func addr, ecx = end of args
       Save callee-save registers on OCaml stack */
        pushl   %ebp; CFI_ADJUST(4)
        pushl   %edi; CFI_ADJUST(4)
        pushl   %esi; CFI_ADJUST(4)
        pushl   %ebx; CFI_ADJUST(4)

    /* Save C function addr and arg_end */
        movl    %eax, %edx              /* edx = C func addr */
        movl    %ecx, %ebp              /* ebp = arg_end (temporarily) */

    /* Get Caml_state pointer */
        LOAD_DOMAIN_STATE(%ebx)

    /* Fill in Caml_state->current_stack->sp
       Stack layout: [ebx][esi][edi][ebp][retaddr]...
       Return address is at esp+16. Scanning uses *(Stack_sp + 4) to read it.
       So Stack_sp = (esp+16) - 4 = esp + 12. */
        movl    Caml_state(current_stack)(%ebx), %esi
        leal    12(%esp), %eax
        movl    %eax, Stack_sp(%esi)

    /* Fill in Caml_state->c_stack */
        movl    Caml_state(c_stack)(%ebx), %edi
        movl    %esi, Cstack_stack(%edi)
        movl    %esp, Cstack_sp(%edi)

    /* Calculate arg_begin = esp + 20 (past saved regs + ret addr) */
        leal    20(%esp), %esi
        movl    %ebp, %ecx              /* ecx = arg_end (restore from ebp) */

    /* Switch to C stack */
        movl    %edi, %esp

    /* Copy arguments from OCaml stack to C stack (high to low) */
LBL(c_call_copy_args):
        cmpl    %esi, %ecx
        jbe     LBL(c_call_args_done)
        subl    $4, %ecx
        pushl   (%ecx); CFI_ADJUST(4)
        jmp     LBL(c_call_copy_args)

LBL(c_call_args_done):
    /* Call C function */
        call    *%edx

    /* Restore OCaml stack */
        LOAD_DOMAIN_STATE(%ebx)
        movl    Caml_state(c_stack)(%ebx), %edi
        movl    Cstack_sp(%edi), %esp

    /* NOTE: Do NOT reload young_ptr into %eax here!
       %eax contains the C function's return value which must be preserved.
       On i386 (unlike ARM), young_ptr is not kept in a register -
       allocators load it from Caml_state when needed. */

    /* Check for pending actions */
        RET_FROM_C_CALL(%ebx, %ecx)

    /* Restore OCaml callee-save registers */
        popl    %ebx; CFI_ADJUST(-4)
        popl    %esi; CFI_ADJUST(-4)
        popl    %edi; CFI_ADJUST(-4)
        popl    %ebp; CFI_ADJUST(-4)

    /* Return to OCaml caller */
        ret
        CFI_ENDPROC
        ENDFUNCTION(caml_c_call)

/*=========================================================================*/
/* Start the OCaml program                                                 */
/*=========================================================================*/

FUNCTION(caml_start_program)
        CFI_STARTPROC
    /* Save callee-save registers */
        pushl   %ebx; CFI_ADJUST(4)
        pushl   %esi; CFI_ADJUST(4)
        pushl   %edi; CFI_ADJUST(4)
        pushl   %ebp; CFI_ADJUST(4)
    /* Domain state is passed as first argument from C */
        movl    20(%esp), %edi
    /* Initial entry point is caml_program */
        movl    $ G(caml_program), %esi
    /* Common code for caml_start_program and caml_callback* */
LBL(caml_start_program_common):
    /* Save callback arguments that will be clobbered during setup.
       These will be restored from the C stack (via ebp) just before the call.
       Stack layout after this: [eax][ebx][ecx][c_stack_link...] */
        pushl   %eax; CFI_ADJUST(4)
        pushl   %ebx; CFI_ADJUST(4)
        pushl   %ecx; CFI_ADJUST(4)
    /* Note: On i386, young_ptr is NOT cached in a register like ARM.
       Each allocation accesses it from domain state directly.
       So no need to load it here. */
    /* Build struct c_stack_link on the C stack */
        subl    $SIZEOF_C_STACK_LINK, %esp; CFI_ADJUST(SIZEOF_C_STACK_LINK)
        movl    $0, Cstack_stack(%esp)
        movl    $0, Cstack_sp(%esp)
        movl    Caml_state(c_stack)(%edi), %ebx
        movl    %ebx, Cstack_prev(%esp)
        movl    %esp, Caml_state(c_stack)(%edi)
    /* Load the OCaml stack */
        movl    Caml_state(current_stack)(%edi), %ebx
        movl    Stack_sp(%ebx), %ebx
    /* Build 16-byte stack header (Stack_header_size from stack.h):
       This matches the ARM layout with 8-byte trap frames:
       sp+0:  prev exn_handler  (trap frame part 1)
       sp+4:  trap handler addr (trap frame part 2)
       sp+8:  gc_regs (Saved_gc_regs expects sp+8)
       sp+12: DWARF C_stack_sp (for debugger) */
        subl    $16, %ebx
        movl    Caml_state(exn_handler)(%edi), %ecx
        movl    %ecx, 0(%ebx)
        movl    $ LBL(trap_handler), 4(%ebx)
        movl    Caml_state(gc_regs)(%edi), %ecx
        movl    %ecx, 8(%ebx)
        movl    %esp, 12(%ebx)
        movl    %ebx, Caml_state(exn_handler)(%edi)
    /* Switch stacks and call the OCaml code */
        movl    %esp, %ebp
        movl    %ebx, %esp
        CFI_REMEMBER_STATE
    /* Restore callback arguments from C stack (ebp points to c_stack_link,
       saved args are above it: ecx at ebp+16, ebx at ebp+20, eax at ebp+24) */
        movl    16(%ebp), %ecx
        movl    20(%ebp), %ebx
        movl    24(%ebp), %eax
    /* Call the OCaml code */
        call    *%esi
LBL(caml_retaddr):
    /* Pop the 8-byte trap frame, restoring Caml_state->exn_handler */
        LOAD_DOMAIN_STATE(%edi)
        movl    0(%esp), %ecx
        movl    %ecx, Caml_state(exn_handler)(%edi)
        addl    $8, %esp
LBL(return_result):
    /* After 8-byte trap frame, esp points to gc_regs (offset 8 of 16-byte header)
       Layout: [gc_regs][c_stack_sp] = 8 bytes remaining */
        movl    0(%esp), %edx
        movl    %edx, Caml_state(gc_regs)(%edi)
        addl    $8, %esp
    /* Note: On i386, young_ptr is NOT cached in a register like ARM.
       Each allocation accesses it directly from domain state.
       So we do NOT save/restore young_ptr here - eax has the return value. */
    /* Return to C stack - use Caml_state(c_stack), not the saved value */
        movl    Caml_state(current_stack)(%edi), %ebx
        movl    %esp, Stack_sp(%ebx)
        movl    Caml_state(c_stack)(%edi), %ecx
        movl    %ecx, %esp
        CFI_RESTORE_STATE
    /* Pop the struct c_stack_link */
        movl    Cstack_prev(%esp), %ebx
        movl    %ebx, Caml_state(c_stack)(%edi)
        addl    $SIZEOF_C_STACK_LINK, %esp; CFI_ADJUST(-SIZEOF_C_STACK_LINK)
    /* Pop the saved callback arguments (we pushed eax, ebx, ecx before c_stack_link) */
        addl    $12, %esp; CFI_ADJUST(-12)
    /* Restore callee-save registers */
        popl    %ebp; CFI_ADJUST(-4)
        popl    %edi; CFI_ADJUST(-4)
        popl    %esi; CFI_ADJUST(-4)
        popl    %ebx; CFI_ADJUST(-4)
    /* Return to caller */
        ret
LBL(trap_handler):
    /* Exception handler */
    /* Mark the bucket as an exception result and return it */
        orl     $2, %eax
        LOAD_DOMAIN_STATE(%edi)
        jmp     LBL(return_result)
        CFI_ENDPROC
        ENDFUNCTION(caml_start_program)

/*=========================================================================*/
/* Exceptions                                                              */
/*=========================================================================*/

/* Raise an exception from OCaml */
FUNCTION(caml_raise_exn)
        CFI_STARTPROC
        LOAD_DOMAIN_STATE(%ebx)
        testl   $1, Caml_state(backtrace_active)(%ebx)
        jne     LBL(raise_with_backtrace)
    /* No backtrace: just jump to handler */
        JUMP_TO_TRAP_PTR(%ebx, %ecx)
LBL(raise_with_backtrace):
    /* Zero backtrace_pos */
        movl    $0, Caml_state(backtrace_pos)(%ebx)
LBL(reraise_with_backtrace):
    /* Save arguments in callee-save registers:
       esi = exn, edi = trapsp, ebp = pc */
        movl    %eax, %esi                      /* esi = exn */
        movl    Caml_state(exn_handler)(%ebx), %edi  /* edi = trapsp */
        movl    0(%esp), %ebp                   /* ebp = pc (return address) */
        leal    4(%esp), %eax                   /* eax = sp (OCaml stack + 4) */
    /* Switch to C stack */
        movl    Caml_state(c_stack)(%ebx), %ecx
        movl    %ecx, %esp
    /* Push OCaml sp first (we'll need it to switch back) then arguments */
        pushl   %eax; CFI_ADJUST(4)             /* save OCaml sp for later */
        pushl   %edi; CFI_ADJUST(4)             /* arg4: trapsp */
        pushl   %eax; CFI_ADJUST(4)             /* arg3: sp (OCaml stack) */
        pushl   %ebp; CFI_ADJUST(4)             /* arg2: pc */
        pushl   %esi; CFI_ADJUST(4)             /* arg1: exn */
        call    G(caml_stash_backtrace)
        addl    $16, %esp; CFI_ADJUST(-16)      /* pop arguments */
    /* Switch back to OCaml stack */
        popl    %esp; CFI_ADJUST(-4)            /* restore OCaml sp */
        movl    %esi, %eax                      /* restore exn to eax */
        LOAD_DOMAIN_STATE(%ebx)
        JUMP_TO_TRAP_PTR(%ebx, %ecx)
        CFI_ENDPROC
        ENDFUNCTION(caml_raise_exn)

FUNCTION(caml_reraise_exn)
        CFI_STARTPROC
        LOAD_DOMAIN_STATE(%ebx)
        testl   $1, Caml_state(backtrace_active)(%ebx)
        jne     LBL(reraise_with_backtrace)
        JUMP_TO_TRAP_PTR(%ebx, %ecx)
        CFI_ENDPROC
        ENDFUNCTION(caml_reraise_exn)

/* Raise an exception from C */
/* This is called from C when an exception should propagate to OCaml.
   We need to switch from the C stack back to the OCaml stack first.
   Like AMD64, we use Stack_sp directly rather than assuming a specific
   register-saving pattern, because different entry points (caml_c_call,
   caml_call_gc) have different patterns. */
FUNCTION(caml_raise_exception)
        CFI_STARTPROC
    /* Arguments: domain_state in 4(%esp), exn bucket in 8(%esp) */
        movl    4(%esp), %ebx
        movl    8(%esp), %eax                  /* eax = exception bucket */
    /* Discard the C stack and switch back to the OCaml stack.
       Use Stack_sp from current_stack directly (like AMD64).
       For i386, Stack_sp + 4 = return address (per stack.h convention).
       caml_raise_exn expects return address at 0(%esp), so set esp = Stack_sp + 4. */
        movl    Caml_state(current_stack)(%ebx), %ecx
        movl    Stack_sp(%ecx), %esp
        addl    $4, %esp                       /* esp now points to return address */
    /* Now we're back on the OCaml stack, jump to caml_raise_exn */
        jmp     G(caml_raise_exn)
        CFI_ENDPROC
        ENDFUNCTION(caml_raise_exception)

/*=========================================================================*/
/* Callbacks from C to OCaml                                               */
/*=========================================================================*/

FUNCTION(caml_callback_asm)
        CFI_STARTPROC
    /* Save callee-save registers */
        pushl   %ebx; CFI_ADJUST(4)
        pushl   %esi; CFI_ADJUST(4)
        pushl   %edi; CFI_ADJUST(4)
        pushl   %ebp; CFI_ADJUST(4)
    /* Initial loading of arguments */
        movl    20(%esp), %edi
        movl    24(%esp), %ebx
        movl    28(%esp), %ecx
        movl    0(%ecx), %eax
        movl    0(%ebx), %esi
        jmp     LBL(caml_start_program_common)
        CFI_ENDPROC
ENDFUNCTION(caml_callback_asm)

FUNCTION(caml_callback2_asm)
        CFI_STARTPROC
    /* Save callee-save registers */
        pushl   %ebx; CFI_ADJUST(4)
        pushl   %esi; CFI_ADJUST(4)
        pushl   %edi; CFI_ADJUST(4)
        pushl   %ebp; CFI_ADJUST(4)
    /* Initial loading of arguments */
        movl    20(%esp), %edi
        movl    24(%esp), %ecx
        movl    28(%esp), %edx
        movl    0(%edx), %eax
        movl    4(%edx), %ebx
        movl    $ G(caml_apply2), %esi
        jmp     LBL(caml_start_program_common)
        CFI_ENDPROC
ENDFUNCTION(caml_callback2_asm)

FUNCTION(caml_callback3_asm)
        CFI_STARTPROC
    /* Save callee-save registers */
        pushl   %ebx; CFI_ADJUST(4)
        pushl   %esi; CFI_ADJUST(4)
        pushl   %edi; CFI_ADJUST(4)
        pushl   %ebp; CFI_ADJUST(4)
    /* Initial loading of arguments */
        movl    20(%esp), %edi
        movl    24(%esp), %edx
        movl    28(%esp), %ecx
        movl    0(%ecx), %eax
        movl    4(%ecx), %ebx
        movl    8(%ecx), %ecx
        movl    $ G(caml_apply3), %esi
        jmp     LBL(caml_start_program_common)
        CFI_ENDPROC
ENDFUNCTION(caml_callback3_asm)

/*=========================================================================*/
/* Fibers (effect handlers)                                                */
/*=========================================================================*/

/* caml_perform: perform an effect
   Arguments:
     eax: effect to perform
     ebx: freshly allocated continuation (1-word Cont_tag block)
   Following amd64 semantics: cont[0] = cont_tail (Val_ptr of last fiber).
   Handler_parent(Stack_handler(cont_tail)) = cont_head (first fiber). */
FUNCTION(caml_perform)
        CFI_STARTPROC
        LOAD_DOMAIN_STATE(%edi)
        movl    Caml_state(current_stack)(%edi), %ecx  /* ecx = current_stack */
        leal    1(%ecx), %edx                          /* edx = Val_ptr(current_stack) */
        movl    %edx, 0(%ebx)                          /* cont[0] = Val_ptr(current_stack) */
        movl    %ecx, %edx                             /* edx = cont_head */
LBL(do_perform):
    /*  eax: effect to perform
        ebx: continuation
        ecx: old_stack (the stack being captured)
        edx: cont_head (first fiber in continuation chain) */
        movl    Stack_handler(%ecx), %esi              /* esi = handler */
        movl    Handler_parent(%esi), %edi             /* edi = parent stack */
        testl   %edi, %edi
        jz      LBL(perform_no_parent)
    /* Push callee-saves FIRST (matching runstack's pattern).
       This ensures Stack_sp has the correct layout for fiber_return_common. */
        pushl   %ebp; CFI_ADJUST(4)
        pushl   %edi; CFI_ADJUST(4)
        pushl   %esi; CFI_ADJUST(4)
    /* Now stack: [esi][edi][ebp][return_addr]
       Save Stack_sp = esp+8, so First_frame(Stack_sp) = esp+16
       which is the caller's frame above the return address. */
        LOAD_DOMAIN_STATE(%ebp)
        leal    8(%esp), %esi
        movl    %esi, Stack_sp(%ecx)
        movl    Caml_state(exn_handler)(%ebp), %esi
        movl    %esi, Stack_exception(%ecx)
    /* Push values we need after the switch (below Stack_sp).
       Compute new_cont_tail_val = Val_ptr(old_stack) = ecx + 1.
       Stack: [cont][effect][new_tail][cont_head][handler][esi][edi][ebp][retaddr] */
        movl    Stack_handler(%ecx), %esi              /* esi = handler (reload) */
        leal    1(%ecx), %ecx                          /* ecx = Val_ptr(old_stack) */
        pushl   %esi; CFI_ADJUST(4)                    /* save handler */
        pushl   %edx; CFI_ADJUST(4)                    /* save cont_head */
        pushl   %ecx; CFI_ADJUST(4)                    /* save new cont_tail val */
        pushl   %eax; CFI_ADJUST(4)                    /* save effect */
        pushl   %ebx; CFI_ADJUST(4)                    /* save continuation */
    /* Save pointer to values for loading after switch */
        movl    %esp, %edx                             /* edx = pointer to saved values */
    /* Switch to parent stack (edi still holds parent from before pushes) */
        movl    %edi, Caml_state(current_stack)(%ebp)
        movl    Stack_sp(%edi), %eax                   /* eax = parent Stack_sp */
        movl    Stack_exception(%edi), %esi
        movl    %esi, Caml_state(exn_handler)(%ebp)
    /* Load callee-saves that runstack/resume pushed on parent.
       Stack_sp points to ebp; layout: [-8]=esi, [-4]=edi, [0]=ebp, [+4]=retaddr */
        movl    -8(%eax), %esi
        movl    -4(%eax), %edi
        movl    0(%eax), %ebp
    /* Set esp to return address position (past callee-saves) */
        leal    4(%eax), %esp; CFI_ADJUST(-32)
    /* Load saved values from fiber stack (edx still points there) */
        movl    0(%edx), %ebx                          /* continuation */
        movl    4(%edx), %eax                          /* effect */
        movl    8(%edx), %edi                          /* new cont_tail val */
        movl    12(%edx), %ecx                         /* cont_head */
        movl    16(%edx), %esi                         /* handler */
    /* Update cont[0] with new cont_tail (needed for reperform path) */
        movl    %edi, 0(%ebx)                          /* cont[0] = new cont_tail val */
    /* Set handler's parent to cont_head (so resume can find cont_head) */
        movl    %ecx, Handler_parent(%esi)
    /* Get effect handler closure and call caml_apply2.
       caml_apply2: eax=arg1(effect), ebx=arg2(continuation), ecx=closure */
        movl    Handler_effect(%esi), %ecx             /* ecx = effect handler closure */
        jmp     G(caml_apply2)

LBL(perform_no_parent):
    /* No parent stack - switch back to cont_head and raise Unhandled.
       At entry: eax=effect, ecx=old_stack, edx=cont_head */
        cmpl    %ecx, %edx
        je      LBL(perform_raise_unhandled)
    /* Save current stack and switch to cont_head */
        pushl   %ebp; CFI_ADJUST(4)
        pushl   %edi; CFI_ADJUST(4)
        pushl   %esi; CFI_ADJUST(4)
        LOAD_DOMAIN_STATE(%ebp)
        leal    8(%esp), %esi
        movl    %esi, Stack_sp(%ecx)
        movl    Caml_state(exn_handler)(%ebp), %esi
        movl    %esi, Stack_exception(%ecx)
    /* Switch to cont_head (edx) */
        movl    %edx, Caml_state(current_stack)(%ebp)
        movl    Stack_sp(%edx), %esi
        leal    -8(%esi), %esp
        movl    Stack_exception(%edx), %esi
        movl    %esi, Caml_state(exn_handler)(%ebp)
    /* Skip callee-saves to get to return_addr */
        addl    $12, %esp; CFI_ADJUST(-12)
LBL(perform_raise_unhandled):
    /* Call caml_raise_unhandled_effect via caml_c_call.
       Effect is in eax. */
        pushl   %eax                                   /* push effect as C argument */
        pushl   $0                                     /* dummy return address */
        movl    $G(caml_raise_unhandled_effect), %eax
        leal    8(%esp), %ecx                          /* ecx = just past effect */
        jmp     G(caml_c_call)
        CFI_ENDPROC
        ENDFUNCTION(caml_perform)

/* caml_reperform: reperform an effect
   Arguments:
     eax: effect to perform
     ebx: continuation
   Following amd64 semantics: read cont[0] to get current cont_tail,
   derive cont_head, link current stack into chain. */
FUNCTION(caml_reperform)
        CFI_STARTPROC
    /* Read cont_tail from cont[0] (tagged pointer) */
        movl    0(%ebx), %ecx                          /* ecx = cont[0] = Val_ptr(cont_tail) */
    /* Get handler of cont_tail (use -1 offset to account for tag bit) */
        movl    Stack_handler_from_cont(%ecx), %esi    /* esi = handler of cont_tail */
    /* Read cont_head from handler's parent (set by previous do_perform) */
        movl    Handler_parent(%esi), %edx             /* edx = cont_head */
    /* Link current stack as parent of cont_tail's handler */
        LOAD_DOMAIN_STATE(%edi)
        movl    Caml_state(current_stack)(%edi), %ecx  /* ecx = current_stack */
        movl    %ecx, Handler_parent(%esi)             /* cont_tail.handler->parent = current */
    /* Set up registers for do_perform:
       ecx = old_stack (current stack)
       edx = cont_head (unchanged) */
        jmp     LBL(do_perform)
        CFI_ENDPROC
        ENDFUNCTION(caml_reperform)

/* caml_resume: resume a continuation
   Arguments (3 args, matching amd64 semantics):
     eax: Val_ptr(cont_tail) - tagged pointer to last fiber in continuation
     ebx: function closure
     ecx: argument
   Derives cont_head from Handler_parent(Stack_handler(cont_tail)). */
FUNCTION(caml_resume)
        CFI_STARTPROC
    /* Save callee-saves like runstack does, so return path can pop them */
        pushl   %ebp; CFI_ADJUST(4)
        pushl   %edi; CFI_ADJUST(4)
        pushl   %esi; CFI_ADJUST(4)
    /* Untag cont_tail pointer */
        subl    $1, %eax                               /* eax = cont_tail (untagged) */
    /* Check if stack is null (already resumed) */
        testl   %eax, %eax
        jz      LBL(resume_already_resumed)
    /* Derive cont_head from cont_tail.
       cont_head = Handler_parent(Stack_handler(cont_tail))
       This was set by do_perform when the continuation was captured. */
        movl    Stack_handler(%eax), %edx              /* edx = Stack_handler(cont_tail) */
        movl    Handler_parent(%edx), %edi             /* edi = cont_head */
    /* Link current stack as parent of cont_tail's handler.
       This overwrites the cont_head link, but we already saved it in edi. */
        LOAD_DOMAIN_STATE(%esi)
        movl    Caml_state(current_stack)(%esi), %ebp  /* ebp = current stack */
        movl    %ebp, Handler_parent(%edx)             /* cont_tail.handler->parent = current */
    /* Save old stack state. Stack: [esi][edi][ebp][return_addr]...
       Save Stack_sp = esp+8 for GC scanning (see runstack comment). */
        leal    8(%esp), %edx                          /* edx = esp + 8 */
        movl    %edx, Stack_sp(%ebp)
        movl    Caml_state(exn_handler)(%esi), %edx
        movl    %edx, Stack_exception(%ebp)
    /* Switch to cont_head (edi). */
        movl    %edi, Caml_state(current_stack)(%esi)
        movl    Stack_sp(%edi), %edx                   /* edx = cont_head's Stack_sp */
        leal    -8(%edx), %esp                         /* esp = Stack_sp - 8 */
        movl    Stack_exception(%edi), %edx
        movl    %edx, Caml_state(exn_handler)(%esi)
    /* Pop callee-saves that perform pushed on cont_head's stack.
       Stack layout: [...][esi][edi][ebp][return_addr]
       Stack_sp points to [ebp], so esp = Stack_sp - 8 = &esi.
       After popping callee-saves, esp points to return_addr. */
        popl    %esi; CFI_ADJUST(-4)
        popl    %edi; CFI_ADJUST(-4)
        popl    %ebp; CFI_ADJUST(-4)
    /* Now esp points to return_addr. Call the function (tail call).
       When function returns via ret, it returns to perform's caller. */
        movl    0(%ebx), %edx                          /* edx = code pointer */
        movl    %ecx, %eax                             /* eax = argument */
        jmp     *%edx

LBL(resume_already_resumed):
    /* Raise Continuation_already_resumed - we already pushed callee-saves
       at the start of resume, just need to pop them */
        popl    %esi; CFI_ADJUST(-4)
        popl    %edi; CFI_ADJUST(-4)
        popl    %ebp; CFI_ADJUST(-4)
        movl    $G(caml_raise_continuation_already_resumed), %eax
        movl    %esp, %ecx
        jmp     G(caml_c_call)
        CFI_ENDPROC
        ENDFUNCTION(caml_resume)

/* caml_runstack: run a function on a new stack
   Arguments:
     eax: stack (tagged)
     ebx: function closure
     ecx: argument */
FUNCTION(caml_runstack)
        CFI_STARTPROC
        pushl   %ebp; CFI_ADJUST(4)
        pushl   %edi; CFI_ADJUST(4)
        pushl   %esi; CFI_ADJUST(4)
        subl    $1, %eax                               /* eax = Ptr_val(stack) */
        movl    0(%ebx), %edx                          /* edx = code pointer */
        movl    %ebx, %ebp                             /* ebp = closure (save for call) */
    /* Save old stack info. Stack: [esi][edi][ebp][ret_addr]...
       For GC scanning: First_frame(sp) = sp+8, Saved_return_address_raw(sp) = *(sp-4)
       So scanner reads *(Stack_sp+4) as return address.
       With [esi][edi][ebp][ret] at esp, we need *(Stack_sp+4) = ret.
       Thus Stack_sp = esp+8 (pointing to ebp), so Stack_sp+4 = esp+12 = &ret. */
        LOAD_DOMAIN_STATE(%ebx)
        movl    Caml_state(current_stack)(%ebx), %esi  /* esi = old stack */
        leal    8(%esp), %edi                          /* Stack_sp = esp + 8 */
        movl    %edi, Stack_sp(%esi)
        movl    Caml_state(exn_handler)(%ebx), %edi
        movl    %edi, Stack_exception(%esi)
    /* Set parent of new stack's handler */
        movl    Stack_handler(%eax), %edi
        movl    %esi, Handler_parent(%edi)
    /* Switch to new stack */
        movl    %eax, Caml_state(current_stack)(%ebx)
        movl    Stack_sp(%eax), %edi                   /* edi = new stack sp */
    /* Build 16-byte stack header for fiber (matching Stack_header_size):
       [0] prev_handler (trap frame part 1)
       [4] trap_addr (trap frame part 2)
       [8] gc_regs (Saved_gc_regs expects sp+8)
       [12] unused */
        subl    $16, %edi
    /* Store gc_regs at offset 8 (matching Saved_gc_regs macro) */
        movl    Caml_state(gc_regs)(%ebx), %esi
        movl    %esi, 8(%edi)
    /* Store exception handler address at offset 4 */
        movl    $LBL(fiber_exn_handler), 4(%edi)
    /* Link previous exn_handler at offset 0 */
        movl    Stack_exception(%eax), %esi
        movl    %esi, 0(%edi)
    /* Set as current exn_handler */
        movl    %edi, Caml_state(exn_handler)(%ebx)
    /* Switch to new stack */
        movl    %edi, %esp
        CFI_REMEMBER_STATE
    /* Call the function: restore closure to ebx before call */
        movl    %ebp, %ebx                             /* ebx = closure (restored) */
        movl    %ecx, %eax                             /* arg */
        call    *%edx
LBL(frame_runstack):
    /* Normal return from fiber - header is 16 bytes */
        leal    16(%esp), %esi                         /* esi = handler (past 16-byte header) */
        movl    Handler_value(%esi), %edi              /* edi = handle_value closure */
        jmp     LBL(fiber_return_common)

LBL(fiber_exn_handler):
    /* Exception return from fiber
       JUMP_TO_TRAP_PTR leaves esp 8 bytes past exn_handler (past trap frame)
       Handler is at 16 bytes from original header = esp+8 */
        leal    8(%esp), %esi                          /* esi = handler */
        movl    Handler_exception(%esi), %edi          /* edi = handle_exception closure */

LBL(fiber_return_common):
    /* Common return path for fiber
       eax = return value or exception
       esi = handler
       edi = handler closure to call */
        movl    %eax, %ebx                             /* save result */
        LOAD_DOMAIN_STATE(%ecx)
        movl    Caml_state(current_stack)(%ecx), %eax  /* arg to caml_free_stack */
    /* Get parent stack */
        movl    Handler_parent(%esi), %edx
        movl    %edx, Caml_state(current_stack)(%ecx)
        movl    Stack_exception(%edx), %esi
        movl    %esi, Caml_state(exn_handler)(%ecx)
        movl    Stack_sp(%edx), %ebp                   /* save parent sp (points to ebp slot) */
    /* Free old stack - switch to c_stack for this */
        movl    Caml_state(c_stack)(%ecx), %esp
        pushl   %eax; CFI_ADJUST(4)
        call    G(caml_free_stack)
        addl    $4, %esp; CFI_ADJUST(-4)
    /* Switch to parent stack. Stack_sp was saved as esp+8, so subtract 8
       to get back to the callee-saves: [esi][edi][ebp][ret] */
        leal    -8(%ebp), %esp
        CFI_RESTORE_STATE
    /* Call handler: eax = result, ebx = handler closure */
        movl    %ebx, %eax                             /* result */
        movl    0(%edi), %edx                          /* code pointer */
        movl    %edi, %ebx                             /* closure */
    /* Restore callee-saves and tail-call */
        popl    %esi; CFI_ADJUST(-4)
        popl    %edi; CFI_ADJUST(-4)
        popl    %ebp; CFI_ADJUST(-4)
        jmp     *%edx
        CFI_ENDPROC
        ENDFUNCTION(caml_runstack)

/*=========================================================================*/
/* Array bound error                                                       */
/*=========================================================================*/

FUNCTION(caml_ml_array_bound_error)
        CFI_STARTPROC
    /* Empty the floating-point stack */
        ffree   %st(0)
        ffree   %st(1)
        ffree   %st(2)
        ffree   %st(3)
        ffree   %st(4)
        ffree   %st(5)
        ffree   %st(6)
        ffree   %st(7)
    /* Load address of caml_array_bound_error_asm into eax
       and jump to caml_c_call. This ensures proper stack state
       is saved for backtraces. ecx = esp (no args to copy). */
        movl    $G(caml_array_bound_error_asm), %eax
        movl    %esp, %ecx
        jmp     G(caml_c_call)
        CFI_ENDPROC
        ENDFUNCTION(caml_ml_array_bound_error)

        TEXT_SECTION(caml_system__code_end)
        .globl  G(caml_system__code_end)
G(caml_system__code_end):

/*=========================================================================*/
/* Data section                                                            */
/*=========================================================================*/

        .data
        .globl  G(caml_system.frametable)
G(caml_system.frametable):
        .long   2               /* two descriptors */
        .long   LBL(caml_retaddr)  /* return address into callback */
#ifndef SYS_solaris
        .word   -1              /* negative frame size => use callback link */
        .word   0               /* no roots here */
#else
        .value  -1
        .value  0
#endif
        .align  FUNCTION_ALIGN
        .long   LBL(frame_runstack) /* return address into fiber handler */
#ifndef SYS_solaris
        .word   -1              /* negative frame size => use callback link */
        .word   0               /* no roots here */
#else
        .value  -1
        .value  0
#endif

        .globl  G(caml_extra_params)
G(caml_extra_params):
#ifndef SYS_solaris
        .space  256
#else
        .zero   256
#endif

#if defined(SYS_linux_elf) || defined(SYS_linux)
    /* Mark stack as non-executable, PR#4564 */
        .section .note.GNU-stack,"",%progbits
#endif

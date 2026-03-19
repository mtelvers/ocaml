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

#include "caml/m.h"
#include "caml/asm.h"

#if defined(MODEL_ppc64le)
        .abiversion 2
#endif

#if defined(MODEL_ppc)
/* PPC32 ELF32 ABI */
#elif defined(MODEL_ppc64) && _CALL_ELF == 1
/* PPC64 ELF64v1 ABI (big-endian) */
#elif defined(MODEL_ppc64le) && _CALL_ELF == 2
/* PPC64 ELF64v2 ABI (little-endian) */
#else
#error "This POWER port requires ELF32 (ppc), ELFv1 (ppc64), or ELFv2 (ppc64le)"
#endif

/* Helpers for 32/64-bit portability */
#if defined(MODEL_ppc)
#define WORD 4
#define lg lwz
#define lgu lwzu
#define stg stw
#define stgu stwu
#define datag .long
#define cmplg cmplw
#define cmpg cmpw
#define cmpgi cmpwi
#define sragi srawi
#define slgi slwi
#else
#define WORD 8
#define lg ld
#define lgu ldu
#define stg std
#define stgu stdu
#define datag .quad
#define cmplg cmpld
#define cmpg cmpd
#define cmpgi cmpdi
#define sragi sradi
#define slgi sldi
#endif

/* Special registers */
#define SP 1
#define TMP 11
#define TMP2 12
#define START_PRG_ARG 12
#define START_PRG_DOMAIN_STATE_PTR 7
#define STACK_ARG_BYTES 24
#define C_CALL_FUN 25
#define C_CALL_TOC 26
#define C_CALL_RET_ADDR 27
#define C_CALL_TMP 28
#define TRAP_PTR 29
#define DOMAIN_STATE_PTR 30
#define ALLOC_PTR 23
#define FRAME_PTR 31

/* gc_regs bucket: integer reg at index i is stored at offset i*8 (matching
   proc.ml), then the caller-save floats.  Without frame pointers r31 is an
   extra allocatable integer register, so there is one more integer slot. */
#ifdef WITH_FRAME_POINTERS
#define NUM_INT_GC_REGS 22
#else
#define NUM_INT_GC_REGS 23
#endif
#define GC_FLOAT_OFS(n) ((NUM_INT_GC_REGS + (n)) * 8)

/* Stack layout */
#if defined(MODEL_ppc)
/* PPC32 ELF ABI requires 8 bytes at the bottom of each stack frame
   for the linkage area: back chain (SP+0) and LR save area (SP+4).
   This must be preserved when passing extra arguments via the stack. */
#define RESERVED_STACK 8
#define LR_SAVE_OFFSET 4
#define TRAP_SIZE 8
#define TRAP_HANDLER_OFFSET 4
#define TRAP_PREVIOUS_OFFSET 0
#define CALLBACK_LINK_SIZE 16
#elif defined(MODEL_ppc64)
/* PPC64 ELF64v1 ABI: 48 bytes reserved at bottom of each stack frame
   (back chain, CR save, LR save, reserved, reserved, TOC save) */
#define RESERVED_STACK 48
#define LR_SAVE 16
#define TOC_SAVE_PARENT 8
#define TOC_SAVE 24
#define TRAP_SIZE 16
#define TRAP_HANDLER_OFFSET 8
#define TRAP_PREVIOUS_OFFSET 0
#define CALLBACK_LINK_SIZE 32
#else
/* PPC64 ELF64v2 ABI: 32 bytes reserved at bottom of each stack frame */
#define RESERVED_STACK 32
#define LR_SAVE 16
#define TOC_SAVE_PARENT 8
#define TOC_SAVE 24
/* Trap frame size, must match emit.mlp's [trap_size].
   With frame pointers we need >= RESERVED_STACK + 16.  Otherwise 16
   suffices. */
#ifdef WITH_FRAME_POINTERS
#define TRAP_SIZE 48
#else
#define TRAP_SIZE 16
#endif
#define TRAP_HANDLER_OFFSET 8
#define TRAP_PREVIOUS_OFFSET 0
#define CALLBACK_LINK_SIZE 32
#endif

/* struct stack_info */
#define Stack_sp(reg)           0(reg)
#define Stack_sp_offset         0
#if defined(MODEL_ppc)
#define Stack_exception(reg)    4(reg)
#define Stack_handler(reg)      8(reg)
#else
#define Stack_exception(reg)    8(reg)
#define Stack_handler(reg)      16(reg)
#endif

/* struct c_stack_link */
#if defined(MODEL_ppc)
/* PPC32: no reserved space, so offsets are 0, 4, 8 */
#define Cstack_stack(reg)       0(reg)
#define Cstack_sp(reg)          4(reg)
#define Cstack_sp_offset        4
#define Cstack_prev(reg)        8(reg)
#elif defined(MODEL_ppc64)
/* PPC64 ELF64v1: 48 bytes reserved (6 quadwords) */
#define Cstack_stack(reg)       48(reg)
#define Cstack_sp(reg)          56(reg)
#define Cstack_sp_offset        56
#define Cstack_prev(reg)        64(reg)
#else
/* PPC64 ELF64v2: 32 bytes reserved (4 quadwords) */
#define Cstack_stack(reg)       32(reg)
#define Cstack_sp(reg)          40(reg)
#define Cstack_sp_offset        40
#define Cstack_prev(reg)        48(reg)
#endif

/* struct stack_handler */
#define Handler_value(reg)      0(reg)
#if defined(MODEL_ppc)
#define Handler_exception(reg)  4(reg)
#define Handler_effect(reg)     8(reg)
#define Handler_parent(reg)     12(reg)
#define Handler_parent_offset   12
#else
#define Handler_exception(reg)  8(reg)
#define Handler_effect(reg)     16(reg)
#define Handler_parent(reg)     24(reg)
#define Handler_parent_offset   24
#endif

/* DWARF

   These Power specific register numbers are coming from
   Table 2.39 ("Mappings of common registers") of:
   64-Bit ELF V2 ABI Specification, Power Architecture
   Revision 1.5 (December 1, 2020)

   https://files.openpower.foundation/s/cfA2oFPXbbZwEBK/download/64biteflv2abi-v1.5.pdf

 */

#define DW_REG_sp 1
#define DW_REG_lr 65

/* On ELFv1 (MODEL_ppc64), CFI_SIGNAL_FRAME causes BFD ld's .eh_frame optimizer
   to corrupt FDEs by dropping DW_CFA_def_cfa_expression instructions.
   The associated DW_CFA_val_expression for SP also triggers a recursive
   frame computation in GDB's ELFv1 unwinder.  Omit both on ELFv1. */
#if defined(MODEL_ppc64)
#define CFI_SIGNAL_FRAME_IF_SUPPORTED /* nothing */
#else
#define CFI_SIGNAL_FRAME_IF_SUPPORTED CFI_SIGNAL_FRAME
#endif

/* Function definitions */

.macro TEXT_SECTION name
#if defined(FUNCTION_SECTIONS)
        .section ".text.caml.\name","ax",@progbits
#else
        .section ".text"
#endif
.endm

#if defined(FUNCTION_SECTIONS)
/* Two sections, and matching symbols, caml_hot__code_begin and
   caml_hot__code_end, are used by OCamlFDO. These names are not OCaml
   functions and should not be mangled in the same way as OCaml
   symbols: they are hard-wired in OCamlFDO. */

        TEXT_SECTION caml_hot__code_begin
        .globl caml_hot__code_begin
caml_hot__code_begin:

        TEXT_SECTION caml_hot__code_end
        .globl caml_hot__code_end
caml_hot__code_end:
#endif

#if defined(MODEL_ppc)
.macro FUNCTION name
        TEXT_SECTION \name
        .globl \name
        TYPE_DIRECTIVE(\name,@function)
        .align 2
\name:
.endm
#elif defined(MODEL_ppc64)
.macro FUNCTION name
        .section ".opd","aw"
        .align 3
        .globl \name
\name:
        .quad .L.\name,.TOC.@tocbase,0
        .previous
        TYPE_DIRECTIVE(\name,@function)
        TEXT_SECTION \name
.L.\name:
.endm
#else
.macro FUNCTION name
        TEXT_SECTION \name
        .globl \name
        TYPE_DIRECTIVE(\name,@function)
\name:
0:      addis   2, 12, .TOC.- 0b@ha
        addi    2, 2,  .TOC.- 0b@l
        .localentry \name, . - \name
.endm
#endif

#if defined(MODEL_ppc64)
.macro ENDFUNCTION name
        .size \name, .-.L.\name
.endm
#else
.macro ENDFUNCTION name
        SIZE_DIRECTIVE(\name)
.endm
#endif

/* OCAML_FUNCTION / ENDOCAML_FUNCTION: for runtime functions called from
   OCaml code (via Capply or direct bl).  On ELFv1, these must NOT have
   .opd descriptors since OCaml callers branch to the symbol directly.
   On ELF32 and ELFv2, these are identical to FUNCTION/ENDFUNCTION. */
#if defined(MODEL_ppc64)
.macro OCAML_FUNCTION name
        TEXT_SECTION \name
        .globl \name
        TYPE_DIRECTIVE(\name,@function)
        .align 2
\name:
.endm
.macro ENDOCAML_FUNCTION name
        SIZE_DIRECTIVE(\name)
.endm
#else
.macro OCAML_FUNCTION name
        TEXT_SECTION \name
        .globl \name
        TYPE_DIRECTIVE(\name,@function)
\name:
#if !defined(MODEL_ppc)
0:      addis   2, 12, .TOC.- 0b@ha
        addi    2, 2,  .TOC.- 0b@l
        .localentry \name, . - \name
#endif
.endm
.macro ENDOCAML_FUNCTION name
        SIZE_DIRECTIVE(\name)
.endm
#endif

.macro OBJECT name
        .globl \name
        TYPE_DIRECTIVE(\name,@object)
\name:
.endm

.macro ENDOBJECT name
        SIZE_DIRECTIVE(\name)
.endm

/* Function prologue and epilogue */

#if defined(MODEL_ppc)
.macro ENTER_FUNCTION
   /* Save return address in caller's frame. */
        mflr    0
        stw     0, LR_SAVE_OFFSET(SP)
        CFI_OFFSET(65, LR_SAVE_OFFSET) /* LR (DWARF reg 65) saved at CFA + 4 */
.endm

.macro LEAVE_FUNCTION
   /* Restore return address. */
        lwz     0, LR_SAVE_OFFSET(SP)
        mtlr    0
.endm
#else
.macro ENTER_FUNCTION
   /* Save return address in caller's frame. */
        mflr    0
        std     0, LR_SAVE(SP)
        CFI_OFFSET(DW_REG_lr, LR_SAVE)  /* LR saved at CFA + LR_SAVE */
.endm

.macro LEAVE_FUNCTION
   /* Restore return address. */
        ld      0, LR_SAVE(SP)
        mtlr    0
.endm
#endif

/* UPDATE_BASE_POINTER: update the fiber's back chain (bottom of the fiber
   stack, a fixed -(16 + TRAP_SIZE + RESERVED_STACK) from the stack_handler)
   to point at the current frame, so frame-pointer walking traverses a resumed
   fiber. Must not touch fiber_bottom+16: that holds f's return address, so the
   walker legitimately shows caml_runstack as the intermediate frame. */
#ifdef WITH_FRAME_POINTERS
.macro UPDATE_BASE_POINTER handler_reg
   /* ENTER_FUNCTION first: a frame's return address is read at
      back_chain + LR_SAVE, so the frame pointed at needs a valid one. */
        ENTER_FUNCTION
        std     SP, -(16 + TRAP_SIZE + RESERVED_STACK)(\handler_reg)
.endm
#else
.macro UPDATE_BASE_POINTER handler_reg
.endm
#endif

/* INIT_LR_SAVE: store \target in this frame's LR save area, obtaining its
   address with a bl to the next instruction. */
.macro INIT_LR_SAVE target, here
        bl      \here
\here:
        mflr    TMP
        addi    TMP, TMP, (\target - \here + 4)
#if defined(MODEL_ppc)
        stw     TMP, LR_SAVE_OFFSET(SP)
#else
        std     TMP, LR_SAVE(SP)
#endif
.endm

/* Accessing global variables.  */

#if defined(MODEL_ppc)
/* For PPC32 PIE, use per-CU .got2 section to avoid system GOT overflow.
   The system .got uses R_PPC_GOT16 (16-bit signed) which overflows when
   total GOT exceeds 64KB.  Per-CU .got2 uses R_PPC_ADDR32 entries
   resolved by the dynamic linker, accessed via PC-relative R_PPC_REL16. */
#define Addrglobal(reg,glob) \
        bcl     20, 31, 68f; \
68:     mflr    reg; \
        addis   reg, reg, .LCTOC1-68b@ha; \
        addi    reg, reg, .LCTOC1-68b@l; \
        lwz     reg, .Lgot2_##glob-.LCTOC1(reg)
#else
#define LSYMB(glob) .L##glob

#define Addrglobal(reg,glob) \
        ld      reg, LSYMB(glob)@toc(2)
#endif

/* Accessing local code labels.  */

#if defined(MODEL_ppc)
/* For PPC32 PIE, we need PC-relative addressing.
   Use bcl 20,31,. to get PC into LR, then compute label relative to that.
   This clobbers LR, so must be called when LR is already saved. */
#define Addrlabel(reg,lbl) \
        bcl     20, 31, 66f; \
66:     mflr    reg; \
        addi    reg, reg, (.L##lbl - 66b)
#else
#define LLABEL(lbl) .LL##lbl

#define Addrlabel(reg,lbl) \
        ld      reg, LLABEL(lbl)@toc(2)
#endif

        .set    domain_curr_field, 0
#define DOMAIN_STATE(c_type, name) \
        .equ    domain_field_caml_##name, domain_curr_field ; \
        .set    domain_curr_field, domain_curr_field + 1
#include "../runtime/caml/domain_state.tbl"
#undef DOMAIN_STATE

#define Caml_state(var) 8*domain_field_caml_##var(DOMAIN_STATE_PTR)

/* Call or tail-call function F defined in another compilation unit */

#if defined(MODEL_ppc)
#define Far_call(fn) bl fn
#define Far_tailcall(fn) mflr 0; Addrglobal(TMP, fn); mtlr 0; mtctr TMP; bctr
#elif defined(MODEL_ppc64)
/* ELFv1: OCaml functions have no .opd descriptor (symbol is on the code),
   so Far_tailcall works like ELFv2.  Far_call uses bl+nop which the
   linker resolves through PLT stubs for .opd-bearing C functions. */
#define Far_call(fn) bl fn; nop
#define Far_tailcall(fn) Addrglobal(12, fn); mtctr 12; bctr
#else
/* ELFv2: TOC entry points directly to code. */
#define Far_call(fn) bl fn; nop
#define Far_tailcall(fn) Addrglobal(12, fn); mtctr 12; bctr
#endif

/* Load an OCaml function's code entry point.
   OCaml functions have no .opd descriptor on ELFv1, so their
   TOC/GOT entries point directly to the code. */
#define Addrfunc(reg,fn) Addrglobal(reg, fn)

/* Switch from OCaml stack to C stack */

.macro SWITCH_OCAML_TO_C
   /* Fill in Caml_state->current_stack->sp */
       lg      TMP, Caml_state(current_stack)
       stg     SP, Stack_sp(TMP)
   /* Fill in Caml_state->c_stack */
       lg      TMP2, Caml_state(c_stack)
       stg     TMP, Cstack_stack(TMP2)
       stg     SP, Cstack_sp(TMP2)
   /* Switch to C stack */
#if defined(MODEL_ppc)
   /* On PPC32 ELF, the C ABI allows functions to store at positive offsets
      from SP: back chain (SP+0), LR save (SP+4), and parameter/register save
      area (SP+8 and above, typically 32 bytes for 8 registers).
      We must place SP far enough below c_stack_link that this area doesn't
      overlap with the structure. Use -56 to be safe (8 linkage + 32 params + 16 buffer). */
       addi    SP, TMP2, -56
#elif defined(MODEL_ppc64)
   /* On PPC64 ELFv1, the C ABI mandates a parameter save area at SP+48
      (48 bytes linkage area + 64 bytes for 8 parameter slots = 112 bytes).
      c_stack_link fields start at offset 48 (stack), 56 (sp), 64 (prev),
      so C callees writing to the parameter save area would corrupt them.
      Offset SP below c_stack_link by 112 bytes to prevent overlap. */
       addi    SP, TMP2, -112
#else
       mr      SP, TMP2
#endif
#ifdef ASM_CFI_SUPPORTED
       CFI_REMEMBER_STATE
   /* CFA = *(SP + offset_to_Cstack_sp) = OCaml_SP (the SP at the call site).
      On PPC32/PPC64BE, SP is offset below c_stack_link for the C ABI save area,
      so add that offset to reach the Cstack_sp field.
      LR was saved at OCaml_SP + LR_SAVE before the switch. */
#if defined(MODEL_ppc)
   /* SP = c_stack_link - 56, Cstack_sp_offset = 4, total = 60 (1-byte SLEB128) */
       .cfi_escape DW_CFA_def_cfa_expression, 3,                      \
          DW_OP_breg + DW_REG_sp, (Cstack_sp_offset + 56), DW_OP_deref
       CFI_OFFSET(65, LR_SAVE_OFFSET) /* LR at CFA + 4 */
#elif defined(MODEL_ppc64)
   /* SP = c_stack_link - 112, Cstack_sp_offset = 56, total = 168 (2-byte SLEB128) */
       .cfi_escape DW_CFA_def_cfa_expression, 4,                      \
          DW_OP_breg + DW_REG_sp, 0xa8, 0x01, DW_OP_deref
       CFI_OFFSET(65, LR_SAVE) /* LR at CFA + 16 */
#else
       .cfi_escape DW_CFA_def_cfa_expression, 3,                      \
          DW_OP_breg + DW_REG_sp, Cstack_sp_offset, DW_OP_deref
       CFI_OFFSET(65, LR_SAVE) /* LR at CFA + 16 */
#endif
   /* Tell the debugger that the interrupted SP value equals CFA.
      This is needed for proper unwinding through the signal frame.
      On ELFv1, DW_CFA_val_expression for SP triggers a recursive frame
      computation in GDB's unwinder (which uses the back chain to cross-check
      SP), so we omit it along with CFI_SIGNAL_FRAME on that ABI. */
#if !defined(MODEL_ppc64)
       .cfi_escape DW_CFA_val_expression, DW_REG_sp, 1, DW_OP_call_frame_cfa
#endif
#endif
.endm

/* Switch from C stack to OCaml stack */

.macro SWITCH_C_TO_OCAML
#if defined(MODEL_ppc)
   /* Undo the -56 offset we applied in SWITCH_OCAML_TO_C, then read Cstack_sp */
       lg      SP, (Cstack_sp_offset + 56)(SP)
#elif defined(MODEL_ppc64)
   /* Undo the -112 offset we applied in SWITCH_OCAML_TO_C */
       lg      SP, (Cstack_sp_offset + 112)(SP)
#else
       lg      SP, Cstack_sp(SP)
#endif
       CFI_RESTORE_STATE
.endm

/* Save ALLOC_PTR and TRAP_PTR to domain state, and save
   the registers used by the code generator to a free gc_regs bucket.
   Address of bucket is then written to Caml_state(gc_regs) */

.macro SAVE_ALL_REGS
    /* Save allocation pointer and exception pointer */
       stg      ALLOC_PTR, Caml_state(young_ptr)
       stg      TRAP_PTR, Caml_state(exn_handler)
    /* Point TMP to the gc_regs bucket and skip to next bucket */
       lg       TMP, Caml_state(gc_regs_buckets)
       lg       0, 0(TMP)
       stg      0, Caml_state(gc_regs_buckets)
    /* Save all allocatable integer registers
       (r23 is ALLOC_PTR, not saved here) */
#if defined(MODEL_ppc)
       stw      3,  0x000(TMP)
       stw      4,  0x004(TMP)
       stw      5,  0x008(TMP)
       stw      6,  0x00C(TMP)
       stw      7,  0x010(TMP)
       stw      8,  0x014(TMP)
       stw      9,  0x018(TMP)
       stw      10, 0x01C(TMP)
       stw      14, 0x020(TMP)
       stw      15, 0x024(TMP)
       stw      16, 0x028(TMP)
       stw      17, 0x02C(TMP)
       stw      18, 0x030(TMP)
       stw      19, 0x034(TMP)
       stw      20, 0x038(TMP)
       stw      21, 0x03C(TMP)
       stw      22, 0x040(TMP)
       stw      24, 0x044(TMP)
       stw      25, 0x048(TMP)
       stw      26, 0x04C(TMP)
       stw      27, 0x050(TMP)
       stw      28, 0x054(TMP)
#ifndef WITH_FRAME_POINTERS
    /* r31 is an allocatable register (frame pointers off): save it too */
       stw      31, 0x058(TMP)
#endif
    /* Save caller-save floating-point registers */
    /* (callee-saves are preserved by C functions) */
       stfd     0,  0x060(TMP)
       stfd     1,  0x068(TMP)
       stfd     2,  0x070(TMP)
       stfd     3,  0x078(TMP)
       stfd     4,  0x080(TMP)
       stfd     5,  0x088(TMP)
       stfd     6,  0x090(TMP)
       stfd     7,  0x098(TMP)
       stfd     8,  0x0A0(TMP)
       stfd     9,  0x0A8(TMP)
       stfd     10, 0x0B0(TMP)
       stfd     11, 0x0B8(TMP)
       stfd     12, 0x0C0(TMP)
       stfd     13, 0x0C8(TMP)
#else
       std      3,  0x000(TMP)
       std      4,  0x008(TMP)
       std      5,  0x010(TMP)
       std      6,  0x018(TMP)
       std      7,  0x020(TMP)
       std      8,  0x028(TMP)
       std      9,  0x030(TMP)
       std      10, 0x038(TMP)
       std      14, 0x040(TMP)
       std      15, 0x048(TMP)
       std      16, 0x050(TMP)
       std      17, 0x058(TMP)
       std      18, 0x060(TMP)
       std      19, 0x068(TMP)
       std      20, 0x070(TMP)
       std      21, 0x078(TMP)
       std      22, 0x080(TMP)
       std      24, 0x088(TMP)
       std      25, 0x090(TMP)
       std      26, 0x098(TMP)
       std      27, 0x0A0(TMP)
       std      28, 0x0A8(TMP)
#ifndef WITH_FRAME_POINTERS
    /* r31 is an allocatable register (frame pointers off): save it too */
       std      31, 0x0B0(TMP)
#endif
    /* Save caller-save floating-point registers */
    /* (callee-saves are preserved by C functions) */
       stfd     0,  GC_FLOAT_OFS(0)(TMP)
       stfd     1,  GC_FLOAT_OFS(1)(TMP)
       stfd     2,  GC_FLOAT_OFS(2)(TMP)
       stfd     3,  GC_FLOAT_OFS(3)(TMP)
       stfd     4,  GC_FLOAT_OFS(4)(TMP)
       stfd     5,  GC_FLOAT_OFS(5)(TMP)
       stfd     6,  GC_FLOAT_OFS(6)(TMP)
       stfd     7,  GC_FLOAT_OFS(7)(TMP)
       stfd     8,  GC_FLOAT_OFS(8)(TMP)
       stfd     9,  GC_FLOAT_OFS(9)(TMP)
       stfd     10, GC_FLOAT_OFS(10)(TMP)
       stfd     11, GC_FLOAT_OFS(11)(TMP)
       stfd     12, GC_FLOAT_OFS(12)(TMP)
       stfd     13, GC_FLOAT_OFS(13)(TMP)
#endif
    /* Save bucket to gc_regs */
       stg      TMP, Caml_state(gc_regs)
.endm

/* Undo SAVE_ALL_REGS: load all the registers saved to Caml_state(gc_regs)
   and refresh ALLOC_PTR and TRAP_PTR from Caml_state */
.macro RESTORE_ALL_REGS
       lg       TMP, Caml_state(gc_regs)
    /* Restore all allocatable integer registers
       (r23 is ALLOC_PTR, not restored here) */
#if defined(MODEL_ppc)
       lwz      3,  0x000(TMP)
       lwz      4,  0x004(TMP)
       lwz      5,  0x008(TMP)
       lwz      6,  0x00C(TMP)
       lwz      7,  0x010(TMP)
       lwz      8,  0x014(TMP)
       lwz      9,  0x018(TMP)
       lwz      10, 0x01C(TMP)
       lwz      14, 0x020(TMP)
       lwz      15, 0x024(TMP)
       lwz      16, 0x028(TMP)
       lwz      17, 0x02C(TMP)
       lwz      18, 0x030(TMP)
       lwz      19, 0x034(TMP)
       lwz      20, 0x038(TMP)
       lwz      21, 0x03C(TMP)
       lwz      22, 0x040(TMP)
       lwz      24, 0x044(TMP)
       lwz      25, 0x048(TMP)
       lwz      26, 0x04C(TMP)
       lwz      27, 0x050(TMP)
       lwz      28, 0x054(TMP)
#ifndef WITH_FRAME_POINTERS
    /* r31 is an allocatable register (frame pointers off): restore it too */
       lwz      31, 0x058(TMP)
#endif
    /* Restore caller-save floating-point registers
       (callee-saves are preserved by C functions) */
       lfd      0,  0x060(TMP)
       lfd      1,  0x068(TMP)
       lfd      2,  0x070(TMP)
       lfd      3,  0x078(TMP)
       lfd      4,  0x080(TMP)
       lfd      5,  0x088(TMP)
       lfd      6,  0x090(TMP)
       lfd      7,  0x098(TMP)
       lfd      8,  0x0A0(TMP)
       lfd      9,  0x0A8(TMP)
       lfd      10, 0x0B0(TMP)
       lfd      11, 0x0B8(TMP)
       lfd      12, 0x0C0(TMP)
       lfd      13, 0x0C8(TMP)
#else
       ld       3,  0x000(TMP)
       ld       4,  0x008(TMP)
       ld       5,  0x010(TMP)
       ld       6,  0x018(TMP)
       ld       7,  0x020(TMP)
       ld       8,  0x028(TMP)
       ld       9,  0x030(TMP)
       ld       10, 0x038(TMP)
       ld       14, 0x040(TMP)
       ld       15, 0x048(TMP)
       ld       16, 0x050(TMP)
       ld       17, 0x058(TMP)
       ld       18, 0x060(TMP)
       ld       19, 0x068(TMP)
       ld       20, 0x070(TMP)
       ld       21, 0x078(TMP)
       ld       22, 0x080(TMP)
       ld       24, 0x088(TMP)
       ld       25, 0x090(TMP)
       ld       26, 0x098(TMP)
       ld       27, 0x0A0(TMP)
       ld       28, 0x0A8(TMP)
#ifndef WITH_FRAME_POINTERS
    /* r31 is an allocatable register (frame pointers off): restore it too */
       ld       31, 0x0B0(TMP)
#endif
    /* Restore caller-save floating-point registers
       (callee-saves are preserved by C functions) */
       lfd      0,  GC_FLOAT_OFS(0)(TMP)
       lfd      1,  GC_FLOAT_OFS(1)(TMP)
       lfd      2,  GC_FLOAT_OFS(2)(TMP)
       lfd      3,  GC_FLOAT_OFS(3)(TMP)
       lfd      4,  GC_FLOAT_OFS(4)(TMP)
       lfd      5,  GC_FLOAT_OFS(5)(TMP)
       lfd      6,  GC_FLOAT_OFS(6)(TMP)
       lfd      7,  GC_FLOAT_OFS(7)(TMP)
       lfd      8,  GC_FLOAT_OFS(8)(TMP)
       lfd      9,  GC_FLOAT_OFS(9)(TMP)
       lfd      10, GC_FLOAT_OFS(10)(TMP)
       lfd      11, GC_FLOAT_OFS(11)(TMP)
       lfd      12, GC_FLOAT_OFS(12)(TMP)
       lfd      13, GC_FLOAT_OFS(13)(TMP)
#endif
    /* Put gc_regs struct back in bucket linked list */
       lg       TMP2, Caml_state(gc_regs_buckets)
       stg      TMP2, 0(TMP)  /* next ptr */
       stg      TMP, Caml_state(gc_regs_buckets)
    /* Reload new allocation pointer and exception pointer */
       lg       ALLOC_PTR, Caml_state(young_ptr)
       lg       TRAP_PTR, Caml_state(exn_handler)
.endm

#if defined(WITH_THREAD_SANITIZER) && !defined(MODEL_ppc) /* { */

.macro TSAN_SETUP_C_CALL size
        ENTER_FUNCTION
   /* Setup new frame for a function call and possibly some register saves. */
        addi    SP, SP, -(RESERVED_STACK + \size)
        std     2, TOC_SAVE(SP)
.endm

.macro TSAN_CLEANUP_AFTER_C_CALL size
   /* Undo call frame. */
        addi    SP, SP, (RESERVED_STACK + \size)
        LEAVE_FUNCTION
.endm

.macro TSAN_ENTER_FUNCTION
        SWITCH_OCAML_TO_C
        TSAN_SETUP_C_CALL 0
        mr      3, 0            /* arg1: return address in caller */
        Far_call(caml_tsan_func_entry_asm)
        TSAN_CLEANUP_AFTER_C_CALL 0
        SWITCH_C_TO_OCAML
.endm

/* This is similar to SAVE_ALL_REGS, but only saving the caller-saved
   registers. */
.macro TSAN_SAVE_CALLER_REGS
    /* Save allocation pointer and exception pointer */
       std      ALLOC_PTR, Caml_state(young_ptr)
       std      TRAP_PTR, Caml_state(exn_handler)
    /* Point TMP to the gc_regs bucket and skip to next bucket */
       ld       TMP, Caml_state(gc_regs_buckets)
       ld       0, 0(TMP)
       std      0, Caml_state(gc_regs_buckets)
    /* Save caller-save integer registers */
       std      3,  0x000(TMP)
       std      4,  0x008(TMP)
       std      5,  0x010(TMP)
       std      6,  0x018(TMP)
       std      7,  0x020(TMP)
       std      8,  0x028(TMP)
       std      9,  0x030(TMP)
       std      10, 0x038(TMP)
    /* Save caller-save floating-point registers */
       stfd     0,  GC_FLOAT_OFS(0)(TMP)
       stfd     1,  GC_FLOAT_OFS(1)(TMP)
       stfd     2,  GC_FLOAT_OFS(2)(TMP)
       stfd     3,  GC_FLOAT_OFS(3)(TMP)
       stfd     4,  GC_FLOAT_OFS(4)(TMP)
       stfd     5,  GC_FLOAT_OFS(5)(TMP)
       stfd     6,  GC_FLOAT_OFS(6)(TMP)
       stfd     7,  GC_FLOAT_OFS(7)(TMP)
       stfd     8,  GC_FLOAT_OFS(8)(TMP)
       stfd     9,  GC_FLOAT_OFS(9)(TMP)
       stfd     10, GC_FLOAT_OFS(10)(TMP)
       stfd     11, GC_FLOAT_OFS(11)(TMP)
       stfd     12, GC_FLOAT_OFS(12)(TMP)
       stfd     13, GC_FLOAT_OFS(13)(TMP)
    /* Save bucket to gc_regs */
       std      TMP, Caml_state(gc_regs)
.endm

/* This is similar to RESTORE_ALL_REGS, but only restoring the caller-saved
   registers. */
.macro TSAN_RESTORE_CALLER_REGS
       ld       TMP, Caml_state(gc_regs)
    /* Restore caller-save integer registers */
       ld       3,  0x000(TMP)
       ld       4,  0x008(TMP)
       ld       5,  0x010(TMP)
       ld       6,  0x018(TMP)
       ld       7,  0x020(TMP)
       ld       8,  0x028(TMP)
       ld       9,  0x030(TMP)
       ld       10, 0x038(TMP)
    /* Restore caller-save floating-point registers */
       lfd      0,  GC_FLOAT_OFS(0)(TMP)
       lfd      1,  GC_FLOAT_OFS(1)(TMP)
       lfd      2,  GC_FLOAT_OFS(2)(TMP)
       lfd      3,  GC_FLOAT_OFS(3)(TMP)
       lfd      4,  GC_FLOAT_OFS(4)(TMP)
       lfd      5,  GC_FLOAT_OFS(5)(TMP)
       lfd      6,  GC_FLOAT_OFS(6)(TMP)
       lfd      7,  GC_FLOAT_OFS(7)(TMP)
       lfd      8,  GC_FLOAT_OFS(8)(TMP)
       lfd      9,  GC_FLOAT_OFS(9)(TMP)
       lfd      10, GC_FLOAT_OFS(10)(TMP)
       lfd      11, GC_FLOAT_OFS(11)(TMP)
       lfd      12, GC_FLOAT_OFS(12)(TMP)
       lfd      13, GC_FLOAT_OFS(13)(TMP)
    /* Put gc_regs struct back in bucket linked list */
       ld       TMP2, Caml_state(gc_regs_buckets)
       std      TMP2, 0(TMP)  /* next ptr */
       std      TMP, Caml_state(gc_regs_buckets)
    /* Reload new allocation pointer and exception pointer */
       ld       ALLOC_PTR, Caml_state(young_ptr)
       ld       TRAP_PTR, Caml_state(exn_handler)
.endm

#else /* } { */

.macro TSAN_ENTER_FUNCTION
.endm

.macro TSAN_SAVE_CALLER_REGS
.endm

.macro TSAN_RESTORE_CALLER_REGS
.endm

#endif /* } WITH_THREAD_SANITIZER */

/* Allocation functions and GC interface.
   Referenced from C code in runtime/startup_nat.c
*/
        TEXT_SECTION caml_system__code_begin
        .globl  caml_system__code_begin
caml_system__code_begin:

/* Reallocate the stack when it is too small. */
/* Desired size is passed in register r27. */

FUNCTION caml_call_realloc_stack
        CFI_STARTPROC
        CFI_SIGNAL_FRAME_IF_SUPPORTED
        ENTER_FUNCTION
   /* Save all registers, as well as ALLOC_PTR and TRAP_PTR */
        SAVE_ALL_REGS  /* r27 is preserved */
   /* Recover desired size, to be passed in r3 */
        mr      3, 27
   /* Switch stacks and call caml_try_realloc_stack */
        SWITCH_OCAML_TO_C
        Far_call(caml_try_realloc_stack)
        SWITCH_C_TO_OCAML
        cmpgi   3, 0
   /* Restore all registers, and also return address */
        RESTORE_ALL_REGS
        LEAVE_FUNCTION
   /* Check status */
        beq     1f
   /* Reallocation successful: return to caller */
        blr
   /* Reallocation failed: raise the Stack_overflow exception */
#if defined(MODEL_ppc)
   /* Save LR before Addrglobal clobbers it (needed for backtrace) */
1:      mflr    0
        Addrglobal(3, caml_exn_Stack_overflow)
        mtlr    0
#else
1:      Addrglobal(3, caml_exn_Stack_overflow)
#endif
        b       .Lcaml_raise_exn
        CFI_ENDPROC
ENDFUNCTION caml_call_realloc_stack

/* Invoke the garbage collector. */

FUNCTION caml_call_gc
        CFI_STARTPROC
        CFI_SIGNAL_FRAME_IF_SUPPORTED
        ENTER_FUNCTION
   /* Save all registers, as well as ALLOC_PTR and TRAP_PTR */
        SAVE_ALL_REGS
        TSAN_ENTER_FUNCTION
   /* Switch stacks and call caml_garbage_collection */
        SWITCH_OCAML_TO_C
        Far_call(caml_garbage_collection)
#if defined(WITH_THREAD_SANITIZER) && !defined(MODEL_ppc)
        TSAN_SETUP_C_CALL 0
        Far_call(caml_tsan_func_exit_asm)
        TSAN_CLEANUP_AFTER_C_CALL 0
#endif
        SWITCH_C_TO_OCAML
   /* Restore registers and return to caller */
        RESTORE_ALL_REGS
        LEAVE_FUNCTION
#if !defined(MODEL_ppc)
        ld      2, TOC_SAVE(SP)
#endif
        blr
        CFI_ENDPROC
ENDFUNCTION caml_call_gc

/* Call a C function from OCaml.  Function to call is in C_CALL_FUN */

.macro RET_FROM_C_CALL
        lg      TMP, Caml_state(action_pending)
        cmpgi   TMP, 0
        beqlr+  0
        li      TMP, -1
        stg     TMP, Caml_state(young_limit)
        blr
.endm

FUNCTION caml_c_call
        CFI_STARTPROC
        CFI_SIGNAL_FRAME_IF_SUPPORTED
        TSAN_SAVE_CALLER_REGS
        TSAN_ENTER_FUNCTION
        TSAN_RESTORE_CALLER_REGS
.Lcaml_c_call:
   /* Save return address in caller's frame AND in a callee-save register */
        mflr    C_CALL_RET_ADDR
#if defined(MODEL_ppc)
        stw     C_CALL_RET_ADDR, LR_SAVE_OFFSET(SP)
   /* Switch from OCaml to C (PPC32 has no frame pointer support) */
        SWITCH_OCAML_TO_C
#else
        std     C_CALL_RET_ADDR, LR_SAVE(SP)
#ifdef WITH_FRAME_POINTERS
   /* Save OCaml SP for frame pointer linking.
      Must use C_CALL_TMP (callee-saved r28) because SWITCH_OCAML_TO_C
      clobbers TMP. */
        mr      C_CALL_TMP, SP
   /* Switch from OCaml to C */
        SWITCH_OCAML_TO_C
   /* Create a frame whose back chain points to OCaml stack.
      This allows frame pointer walking to cross from C to OCaml,
      similar to ARM64's ENTER_FUNCTION. */
        stdu    C_CALL_TMP, -RESERVED_STACK(SP)
#ifdef ASM_CFI_SUPPORTED
   /* After stdu, SP moved away from c_stack_link. The back chain at SP+0
      contains OCaml_SP (from C_CALL_TMP). Update CFI to read CFA from there. */
        .cfi_escape DW_CFA_def_cfa_expression, 3, \
           DW_OP_breg + DW_REG_sp, 0, DW_OP_deref
#endif
#else
   /* Switch from OCaml to C (no extra frame needed without frame pointers) */
        SWITCH_OCAML_TO_C
#endif
#endif
   /* Make the exception handler and alloc ptr available to the C code */
        stg     ALLOC_PTR, Caml_state(young_ptr)
        stg     TRAP_PTR, Caml_state(exn_handler)
    /* Call C function (address in C_CALL_FUN) */
#if defined(MODEL_ppc64)
    /* ELFv1: C_CALL_FUN holds descriptor address; dereference for entry+TOC */
        ld      0, 0(C_CALL_FUN)
        mr      C_CALL_TOC, 2   /* save current TOC in a callee-save register */
        ld      2, 8(C_CALL_FUN)  /* load callee's TOC from descriptor */
        mtctr   0
        bctrl
        mr      2, C_CALL_TOC   /* restore current TOC */
#elif !defined(MODEL_ppc)
    /* ELFv2: r12 must hold function address for local entry computation */
        mtctr   C_CALL_FUN
        mr      12, C_CALL_FUN
        mr      C_CALL_TOC, 2   /* save current TOC in a callee-save register */
        bctrl
        mr      2, C_CALL_TOC   /* restore current TOC */
#ifdef WITH_FRAME_POINTERS
    /* Pop the frame we created */
        addi    SP, SP, RESERVED_STACK
#ifdef ASM_CFI_SUPPORTED
   /* After popping, SP points to c_stack_link again. Restore CFI to read
      CFA from Cstack_sp (offset 40), matching SWITCH_OCAML_TO_C output. */
        .cfi_escape DW_CFA_def_cfa_expression, 3, \
           DW_OP_breg + DW_REG_sp, Cstack_sp_offset, DW_OP_deref
#endif
#endif
#else
    /* PPC32: simple indirect call */
        mtctr   C_CALL_FUN
        bctrl
#endif
    /* Restore return address (in register C_CALL_RET_ADDR, preserved by C) */
        mtlr    C_CALL_RET_ADDR
    /* Reload new allocation pointer and exception pointer */
        lg      ALLOC_PTR, Caml_state(young_ptr)
        lg      TRAP_PTR, Caml_state(exn_handler)
#if defined(WITH_THREAD_SANITIZER) && !defined(MODEL_ppc)
        TSAN_SETUP_C_CALL 16
    /* Save return value registers. Since the called function could be anything,
       it may have returned its result (if any) either in r3 or f1. */
        std     3,  (RESERVED_STACK + 0)(SP)
        stfd    1,  (RESERVED_STACK + 8)(SP)
        Far_call(caml_tsan_func_exit_asm)
        lfd     1,  (RESERVED_STACK + 8)(SP)
        ld      3,  (RESERVED_STACK + 0)(SP)
        TSAN_CLEANUP_AFTER_C_CALL 16
#endif
    /* Switch from C to OCaml */
        SWITCH_C_TO_OCAML
    /* Return to caller */
        RET_FROM_C_CALL
        CFI_ENDPROC
ENDFUNCTION caml_c_call

FUNCTION caml_c_call_stack_args
        CFI_STARTPROC
        CFI_SIGNAL_FRAME_IF_SUPPORTED
   /* Extra arguments to be passed on stack:
      STACK_ARG_BYTES at offsets RESERVED_STACK
      to RESERVED_STACK + STACK_ARG_BYTES from SP.
      On PPC64 C_CALL_TOC (r26, callee-saved) holds the OCaml SP;
      on PPC32 C_CALL_TMP (r28, callee-saved) holds the OCaml SP. */
#if defined(MODEL_ppc)
        mr      C_CALL_TMP, SP
#else
        mr      C_CALL_TOC, SP
#ifdef WITH_FRAME_POINTERS
   /* Power does not need caml_c_call_copy_stack_args (used by the register-FP
      arches, see ocaml/ocaml#13635): stack reallocation locates OCaml frame
      pointers via c_stack_link->sp and the in-memory back chain (see
      caml_try_realloc_stack in fiber.c), so it never walks the C-stack region
      where these arguments are pushed. */
   /* SP is a parameter frame whose back chain points to the actual function
      frame.  Skip the parameter frame so the frame walker does not see it
      twice. */
        ld      C_CALL_TMP, 0(SP)       /* actual function frame */
#endif
#endif
   /* Save return address in caller's frame AND in a callee-save register */
        mflr    C_CALL_RET_ADDR
#if defined(MODEL_ppc)
        stw     C_CALL_RET_ADDR, LR_SAVE_OFFSET(SP)
#else
#ifdef WITH_FRAME_POINTERS
   /* Saved into the OCaml caller's frame after the copy loop instead, where
      it cannot be clobbered by the last argument slot. */
#else
        std     C_CALL_RET_ADDR, LR_SAVE(SP)
#endif
#endif
   /* Switch from OCaml to C */
        SWITCH_OCAML_TO_C
   /* Make the exception handler and alloc ptr available to the C code */
        stg     ALLOC_PTR, Caml_state(young_ptr)
        stg     TRAP_PTR, Caml_state(exn_handler)
   /* Reserve STACK_ARG_BYTES bytes on the C stack */
        subfc   SP, STACK_ARG_BYTES, SP
#if !defined(MODEL_ppc)
#ifdef WITH_FRAME_POINTERS
   /* Set up back chain pointing to actual OCaml function frame
      (not param frame).
      This allows frame pointer walking to cross from C to OCaml correctly. */
        std     C_CALL_TMP, 0(SP)
#ifdef ASM_CFI_SUPPORTED
   /* After subfc + std, SP moved away from c_stack_link. The back chain at SP+0
      contains OCaml_SP (from C_CALL_TMP). Update CFI to read CFA from there. */
        .cfi_escape DW_CFA_def_cfa_expression, 3, \
           DW_OP_breg + DW_REG_sp, 0, DW_OP_deref
#endif
#endif
#endif
   /* Copy from OCaml SP + [RESERVED_STACK...RESERVED_STACK+STACK_ARG_BYTES)
           to C SP + [RESERVED_STACK...RESERVED_STACK+STACK_ARG_BYTES).
      Saved OCaml SP is in C_CALL_TMP on PPC32 and C_CALL_TOC on PPC64. */
#if defined(MODEL_ppc)
        addi    TMP, STACK_ARG_BYTES, RESERVED_STACK - 4
1:      lwzx    0, C_CALL_TMP, TMP
        stwx    0, SP, TMP
        addi    TMP, TMP, -4
        cmpwi   TMP, RESERVED_STACK
        bge     1b
#else
        addi    TMP, STACK_ARG_BYTES, RESERVED_STACK - 8
1:      ldx     0, C_CALL_TOC, TMP
        stdx    0, SP, TMP
        addi    TMP, TMP, -8
        cmpdi   TMP, RESERVED_STACK
        bge     1b
#ifdef WITH_FRAME_POINTERS
   /* Save return address in OCaml caller's frame for frame pointer walking.
      Must be AFTER the copy loop because main_SP + 16
      (= param_SP + stack_ofs + 16)
      can overlap with the last argument slot in the parameter frame. */
        std     C_CALL_RET_ADDR, LR_SAVE(C_CALL_TMP)
#endif
#endif
    /* Call C function (address in C_CALL_FUN) */
#if defined(MODEL_ppc64)
    /* ELFv1: C_CALL_FUN holds descriptor address; dereference for entry+TOC */
        ld      0, 0(C_CALL_FUN)
        mr      C_CALL_TOC, 2
        ld      2, 8(C_CALL_FUN)
        mtctr   0
        bctrl
        mr      2, C_CALL_TOC
#elif !defined(MODEL_ppc)
        mtctr   C_CALL_FUN
        mr      12, C_CALL_FUN
        mr      C_CALL_TOC, 2   /* save current TOC in a callee-save register */
        bctrl
        mr      2, C_CALL_TOC   /* restore current TOC */
#else
        mtctr   C_CALL_FUN
        bctrl
#endif
    /* Pop the extra stack space used */
        add     SP, SP, STACK_ARG_BYTES
#ifdef WITH_FRAME_POINTERS
#ifdef ASM_CFI_SUPPORTED
   /* Undo the CFA override above (SP is back at the c_stack_link, so restore
      the CFA = *(SP + Cstack_sp_offset) rule set by SWITCH_OCAML_TO_C).
      Only needed with frame pointers.  Without them that rule was never
      changed. */
        .cfi_escape DW_CFA_def_cfa_expression, 3, \
           DW_OP_breg + DW_REG_sp, Cstack_sp_offset, DW_OP_deref
#endif
#endif
    /* Restore return address (in register C_CALL_RET_ADDR, preserved by C) */
        mtlr    C_CALL_RET_ADDR
    /* Reload new allocation pointer and exception pointer */
        lg      ALLOC_PTR, Caml_state(young_ptr)
        lg      TRAP_PTR, Caml_state(exn_handler)
    /* Switch from C to OCaml */
        SWITCH_C_TO_OCAML
    /* Return to caller */
        RET_FROM_C_CALL
        CFI_ENDPROC
ENDFUNCTION caml_c_call_stack_args

/* Raise an exception from OCaml */

FUNCTION caml_raise_exn
.Lcaml_raise_exn:
        CFI_STARTPROC
        lg      0, Caml_state(backtrace_active)
        cmpgi   0, 0
        bne     .L111
.L110:
    /* Pop trap frame */
        lg      0, TRAP_HANDLER_OFFSET(TRAP_PTR)
        addi    SP, TRAP_PTR, TRAP_SIZE-RESERVED_STACK
        mtctr   0
        lg      TRAP_PTR, (RESERVED_STACK-TRAP_SIZE+TRAP_PREVIOUS_OFFSET)(SP)
    /* Branch to handler */
        bctr
.L111:
    /* Zero backtrace_pos */
        li      0, 0
        stg     0, Caml_state(backtrace_pos)
.L112:
        mr      27, 3           /* preserve exn bucket in callee-save reg */
                                /* arg1: exception bucket, already in r3 */
        mflr    4               /* arg2: PC of raise */
        mr      5, SP           /* arg3: SP of raise */
        mr      6, TRAP_PTR     /* arg4: SP of handler */
    /* Switch to C stack and call caml_stash_backtrace.
       Must offset SP below c_stack_link so the C ABI parameter save area
       does not overlap with c_stack_link fields (stack, sp, prev).
       Same offsets as SWITCH_OCAML_TO_C. */
        lg      SP, Caml_state(c_stack)
#if defined(MODEL_ppc)
        addi    SP, SP, -56
#elif defined(MODEL_ppc64)
        addi    SP, SP, -112
#endif
        Far_call(caml_stash_backtrace)
    /* Restore exception bucket and raise */
        mr      3, 27
        b       .L110
        CFI_ENDPROC
ENDFUNCTION caml_raise_exn

FUNCTION caml_reraise_exn
        CFI_STARTPROC
        lg      0, Caml_state(backtrace_active)
        cmpgi   0, 0
        bne     .L112
    /* Pop trap frame */
        lg      0, TRAP_HANDLER_OFFSET(TRAP_PTR)
        addi    SP, TRAP_PTR, TRAP_SIZE-RESERVED_STACK
        mtctr   0
        lg      TRAP_PTR, (RESERVED_STACK-TRAP_SIZE+TRAP_PREVIOUS_OFFSET)(SP)
    /* Branch to handler */
        bctr
        CFI_ENDPROC
ENDFUNCTION caml_reraise_exn

#if defined(WITH_THREAD_SANITIZER)
/* When TSan support is enabled, this routine should be called just before
   raising an exception. It calls __tsan_func_exit for every OCaml frame about
   to be exited due to the exception.
   Takes no arguments, clobbers r3, r4, r5 and potentially all
   caller-saved registers of the C calling convention. */
FUNCTION caml_tsan_exit_on_raise_asm
        CFI_STARTPROC
        mflr    3               /* arg1: PC of raise */
        mr      4, SP           /* arg2: SP of raise */
        mr      5, TRAP_PTR     /* arg3: SP of handler */
        SWITCH_OCAML_TO_C
        TSAN_SETUP_C_CALL 0
        Far_call(caml_tsan_exit_on_raise)
        TSAN_CLEANUP_AFTER_C_CALL 0
        SWITCH_C_TO_OCAML
        blr
        CFI_ENDPROC
ENDFUNCTION caml_tsan_exit_on_raise_asm
#endif

/* Raise an exception from C */

FUNCTION caml_raise_exception
        CFI_STARTPROC
    /* Reinitialize domain state pointer */
        mr      DOMAIN_STATE_PTR, 3
    /* Move exn bucket where caml_raise_exn expects it */
        mr      3, 4
    /* Reload allocation pointer and exception pointer */
        lg      ALLOC_PTR, Caml_state(young_ptr)
        lg      TRAP_PTR, Caml_state(exn_handler)
    /* Discard the C stack pointer and switch to OCaml stack */
        lg      TMP, Caml_state(current_stack)
        lg      SP, Stack_sp(TMP)
    /* Reload return address from caller's frame (for the backtrace) */
        LEAVE_FUNCTION
#if defined(WITH_THREAD_SANITIZER) && !defined(MODEL_ppc)
    /* Call __tsan_func_exit for every OCaml stack frame exited due to the
       exception */
        mr      4, SP           /* arg2: SP of raise */
        SWITCH_OCAML_TO_C
        TSAN_SETUP_C_CALL 16
        std     3, (RESERVED_STACK + 0)(SP) /* preserve exception bucket */
        mr      3, 0            /* arg1: PC of raise */
        mr      5, TRAP_PTR     /* arg3: SP of handler */
        Far_call(caml_tsan_exit_on_raise)
        ld      3,  (RESERVED_STACK + 0)(SP)
        TSAN_CLEANUP_AFTER_C_CALL 16
        SWITCH_C_TO_OCAML
#endif
    /* Raise the exception */
        b       .Lcaml_raise_exn
        CFI_ENDPROC
ENDFUNCTION caml_raise_exception

/* Start the OCaml program */

FUNCTION caml_start_program
        CFI_STARTPROC
        CFI_SIGNAL_FRAME_IF_SUPPORTED

#if defined(WITH_THREAD_SANITIZER) && !defined(MODEL_ppc)
  /* We can't use the TSAN_ENTER_FUNCTION macro, as it assumes to run on an
     OCaml stack, and we are still on a C stack at this point. Moreover, we
     need to save r3 on the stack. */
        TSAN_SETUP_C_CALL 16
        CFI_ADJUST(16)
        std     3, (RESERVED_STACK + 0)(SP)
        mr      3, 0            /* arg1: return address in caller */
        Far_call(caml_tsan_func_entry_asm)
        ld      3, (RESERVED_STACK + 0)(SP)
        TSAN_CLEANUP_AFTER_C_CALL 16
        CFI_ADJUST(-16)
#endif
  /* Domain state pointer is the first arg to caml_start_program. Move it */
        mr      START_PRG_DOMAIN_STATE_PTR, 3
  /* Code to call is caml_program */
#if defined(MODEL_ppc)
  /* For PPC32 PIE: Save return address in r0 before Addrglobal clobbers LR */
        mflr    0
        Addrglobal(START_PRG_ARG, caml_program)
        mtlr    0
#else
        Addrfunc(START_PRG_ARG, caml_program)
#endif

/* Code shared between caml_start_program and caml_callback */
/* Domain state pointer is in START_PRG_DOMAIN_STATE_PTR */
/* Code to call is in START_PRG_ARG */
.L102:
    /* Stack frame contains:
       - 18 callee-save FPRs
       - 18 callee-save GPRs
       - a struct c_stack_link
       - the standard reserved space
       On PPC32, we need 4 extra bytes for alignment gap between
       4-byte int regs and 8-byte float regs in the save area */
#if defined(MODEL_ppc)
#define STACKSIZE (18 * 8 + 18 * WORD + 4 + CALLBACK_LINK_SIZE + RESERVED_STACK)
#else
#define STACKSIZE (18 * 8 + 18 * WORD + CALLBACK_LINK_SIZE + RESERVED_STACK)
#endif
    /* Allocate and link stack frame */
        stgu    SP, -STACKSIZE(SP)
        CFI_ADJUST(STACKSIZE)
    /* Save return address and TOC pointer into caller's frame */
        mflr    0
#if defined(MODEL_ppc)
        stw     0, (STACKSIZE + LR_SAVE_OFFSET)(SP)
#else
        std     0, (STACKSIZE + LR_SAVE)(SP)
        CFI_OFFSET(DW_REG_lr, LR_SAVE) /* LR saved at CFA + LR_SAVE */
        std     2, (STACKSIZE + TOC_SAVE_PARENT)(SP)
#endif
    /* Save all callee-save registers */
        addi    TMP, SP, CALLBACK_LINK_SIZE + RESERVED_STACK - WORD
        stgu    14, WORD(TMP)
        stgu    15, WORD(TMP)
        stgu    16, WORD(TMP)
        stgu    17, WORD(TMP)
        stgu    18, WORD(TMP)
        stgu    19, WORD(TMP)
        stgu    20, WORD(TMP)
        stgu    21, WORD(TMP)
        stgu    22, WORD(TMP)
        stgu    23, WORD(TMP)
        stgu    24, WORD(TMP)
        stgu    25, WORD(TMP)
        stgu    26, WORD(TMP)
        stgu    27, WORD(TMP)
        stgu    28, WORD(TMP)
        stgu    29, WORD(TMP)
        stgu    30, WORD(TMP)
        stgu    31, WORD(TMP)
        stfdu   14, 8(TMP)
        stfdu   15, 8(TMP)
        stfdu   16, 8(TMP)
        stfdu   17, 8(TMP)
        stfdu   18, 8(TMP)
        stfdu   19, 8(TMP)
        stfdu   20, 8(TMP)
        stfdu   21, 8(TMP)
        stfdu   22, 8(TMP)
        stfdu   23, 8(TMP)
        stfdu   24, 8(TMP)
        stfdu   25, 8(TMP)
        stfdu   26, 8(TMP)
        stfdu   27, 8(TMP)
        stfdu   28, 8(TMP)
        stfdu   29, 8(TMP)
        stfdu   30, 8(TMP)
        stfdu   31, 8(TMP)
#ifdef ASM_CFI_SUPPORTED
#ifdef WITH_FRAME_POINTERS
    /* CFI for r31 (frame pointer). r31 is saved at SP + 200.
       CFA = SP + STACKSIZE = SP + 352, so r31 is at CFA - 152.
       This is needed for unwinding through C frames compiled with
       frame pointers. */
        CFI_OFFSET(FRAME_PTR, -152)
#endif
#endif
    /* Load domain state pointer from argument */
        mr      DOMAIN_STATE_PTR, START_PRG_DOMAIN_STATE_PTR
    /* Reload allocation pointer */
        lg      ALLOC_PTR, Caml_state(young_ptr)
    /* Set up a struct c_stack_link on the C stack */
        li      0, 0
        stg     0, Cstack_stack(SP)
        stg     0, Cstack_sp(SP)
        lg      0, Caml_state(c_stack)
        stg     0, Cstack_prev(SP)
        stg     SP, Caml_state(c_stack)
    /* Load the OCaml stack */
        lg      TMP, Caml_state(current_stack)
        lg      TMP, Stack_sp(TMP)
    /* Store the gc_regs for callbacks during a GC */
        lg      0, Caml_state(gc_regs)
        stgu    0, -WORD(TMP)
#if defined(MODEL_ppc)
    /* Store the C stack pointer for DWARF unwinding */
        stgu    SP, -WORD(TMP)
#else
    /* Store the C caller's stack pointer for frame pointer walking.
       We need caller's SP (before caml_start_program's frame), not our SP.
       Our frame is STACKSIZE bytes, so caller's SP = SP + STACKSIZE. */
        addi    0, SP, STACKSIZE
        stdu    0, -8(TMP)
#endif
    /* Setup a trap frame to catch exceptions escaping the OCaml code */
        addi    TMP, TMP, -TRAP_SIZE
        lg      0, Caml_state(exn_handler)
        stg     0, TRAP_PREVIOUS_OFFSET(TMP)
#if defined(MODEL_ppc)
    /* Load .Ltrap_handler into a register using PC-relative addressing for PIE.
       Use r14 as temp (already saved on stack). */
        bcl     20, 31, 67f
67:     mflr    14
        addi    14, 14, (.Ltrap_handler - 67b)
        stg     14, TRAP_HANDLER_OFFSET(TMP)
#else
        Addrlabel(0,trap_handler)
        stg     0, TRAP_HANDLER_OFFSET(TMP)
#endif
        mr      TRAP_PTR, TMP
    /* Switch stacks, reserving RESERVED_STACK bytes at the bottom */
        addi    SP, TMP, -RESERVED_STACK
    /* Set up back chain to link OCaml stack back to C stack.
       The C stack SP (caml_start_program's frame) was stored at
       SP + RESERVED_STACK + TRAP_SIZE (see stdu SP, -8(TMP) above).
       Load it and store as the back chain so frame pointer walking
       can continue from OCaml stack to C stack. */
#ifdef WITH_FRAME_POINTERS
        ld      0, (RESERVED_STACK + TRAP_SIZE)(SP)
        std     0, 0(SP)
    /* r31 must hold the OCaml SP on entry to OCaml code. */
        mr      FRAME_PTR, SP
#endif

#ifdef ASM_CFI_SUPPORTED
        CFI_REMEMBER_STATE
        /* CFA = *(SP + RESERVED_STACK + TRAP_SIZE), where the C caller's SP
           was stored before entering OCaml.  The offset goes in a ULEB128
           (plus_uconst) rather than breg's SLEB128, which with frame pointers
           would be 80 and so would need two bytes. */
        .cfi_escape DW_CFA_def_cfa_expression, 5,                          \
            DW_OP_breg + DW_REG_sp, 0,                                     \
            DW_OP_plus_uconst, (RESERVED_STACK + TRAP_SIZE),               \
            DW_OP_deref
#if defined(MODEL_ppc)
        CFI_OFFSET(DW_REG_lr, LR_SAVE_OFFSET) /* LR saved at CFA + 4 */
#else
        CFI_OFFSET(DW_REG_lr, LR_SAVE) /* LR saved at CFA + LR_SAVE */
#endif
#endif
    /* Call the OCaml code (address in START_PRG_ARG) */
        mtctr   START_PRG_ARG
    /* Pre-initialize the LR save area with the return address, so the
       runtime's stack walk can find LR even if the first OCaml function
       does not save it (when fun_frame_required = false).  The address
       stored is .Lcaml_retaddr + 4, the instruction after bctrl. */
        INIT_LR_SAVE .Lcaml_retaddr, .Linit_lr_save

.Lcaml_retaddr:
        bctrl
    /* Pop the reserved bytes */
        addi    SP, SP, RESERVED_STACK
        CFI_ADJUST(-RESERVED_STACK)
    /* Pop the trap frame, restoring caml_exn_handler */
        lg      0, TRAP_PREVIOUS_OFFSET(SP)
        stg     0, Caml_state(exn_handler)
        addi    SP, SP, TRAP_SIZE
        CFI_ADJUST(-TRAP_SIZE)
    /* Update allocation pointer */
.L106:
        stg     ALLOC_PTR, Caml_state(young_ptr)
    /* Restore GC regs */
        lg      0, WORD(SP)
        stg     0, Caml_state(gc_regs)
        addi    SP, SP, 2*WORD
    /* Return to C stack */
        lg      TMP, Caml_state(current_stack)
        stg     SP, Stack_sp(TMP)
        lg      SP, Caml_state(c_stack)
        CFI_RESTORE_STATE
    /* Pop the struct c_stack_link */
        lg      0, Cstack_prev(SP)
        stg     0, Caml_state(c_stack)
    /* Restore callee-save registers */
        addi    TMP, SP, CALLBACK_LINK_SIZE + RESERVED_STACK - WORD
        lgu     14, WORD(TMP)
        lgu     15, WORD(TMP)
        lgu     16, WORD(TMP)
        lgu     17, WORD(TMP)
        lgu     18, WORD(TMP)
        lgu     19, WORD(TMP)
        lgu     20, WORD(TMP)
        lgu     21, WORD(TMP)
        lgu     22, WORD(TMP)
        lgu     23, WORD(TMP)
        lgu     24, WORD(TMP)
        lgu     25, WORD(TMP)
        lgu     26, WORD(TMP)
        lgu     27, WORD(TMP)
        lgu     28, WORD(TMP)
        lgu     29, WORD(TMP)
        lgu     30, WORD(TMP)
        lgu     31, WORD(TMP)
        lfdu    14, 8(TMP)
        lfdu    15, 8(TMP)
        lfdu    16, 8(TMP)
        lfdu    17, 8(TMP)
        lfdu    18, 8(TMP)
        lfdu    19, 8(TMP)
        lfdu    20, 8(TMP)
        lfdu    21, 8(TMP)
        lfdu    22, 8(TMP)
        lfdu    23, 8(TMP)
        lfdu    24, 8(TMP)
        lfdu    25, 8(TMP)
        lfdu    26, 8(TMP)
        lfdu    27, 8(TMP)
        lfdu    28, 8(TMP)
        lfdu    29, 8(TMP)
        lfdu    30, 8(TMP)
        lfdu    31, 8(TMP)
    /* Reload return address and TOC pointer */
#if defined(MODEL_ppc)
        lwz     0, (STACKSIZE + LR_SAVE_OFFSET)(SP)
#else
        ld      0, (STACKSIZE + LR_SAVE)(SP)
        ld      2, (STACKSIZE + TOC_SAVE_PARENT)(SP)
#endif
        mtlr    0
    /* Return */
        addi    SP, SP, STACKSIZE
#if defined(WITH_THREAD_SANITIZER) && !defined(MODEL_ppc)
        TSAN_SETUP_C_CALL 16
        std     3, (RESERVED_STACK + 0)(SP)
        Far_call(caml_tsan_func_exit_asm)
        ld      3, (RESERVED_STACK + 0)(SP)
        TSAN_CLEANUP_AFTER_C_CALL 16
#endif
        blr
        CFI_ENDPROC

    /* The trap handler: */
.Ltrap_handler:
    /* Update caml_exn_handler */
        stg     TRAP_PTR, Caml_state(exn_handler)
    /* Pop the reserved bytes */
        addi    SP, SP, RESERVED_STACK
    /* Encode exception bucket as an exception result and return it */
        ori     3, 3, 2
        b       .L106
#undef STACKSIZE
ENDFUNCTION caml_start_program

/* Callback from C to OCaml */

FUNCTION caml_callback_asm
        CFI_STARTPROC
#if defined(WITH_THREAD_SANITIZER) && !defined(MODEL_ppc)
    /* Save non-callee-saved registers r3, r4, r5 before C call */
        TSAN_SETUP_C_CALL 32
        std     3, (RESERVED_STACK + 0)(SP)
        std     4, (RESERVED_STACK + 8)(SP)
        std     5, (RESERVED_STACK + 16)(SP)
        mr      3, 0 /* return address */
        Far_call(caml_tsan_func_entry_asm)
        ld      5, (RESERVED_STACK + 16)(SP)
        ld      4, (RESERVED_STACK + 8)(SP)
        ld      3, (RESERVED_STACK + 0)(SP)
        TSAN_CLEANUP_AFTER_C_CALL 32
#endif
    /* Initial shuffling of arguments */
    /* r3 = Caml_state, r4 = closure, 0(r5) = first arg */
        mr      START_PRG_DOMAIN_STATE_PTR, 3
        lg      3, 0(5)             /* r3 = Argument */
                                    /* r4 = Closure */
        lg      START_PRG_ARG, 0(4) /* Code pointer */
        b       .L102
        CFI_ENDPROC
ENDFUNCTION caml_callback_asm

FUNCTION caml_callback2_asm
        CFI_STARTPROC
#if defined(WITH_THREAD_SANITIZER) && !defined(MODEL_ppc)
    /* Save non-callee-saved registers r3, r4, r5 before C call */
        TSAN_SETUP_C_CALL 32
        std     3, (RESERVED_STACK + 0)(SP)
        std     4, (RESERVED_STACK + 8)(SP)
        std     5, (RESERVED_STACK + 16)(SP)
        mr      3, 0 /* return address */
        Far_call(caml_tsan_func_entry_asm)
        ld      5, (RESERVED_STACK + 16)(SP)
        ld      4, (RESERVED_STACK + 8)(SP)
        ld      3, (RESERVED_STACK + 0)(SP)
        TSAN_CLEANUP_AFTER_C_CALL 32
#endif
    /* r3 = Caml_state, r4 = closure, 0(r5) = first arg,
       WORD(r5) = second arg */
        mr      START_PRG_DOMAIN_STATE_PTR, 3
        mr      0, 4
        lg      3, 0(5)             /* r3 = First argument */
        lg      4, WORD(5)          /* r4 = Second argument */
        mr      5, 0                /* r5 = Closure */
#if defined(MODEL_ppc)
    /* For PPC32 PIE: Save return address before Addrglobal clobbers LR */
        mflr    0
        Addrglobal(START_PRG_ARG, caml_apply2)
        mtlr    0
#else
        Addrfunc(START_PRG_ARG, caml_apply2)
#endif
        b       .L102
        CFI_ENDPROC
ENDFUNCTION caml_callback2_asm

FUNCTION caml_callback3_asm
        CFI_STARTPROC
#if defined(WITH_THREAD_SANITIZER) && !defined(MODEL_ppc)
    /* Save non-callee-saved registers r3, r4, r5 before C call */
        TSAN_SETUP_C_CALL 32
        std     3, (RESERVED_STACK + 0)(SP)
        std     4, (RESERVED_STACK + 8)(SP)
        std     5, (RESERVED_STACK + 16)(SP)
        mr      3, 0 /* return address */
        Far_call(caml_tsan_func_entry_asm)
        ld      5, (RESERVED_STACK + 16)(SP)
        ld      4, (RESERVED_STACK + 8)(SP)
        ld      3, (RESERVED_STACK + 0)(SP)
        TSAN_CLEANUP_AFTER_C_CALL 32
#endif
    /* r3 = Caml_state, r4 = closure, 0(r5) = first arg, WORD(r5) = second arg,
       2*WORD(r5) = third arg */
        mr      START_PRG_DOMAIN_STATE_PTR, 3
        mr      6, 4                /* r6 = Closure */
        lg      3, 0(5)             /* r3 = First argument */
        lg      4, WORD(5)          /* r4 = Second argument */
        lg      5, 2*WORD(5)        /* r5 = Third argument */
#if defined(MODEL_ppc)
    /* For PPC32 PIE: Save return address before Addrglobal clobbers LR */
        mflr    0
        Addrglobal(START_PRG_ARG, caml_apply3)
        mtlr    0
#else
        Addrfunc(START_PRG_ARG, caml_apply3)
#endif
        b       .L102
        CFI_ENDPROC
ENDFUNCTION caml_callback3_asm

/* Fibers */

/* Switch between OCaml stacks. Clobbers register 0 and switches TRAP_PTR.
   Preserves old_stack and new_stack registers */
.macro SWITCH_OCAML_STACKS old_stack, new_stack
    /* Save return address for old_stack */
        ENTER_FUNCTION
    /* Save OCaml SP and exn_handler in the stack info */
        stg     SP, Stack_sp(\old_stack)
        stg     TRAP_PTR, Stack_exception(\old_stack)
    /* switch stacks */
        stg     \new_stack, Caml_state(current_stack)
        lg      SP, Stack_sp(\new_stack)
    /* restore exn_handler for new stack */
        lg      TRAP_PTR, Stack_exception(\new_stack)
    /* Restore return address for new_stack */
        LEAVE_FUNCTION
.endm

/*
 * A continuation is a one word object that points to a fiber. A fiber [f] will
 * point to its parent at Handler_parent(Stack_handler(f)).
 */

OCAML_FUNCTION caml_perform
        CFI_STARTPROC
  /* r3: effect to perform
     r4: freshly allocated continuation */
        lg      5, Caml_state(current_stack) /* r5 := current_stack */
        addi    6, 5, 1  /* r6 := Val_ptr(current_stack) */
        stg     6, 0(4)  /* Initialize continuation */
        mr      7, 5     /* r7 := cont_head */
.Ldo_perform:
  /* r3: effect to perform
     r4: continuation
     r5: current_stack
     r6: Val_ptr(current_stack)
     r7: cont_head */
#if defined(WITH_THREAD_SANITIZER) && !defined(MODEL_ppc)
  /* Signal to TSan all stack frames exited by the perform. */
        TSAN_SAVE_CALLER_REGS
        mflr    3        /* arg1: PC of perform */
        mr      4, SP    /* arg2: SP of perform */
        SWITCH_OCAML_TO_C
        TSAN_SETUP_C_CALL 0
        Far_call(caml_tsan_exit_on_perform)
        TSAN_CLEANUP_AFTER_C_CALL 0
        SWITCH_C_TO_OCAML
        TSAN_RESTORE_CALLER_REGS
#endif
        lg      8, Stack_handler(5)  /* r8 := current_stack -> handler */
        lg      9, Handler_parent(8) /* r9 := parent_stack */
        cmpgi   9, 0 /* is parent_stack NULL? */
        beq     1f
#if defined(WITH_THREAD_SANITIZER) && !defined(MODEL_ppc)
        SWITCH_OCAML_TO_C
        TSAN_SETUP_C_CALL 56
    /* Save non-callee-saved registers r3 to r9 */
        std     3, (RESERVED_STACK + 0)(SP)
        std     4, (RESERVED_STACK + 8)(SP)
        std     5, (RESERVED_STACK + 16)(SP)
        std     6, (RESERVED_STACK + 24)(SP)
        std     7, (RESERVED_STACK + 32)(SP)
        std     8, (RESERVED_STACK + 40)(SP)
        std     9, (RESERVED_STACK + 48)(SP)
    /* Match the TSan-enter made from caml_runstack */
        Far_call(caml_tsan_func_exit_asm)
        ld      9, (RESERVED_STACK + 48)(SP)
        ld      8, (RESERVED_STACK + 40)(SP)
        ld      7, (RESERVED_STACK + 32)(SP)
        ld      6, (RESERVED_STACK + 24)(SP)
        ld      5, (RESERVED_STACK + 16)(SP)
        ld      4, (RESERVED_STACK + 8)(SP)
        ld      3, (RESERVED_STACK + 0)(SP)
        TSAN_CLEANUP_AFTER_C_CALL 56
        SWITCH_C_TO_OCAML
#endif
        SWITCH_OCAML_STACKS 5, 9
  /* We have to update the Handler_parent after the switch because
     the Handler_parent is needed to unwind the stack for backtraces */
        stg     6, 0(4)  /* Update continuation with new cont_tail */
        stg     7, Handler_parent(8)   /* Connect new cont_tail to cont_head */
        lg      5, Handler_effect(8)   /* r5 := effect handler (closure) */
                                       /* r3 := effect to perform (1st arg) */
                                       /* r4 := continuation (2nd arg) */
        Far_tailcall(caml_apply2)
1:
  /* No parent stack. Switch back to original performer before raising
     Effect.Unhandled. */
        SWITCH_OCAML_STACKS 5, 7
  /* No parent stack. Raise Effect.Unhandled. */
#if defined(WITH_THREAD_SANITIZER) && !defined(MODEL_ppc)
        /* We must let the TSan runtime know that we switched back to the
           original performer stack. For that, we perform the necessary calls
           to __tsan_func_entry via caml_tsan_entry_on_resume.
           Note that from TSan's point of view, we just exited all stack
           frames, including those of the main fiber. This is ok, because we
           re-enter them immediately via caml_tsan_entry_on_resume below. */
        TSAN_SAVE_CALLER_REGS
        mflr    3       /* arg1: PC of perform */
        mr      4, SP   /* arg2: SP of perform */
        mr      5, 7    /* arg3: performer stack (cont_head) */
        SWITCH_OCAML_TO_C
        TSAN_SETUP_C_CALL 0
        Far_call(caml_tsan_entry_on_resume)
        /* invoke __tsan_func_entry without shuffling stacks */
        ld      3, LR_SAVE(SP)
        Far_call(caml_tsan_func_entry_asm)
        TSAN_CLEANUP_AFTER_C_CALL 0
        SWITCH_C_TO_OCAML
        TSAN_RESTORE_CALLER_REGS
#endif
#if defined(MODEL_ppc)
   /* Save LR before Addrglobal clobbers it (needed for backtrace) */
        mflr    0
        Addrglobal(C_CALL_FUN, caml_raise_unhandled_effect)
        mtlr    0
#else
        Addrglobal(C_CALL_FUN, caml_raise_unhandled_effect)
#endif
        b       .Lcaml_c_call
        CFI_ENDPROC
ENDOCAML_FUNCTION caml_perform

OCAML_FUNCTION caml_reperform
        CFI_STARTPROC
  /* r3: effect to perform
     r4: continuation */
        lg      5, Caml_state(current_stack) /* r5 := current_stack */
        lg      6, 0(4)                      /* r6 := Val_ptr(cont_tail) */
        addi    6, 6, -1                     /* r6 := cont_tail */
        lg      TMP, Stack_handler(6)
        lg      7, Handler_parent(TMP) /* r7 := cont_head */
        stg     5, Handler_parent(TMP) /* parent(cont_tail) := current_stack */
        addi    6, 5, 1 /* r6 := Val_ptr(current_stack) */
    /* The handler may have reallocated the fiber stack, so refresh the
       back chain at its bottom. */
        UPDATE_BASE_POINTER TMP
        b       .Ldo_perform
        CFI_ENDPROC
ENDOCAML_FUNCTION caml_reperform

OCAML_FUNCTION caml_resume
        CFI_STARTPROC
  /* r3: Val_ptr(cont_tail)
     r4: fun
     r5: arg */
        addi    3, 3, -1 /* r3 (cont_tail) = Ptr_val(r3) */
        lg      12, 0(4) /* r12 = code pointer */
        mtctr   12       /* CTR = code pointer */
    /* Check if stack is null, then already used */
        cmpgi   3, 0
        beq     1f
   /* Load cont_head, the fiber at which we will resume */
        lg      6, Stack_handler(3)
        lg      6, Handler_parent(6) /* r6 = cont_head */
#if defined(WITH_THREAD_SANITIZER) && !defined(MODEL_ppc)
        TSAN_SAVE_CALLER_REGS
        SWITCH_OCAML_TO_C
        TSAN_SETUP_C_CALL 16
    /* save r6 (cont_head) clobbered by first Far_call */
        std     6, (RESERVED_STACK + 0)(SP)
    /* Necessary to include the caller of caml_resume in the TSan backtrace */
        mr      3, 0            /* arg1: return address in caller */
        Far_call(caml_tsan_func_entry_asm)
    /* Signal to TSan all stack frames exited by the perform. */
        ld      5, (RESERVED_STACK + 0)(SP) /* arg3: cont_head */
        ld      4, Stack_sp(5)  /* arg2: SP at perform */
        ld      3, LR_SAVE(4)   /* arg1: PC of perform */
        Far_call(caml_tsan_entry_on_resume)
        TSAN_CLEANUP_AFTER_C_CALL 16
        SWITCH_C_TO_OCAML
        TSAN_RESTORE_CALLER_REGS
    /* Restore r12 and ctr */
        ld      12, 0(4) /* r12 = code pointer */
        mtctr   12       /* CTR = code pointer */
#endif
    /* Add current stack to the end */
        lg      7, Stack_handler(3)
        lg      8, Caml_state(current_stack)
        stg     8, Handler_parent(7)
    /* Point cont_tail's back chain (r7 = its stack_handler) at this frame,
       so a walker passes through the effect handler. */
        UPDATE_BASE_POINTER 7
    /* Switch stacks and run code */
        SWITCH_OCAML_STACKS 8, 6
        mr      3, 5
        bctr
1:      TSAN_ENTER_FUNCTION /* needed since we skip caml_c_call entry */
#if defined(MODEL_ppc)
   /* Save LR before Addrglobal clobbers it (needed for backtrace) */
        mflr    0
        Addrglobal(C_CALL_FUN, caml_raise_continuation_already_resumed)
        mtlr    0
#else
        Addrglobal(C_CALL_FUN, caml_raise_continuation_already_resumed)
#endif
        b       .Lcaml_c_call
        CFI_ENDPROC
ENDOCAML_FUNCTION caml_resume

/* Run a function on a new stack, then either
   return the value or invoke exception handler */
OCAML_FUNCTION caml_runstack
        CFI_STARTPROC
        CFI_SIGNAL_FRAME_IF_SUPPORTED
#if defined(WITH_THREAD_SANITIZER) && !defined(MODEL_ppc)
        SWITCH_OCAML_TO_C
        TSAN_SETUP_C_CALL 32
    /* Save non-callee-saved registers r3, r4 and r5 */
        std     3, (RESERVED_STACK + 0)(SP)
        std     4, (RESERVED_STACK + 8)(SP)
        std     5, (RESERVED_STACK + 16)(SP)
    /* Necessary to include the caller of caml_runstack in the TSan backtrace */
        mr      3, 0            /* arg1: return address in caller */
        Far_call(caml_tsan_func_entry_asm)
        ld      5, (RESERVED_STACK + 16)(SP)
        ld      4, (RESERVED_STACK + 8)(SP)
        ld      3, (RESERVED_STACK + 0)(SP)
        TSAN_CLEANUP_AFTER_C_CALL 32
        SWITCH_C_TO_OCAML
#endif
  /* r3: fiber
     r4: fun
     r5: arg */
    /* Save return address and TOC */
        ENTER_FUNCTION
    /*  save old stack pointer and exception handler */
        lg      8, Caml_state(current_stack) /* r8 := old stack */
    /* Stack_sp records caml_runstack's entry frame, where ENTER_FUNCTION
       saved LR.  LEAVE_FUNCTION recovers it from Stack_sp + 16.  The TOC is
       saved just above that (PPC64 only), so that it survives a reallocation of
       this stack: caml_try_realloc_stack copies only [sp, Stack_high). */
        stg     SP, Stack_sp(8)
#if !defined(MODEL_ppc)
        std     2, TOC_SAVE_PARENT(SP)
#ifdef WITH_FRAME_POINTERS
    /* Keep the entry frame for use as fiber_bottom's back chain, then give
       caml_runstack a frame of its own so the back chain can be walked. */
        mr      25, SP
        stdu    SP, -RESERVED_STACK(SP)
        CFI_ADJUST(RESERVED_STACK)
#endif
#endif
        addi    3, 3, -1   /* r3 := Ptr_val(r3) */
        lg      12, 0(4)   /* r12 := code pointer */
        mtctr   12         /* CTR := code pointer */
        stg     TRAP_PTR, Stack_exception(8)
    /* Load new stack pointer and set parent */
        lg      TMP, Stack_handler(3)
        stg     8, Handler_parent(TMP)
        stg     3, Caml_state(current_stack)
        lg      9, Stack_sp(3) /* r9 := sp of new stack */
    /* Reserve 2*WORD DWARF and gc_regs block, which is unused here. */
        addi    9, 9, -(2*WORD)
    /* Create an exception handler on the target stack
       after 2*WORD DWARF & gc_regs block (which is unused here) */
        addi    9, 9, -TRAP_SIZE
        Addrlabel(TMP, fiber_exn_handler)
        stg     TMP, TRAP_HANDLER_OFFSET(9)
    /* link the previous exn_handler so that copying stacks works */
        lg      TMP, Stack_exception(3)
        stg     TMP, TRAP_PREVIOUS_OFFSET(9)
        mr      TRAP_PTR, 9
    /* Switch to the new stack, after reserving RESERVED_STACK bytes at bottom */
        addi    SP, 9, -RESERVED_STACK
#ifdef WITH_FRAME_POINTERS
    /* Link the fiber's back chain to caml_runstack's frame. */
        std     25, 0(SP)
#endif
#ifdef ASM_CFI_SUPPORTED
        CFI_REMEMBER_STATE
        .cfi_escape DW_CFA_def_cfa_expression, 5+3,                           \
            DW_OP_breg + DW_REG_sp, 0,                                        \
            DW_OP_plus_uconst,                                                \
              (RESERVED_STACK + TRAP_SIZE                                     \
               + 8 /* C stack SP for DWARF (unused) */                       \
               + 8 /* gc_regs slot (unused) */                               \
               + Handler_parent_offset),                                      \
            DW_OP_deref,                                                      \
            DW_OP_plus_uconst, Stack_sp_offset, DW_OP_deref
#if defined(MODEL_ppc)
        CFI_OFFSET(DW_REG_lr, LR_SAVE_OFFSET)  /* LR saved at CFA + 4 */
#else
        CFI_OFFSET(DW_REG_lr, LR_SAVE)  /* LR saved at CFA + LR_SAVE */
#endif
#endif
    /* Pre-initialize the LR save area at SP+16 with the return address, so
       the runtime's stack walk can find LR even if the first OCaml function
       does not save it (when fun_frame_required = false).  The address
       stored is .Lframe_runstack + 4, the instruction after bctrl. */
        INIT_LR_SAVE .Lframe_runstack, .Linit_runstack_lr
    /* Call the function on the new stack */
        mr      3, 5   /* argument */
.Lframe_runstack:
        bctrl
    /* Clean up on return */
        addi    8, SP, (RESERVED_STACK + TRAP_SIZE + 2*WORD)
                                       /* r8 := stack_handler */
        lg      25, Handler_value(8) /* saved across C call */
1:
        mr      26, 3                /* save return value across C call */
        lg      3, Caml_state(current_stack) /* arg to caml_free_stack */
    /* restore parent stack and exn_handler into Caml_state */
        lg      TMP, Handler_parent(8)
        stg     TMP, Caml_state(current_stack)
        lg      TRAP_PTR, Stack_exception(TMP)
        stg     TRAP_PTR, Caml_state(exn_handler)
    /* restore saved TOC (Stack_sp is caml_runstack's entry frame) */
        lg      27, Stack_sp(TMP)    /* saved across C calls */
#if !defined(MODEL_ppc)
        ld      2, TOC_SAVE_PARENT(27)
#endif
    /* free old stack by switching directly to c_stack;
       this is a no-alloc call */
        lg      SP, Caml_state(c_stack)
        Far_call(caml_free_stack)
    /* switch directly to parent stack (caml_runstack's frame) */
        mr      SP, 27 /* OCaml stack */
        CFI_RESTORE_STATE
#if defined(WITH_THREAD_SANITIZER) && !defined(MODEL_ppc)
    /* Signal to TSan that we exit caml_runstack (no registers to save here) */
        SWITCH_OCAML_TO_C
        TSAN_SETUP_C_CALL 0
        Far_call(caml_tsan_func_exit_asm)
        TSAN_CLEANUP_AFTER_C_CALL 0
        SWITCH_C_TO_OCAML
#endif
    /* pick correct return */
        mr      3, 26  /* return value */
        mr      4, 25  /* handler value */
        lg      12, 0(4) /* code pointer */
        mtctr   12       /* code pointer */
    /* Invoke handle_value (or handle_exn) */
        LEAVE_FUNCTION
        bctr
.Lfiber_exn_handler:
        addi    8, SP, (RESERVED_STACK + 2*WORD) /* r8 := stack_handler */
        lg      25, Handler_exception(8)
        b       1b
        CFI_ENDPROC
ENDOCAML_FUNCTION caml_runstack

FUNCTION caml_ml_array_bound_error
        CFI_STARTPROC
        TSAN_ENTER_FUNCTION /* needed since we skip caml_c_call entry */
#if defined(MODEL_ppc)
   /* Save LR before Addrglobal clobbers it (needed for backtrace) */
        mflr    0
        Addrglobal(C_CALL_FUN, caml_array_bound_error_asm)
        mtlr    0
#else
        Addrglobal(C_CALL_FUN, caml_array_bound_error_asm)
#endif
        b       .Lcaml_c_call
        CFI_ENDPROC
ENDFUNCTION caml_ml_array_bound_error

        TEXT_SECTION caml_system__code_end
        .globl  caml_system__code_end
caml_system__code_end:

/* Frametable - GC roots for callback */
/* Uses the same naming convention as ocamlopt generated modules. */
        .section ".data"
OBJECT caml_system.frametable
        datag   2               /* two descriptors */
        datag   .Lcaml_retaddr + 4  /* return address into callback */
        .short  -1              /* negative frame size => use callback link */
        .short  0               /* no roots */
#if defined(MODEL_ppc)
        .align  2
#else
        .align  3
#endif
        datag   .Lframe_runstack + 4 /* return address into fiber handler */
        .short  -1              /* negative frame size => use callback link */
        .short  0               /* no roots here */
#if defined(MODEL_ppc)
        .align 2
#else
        .align 3
#endif
ENDOBJECT caml_system.frametable

#if defined(MODEL_ppc)
/* Per-CU .got2 entries for PPC32.
   Each entry is a 32-bit absolute address resolved by the dynamic linker
   via R_PPC_ADDR32 relocations.  Code accesses these via PC-relative
   addressing to .LCTOC1 (centered at .got2 + 32768 for maximum range). */

        .section ".got2","aw"
        .balign 4
.LCTOC1 = . + 32768

#define GOT2ENTRY(glob) .Lgot2_##glob: .long glob

GOT2ENTRY(caml_apply2)
GOT2ENTRY(caml_apply3)
GOT2ENTRY(caml_program)
GOT2ENTRY(caml_exn_Stack_overflow)
GOT2ENTRY(caml_raise_unhandled_effect)
GOT2ENTRY(caml_raise_continuation_already_resumed)
GOT2ENTRY(caml_array_bound_error_asm)

#else
/* TOC entries */

        .section ".toc", "aw"

#define TOCENTRY(glob) LSYMB(glob): .quad glob
#define TOCENTRYLABEL(lbl) LLABEL(lbl): .quad .L##lbl

TOCENTRY(caml_apply2)
TOCENTRY(caml_apply3)
TOCENTRY(caml_program)
TOCENTRY(caml_exn_Stack_overflow)
TOCENTRY(caml_raise_unhandled_effect)
TOCENTRY(caml_raise_continuation_already_resumed)
TOCENTRY(caml_array_bound_error_asm)
TOCENTRYLABEL(fiber_exn_handler)
TOCENTRYLABEL(trap_handler)
#endif

        NONEXECSTACK_NOTE

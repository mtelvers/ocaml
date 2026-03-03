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

/* Machine-dependent interface with the asm code */

#ifndef CAML_STACK_H
#define CAML_STACK_H

#ifdef CAML_INTERNALS

/* Macros to access OCaml stacks */

/* An OCaml stack is composed of one or several "chunks", each chunk
   being a sequence of frames (activation records) for ocamlopt-generated
   functions.

   A chunk terminates when the OCaml code calls into C code
   (explicitly or to perform garbage collection or signal polling).

   A chunk starts when the program starts, or a fiber is created,
   or a callback is performed from C to OCaml.

   If [sp] points to the bottom of an OCaml stack,
   [First_frame(sp)] is the first stack frame of the first chunk of this stack.

   If [sp] points to the special frame for [caml_start_program] or
   [caml_callback_*], this marks the end of the current chunk.
   The saved value of [gc_regs] for the previous chunk is in
   [Saved_gc_regs(sp)], and [Stack_header_size] bytes must be skipped
   to find the first frame of the next chunk, or to reach the top of the stack.
*/

#ifdef TARGET_i386
/* Size of the gc_regs structure, in words.
   See i386.S and i386/proc.ml for the indices
   Bucket layout: [0]=next, [4]=eax, [8]=ebx, [12]=ecx, [16]=edx, [20]=esi, [24]=edi, [28]=ebp */
#define Wosize_gc_regs (1 /* next */ + 7 /* int regs: eax,ebx,ecx,edx,esi,edi,ebp */)
#define Saved_return_address_raw(sp) *((intnat *)((sp) - 4))
/* Callback header layout (16 bytes) with 8-byte trap frames:
   [0] prev_handler (trap frame part 1)
   [4] trap_addr (trap frame part 2)
   [8] gc_regs
   [12] c_stack_sp
   When hitting return-to-C frame (LBL(caml_retaddr)), sp points to the base of
   the callback header (offset 0). The return address was pushed by 'call' just
   below the header, so Saved_return_address_raw(sp) = *(sp-4) gives the pushed
   return address. Saved_gc_regs must read from sp+8 to get gc_regs. */
#define First_frame(sp) ((sp) + 8)
#define Saved_gc_regs(sp) (*(value **)((sp) + 8))
#define Stack_header_size 16
#endif

#ifdef TARGET_power
/* Size of the gc_regs structure, in words.
   See power.S and power/proc.ml for the indices */
#if defined(MODEL_ppc)
/* PPC32: 23 int regs (4B each) + 1 padding word + 14 float regs (8B = 2 words each) */
#define Wosize_gc_regs (23 + 1 + 14 * 2)
#define Saved_return_address_raw(sp) *((intnat *)((sp) + 4))
#define First_frame(sp) (sp)
/* RESERVED_STACK(8) + TRAP_SIZE(8) + WORD (skip DWARF word, gc_regs is second) */
#define Saved_gc_regs(sp) (*(value **)((sp) + 8 + 8 + 4))
#define Stack_header_size (8 + 8 + 8)
#else
/* PPC64 */
#ifdef WITH_FRAME_POINTERS
#define Wosize_gc_regs \
  (22 /* int regs, r23 is ALLOC_PTR */ + 14 /* caller-save float regs */)
#else
#define Wosize_gc_regs \
  (23 /* int regs, r23 is ALLOC_PTR, r31 allocatable */ \
   + 14 /* caller-save float regs */)
#endif
#define Saved_return_address_raw(sp) *((intnat *)((sp) + 16))
#define First_frame(sp) (sp)
/* Stack header layout: RESERVED_STACK (32) + TRAP_SIZE + gc_regs (16).
   TRAP_SIZE matches the value used in power.S and emit.mlp:
   48 with frame pointers, 16 otherwise. */
#ifdef WITH_FRAME_POINTERS
#define Saved_gc_regs(sp) (*(value **)((sp) + 32 + 48 + 8))
#define Stack_header_size (32 + 48 + 16)
#else
#define Saved_gc_regs(sp) (*(value **)((sp) + 32 + 16 + 8))
#define Stack_header_size (32 + 16 + 16)
#endif
#endif
#define CODE_POINTER_MARK_BIT 0
#endif

#ifdef TARGET_s390x
#define Wosize_gc_regs (2 + 9 /* int regs */ + 16 /* float regs */)
#define Saved_return_address_raw(sp) *((intnat *)((sp) - 8))
#define First_frame(sp) ((sp) + 8)
#define Saved_gc_regs(sp) (*(value **)((sp) + 24))
#define Stack_header_size 32
#endif

#ifdef TARGET_arm
/* Size of the gc_regs structure, in words.
   See arm.S and arm/proc.ml for the indices */
#define Wosize_gc_regs (2 + 9 /* int regs */ + 16 /* float regs */)
#define Saved_return_address_raw(sp) *((intnat *)((sp) - 4))
#define First_frame(sp) ((sp) + 8)
#define Saved_gc_regs(sp) (*(value **)((sp) + 12))
#define Stack_header_size 16
#endif

#ifdef TARGET_amd64
/* Size of the gc_regs structure, in words.
   See amd64.S and amd64/proc.ml for the indices */
#define Wosize_gc_regs (13 /* int regs */ + 16 /* float regs */)
#define Saved_return_address_raw(sp) *((intnat *)((sp) - 8))
#ifdef WITH_FRAME_POINTERS
#define First_frame(sp) ((sp) + 16)
#else
#define First_frame(sp) ((sp) + 8)
#endif
#define Saved_gc_regs(sp) (*(value **)((sp) + 24))
#define Stack_header_size 32
#endif

#ifdef TARGET_arm64
/* Size of the gc_regs structure, in words.
   See arm64.S and arm64/proc.ml for the indices */
#define Wosize_gc_regs (2 + 24 /* int regs */ + 24 /* float regs */)
#define Saved_return_address_raw(sp) *((intnat *)((sp) - 8))
#define First_frame(sp) ((sp) + 16)
#define Saved_gc_regs(sp) (*(value **)((sp) + 24))
#define Stack_header_size 32
#define CODE_POINTER_MARK_BIT 60
#endif

#ifdef TARGET_riscv
/* Size of the gc_regs structure, in words.
   See riscv.S and riscv/proc.ml for the indices */
#define Wosize_gc_regs (2 + 22 /* int regs */ + 20 /* float regs */)
#define Saved_return_address_raw(sp) *((intnat *)((sp) - 8))
#define First_frame(sp) ((sp) + 16)
#define Saved_gc_regs(sp) (*(value **)((sp) + 24))
#define Stack_header_size 32
#define CODE_POINTER_MARK_BIT 0
#endif

#ifdef CODE_POINTER_MARK_BIT
#define CODE_POINTER_MARK_MASK ((uintnat) 1 << CODE_POINTER_MARK_BIT)
#define Already_scanned(sp, retaddr) ((retaddr) & CODE_POINTER_MARK_MASK)
#define Mask_already_scanned(retaddr) ((retaddr) & ~CODE_POINTER_MARK_MASK)
#define Saved_return_address(sp) \
  Mask_already_scanned(Saved_return_address_raw(sp))
#define Mark_scanned(sp, retaddr) \
  Saved_return_address_raw(sp) = (retaddr) | CODE_POINTER_MARK_MASK
#else
#define Saved_return_address Saved_return_address_raw
#endif

/* Declaration of variables used in the asm code */
extern value * caml_globals[];
extern intnat caml_globals_inited;

#endif /* CAML_INTERNALS */

#endif /* CAML_STACK_H */

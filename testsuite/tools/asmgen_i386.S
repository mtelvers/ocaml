/**************************************************************************/
/*                                                                        */
/*                                OCaml                                   */
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

/* Linux with ELF binaries does not prefix identifiers with _.
   Linux with a.out binaries, FreeBSD, and NextStep do. */

#if defined(SYS_linux_elf) || defined(SYS_linux) || defined(SYS_bsd_elf) \
 || defined(SYS_solaris) || defined(SYS_beos) || defined(SYS_gnu)
#define G(x) x
#define FUNCTION_ALIGN 16
#else
#define G(x) _##x
#define FUNCTION_ALIGN 4
#endif

        .globl  G(call_gen_code)
        .align  FUNCTION_ALIGN
G(call_gen_code):
        pushl %ebp
        movl %esp,%ebp
        pushl %ebx
        pushl %esi
        pushl %edi
        movl 12(%ebp),%eax
        movl 16(%ebp),%ebx
        movl 20(%ebp),%ecx
        movl 24(%ebp),%edx
        call *8(%ebp)
        popl %edi
        popl %esi
        popl %ebx
        popl %ebp
        ret

        .globl  G(caml_c_call)
        .align  FUNCTION_ALIGN
G(caml_c_call):
        jmp     *%eax

        .comm   G(Caml_state), 4

/* For stack checks on i386, we need caml_state as a TLS variable pointing
   to a domain state structure. The stack check reads current_stack
   (offset 40) and compares against esp.
   We set current_stack to 0 so the check always passes in these tests. */
        .data
        .align  4
G(fake_domain_state):
        .space  40              /* offsets 0-39 */
        .long   0               /* offset 40: current_stack = 0 */
        .space  220             /* remaining domain state fields */

/* caml_state is accessed via TLS (%gs:caml_state@ntpoff) */
        .section .tdata,"awT",@progbits
        .align  4
        .globl  G(caml_state)
        .type   G(caml_state), @object
        .size   G(caml_state), 4
G(caml_state):
        .long   G(fake_domain_state)

/* Some tests are designed to cause registers to spill; on
 * x86 we require the caml_extra_params symbol from the RTS. */
        .data
        .globl  G(caml_extra_params)
G(caml_extra_params):
#ifndef SYS_solaris
        .space  64
#else
        .zero   64
#endif



#if defined(SYS_linux_elf) || defined(SYS_linux)
    /* Mark stack as non-executable */
        .section .note.GNU-stack,"",%progbits
#endif

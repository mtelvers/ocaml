(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cambium, INRIA Paris                  *)
(*                                                                        *)
(*   Copyright 2023 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* Compute the parameters needed for allocating and managing stack frames
   in the Emit phase. *)

open! Mach [@@warning "-66"]

let trap_handler_size = 8

class stackframe = object

inherit Stackframegen.stackframe_generic

method trap_handler_size = trap_handler_size

(* ARM has 3 register classes, so we need to check all of them *)
method! frame_required f contains_calls =
  contains_calls ||
  f.fun_num_stack_slots.(0) > 0 ||
  f.fun_num_stack_slots.(1) > 0 ||
  f.fun_num_stack_slots.(2) > 0

end

let analyze f =
  (new stackframe)#analyze f

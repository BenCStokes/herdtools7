(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* Jade Alglave, University College London, UK.                             *)
(* Luc Maranget, INRIA Paris-Rocquencourt, France.                          *)
(*                                                                          *)
(* Copyright 2015-present Institut National de Recherche en Informatique et *)
(* en Automatique and the authors. All rights reserved.                     *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law and   *)
(* abiding by the rules of distribution of free software. You can use,      *)
(* modify and/ or redistribute the software under the terms of the CeCILL-B *)
(* license as circulated by CEA, CNRS and INRIA at the following URL        *)
(* "http://www.cecill.info". We also give a copy in LICENSE.txt.            *)
(****************************************************************************)
(* Authors:                                                                 *)
(* Hadrien Renaud, University College London, UK.                           *)
(****************************************************************************)

open AST
open ASTUtils
open Infix

let _log = false

let list_update i f li =
  let rec aux acc i li =
    match (li, i) with
    | [], _ -> raise (Invalid_argument "list_update")
    | h :: t, 0 -> List.rev_append acc (f h :: t)
    | h :: t, i -> aux (h :: acc) (i - 1) t
  in
  aux [] i li

let mismatch_type v types =
  Error.fatal_unknown_pos (Error.MismatchType (v, types))

module NativeBackend = struct
  type 'a m = 'a
  type value = AST.value
  type primitive = value m list -> value list m
  type ast = primitive AST.t
  type scope = AST.identifier * int

  module ScopedIdentifiers = struct
    type t = identifier * scope

    let compare = compare
  end

  module SIMap = Map.Make (ScopedIdentifiers)

  let is_undetermined _ = false
  let v_of_int i = V_Int (Z.of_int i)
  let v_of_parsed_v = Fun.id
  let v_to_int = function V_Int i -> Some (Z.to_int i) | _ -> None
  let debug_value = PP.value_to_string
  let bind (vm : 'a m) (f : 'a -> 'b m) : 'b m = f vm
  let prod (r1 : 'a m) (r2 : 'b m) : ('a * 'b) m = (r1, r2)
  let return v = v

  let v_unknown_of_type ty =
    Types.base_value dummy_annotated StaticEnv.empty ty
    |> StaticInterpreter.static_eval StaticEnv.empty

  let warnT msg v =
    (* Should not be called... *)
    Printf.eprintf "Warning: message %s found its way, something is wrong\n" msg;
    return v

  let bind_data = bind
  let bind_seq = bind
  let bind_ctrl = bind

  let choice (c : value m) (m_true : 'b m) (m_false : 'b m) : 'b m =
    let open AST in
    bind c (function
      | V_Bool true -> m_true
      | V_Bool false -> m_false
      | v -> mismatch_type v [ T_Bool ])

  let delay m k = k m m
  let binop op v1 v2 = StaticInterpreter.binop_values dummy_annotated op v1 v2

  let ternary = function
    | V_Bool true -> fun m_true _m_false -> m_true ()
    | V_Bool false -> fun _m_true m_false -> m_false ()
    | v -> mismatch_type v [ T_Bool ]

  let unop op v = StaticInterpreter.unop_values dummy_annotated op v

  let on_write_identifier x scope value =
    if _log then
      Format.eprintf "Writing %a to %s in %a.@." PP.pp_value value x PP.pp_scope
        scope

  let on_read_identifier x scope value =
    if _log then
      Format.eprintf "Reading %a from %s in %a.@." PP.pp_value value x
        PP.pp_scope scope

  let v_tuple li = return (V_Tuple li)
  let v_record li = return (V_Record li)
  let v_exception li = return (V_Exception li)
  let non_tuple_exception v = mismatch_type v [ T_Tuple [] ]

  let doesnt_have_fields_exception v =
    mismatch_type v [ T_Record []; T_Exception [] ]

  let get_index i vec =
    match vec with
    | V_Tuple li -> List.nth li i |> return
    | v -> non_tuple_exception v

  let set_index i v vec =
    match vec with
    | V_Tuple li -> list_update i (Fun.const v) li |> v_tuple
    | v -> non_tuple_exception v

  let get_field name record =
    match record with
    | V_Record li | V_Exception li -> List.assoc name li
    | v -> doesnt_have_fields_exception v

  let set_field =
    let field_update name v li =
      (name, v) :: List.filter (fun (s, _) -> not (String.equal s name)) li
    in
    fun name v record ->
      match record with
      | V_Record li -> V_Record (field_update name v li)
      | V_Exception li -> V_Exception (field_update name v li)
      | v -> doesnt_have_fields_exception v

  let create_vector = v_tuple
  let create_record = v_record
  let create_exception = v_exception

  let as_bitvector = function
    | V_BitVector bits -> bits
    | V_Int i -> Bitvector.of_z (Z.numbits i) i
    | v -> mismatch_type v [ default_t_bits ]

  let as_int = function
    | V_Int i -> Z.to_int i
    | v -> mismatch_type v [ T_Int None ]

  let bitvector_to_value bv = return (V_BitVector bv)

  let int_max x y = if x >= y then x else y

  let read_from_bitvector positions bv =
    let positions = slices_to_positions as_int positions in
    let max_pos = List.fold_left int_max 1 positions in
    let bv =
      match bv with
      | V_BitVector bv -> bv
      | V_Int i -> Bitvector.of_z (max_pos + 1) i
      | _ -> mismatch_type bv [ default_t_bits ]
    in
    let res = Bitvector.extract_slice bv positions in
    bitvector_to_value res

  let write_to_bitvector positions bits bv =
    let bv = as_bitvector bv
    and bits = as_bitvector bits
    and positions = slices_to_positions as_int positions in
    Bitvector.write_slice bv bits positions |> bitvector_to_value

  let concat_bitvectors bvs =
    let bvs = List.map as_bitvector bvs in
    Bitvector.concat bvs |> bitvector_to_value
end

module NativePrimitives = struct
  open NativeBackend

  let return_one v = return [ return v ]

  let uint = function
    | [ V_BitVector bv ] -> V_Int (Bitvector.to_z_unsigned bv) |> return_one
    | [ v ] ->
        Error.fatal_unknown_pos @@ Error.MismatchType (v, [ default_t_bits ])
    | li -> Error.fatal_unknown_pos @@ Error.BadArity ("UInt", 1, List.length li)

  let sint = function
    | [ V_BitVector bv ] -> V_Int (Bitvector.to_z_signed bv) |> return_one
    | [ v ] ->
        Error.fatal_unknown_pos @@ Error.MismatchType (v, [ default_t_bits ])
    | li -> Error.fatal_unknown_pos @@ Error.BadArity ("SInt", 1, List.length li)

  let print =
    let print_one = function
      | V_String s -> Printf.printf "%s " s
      | v -> Error.fatal_unknown_pos @@ Error.MismatchType (v, [ T_String ])
    in
    fun li ->
      List.iter print_one li;
      Printf.printf "\n%!";
      return []

  let dec_str = function
    | [ V_Int i ] -> V_String (Z.to_string i) |> return_one
    | [ v ] ->
        Error.fatal_unknown_pos @@ Error.MismatchType (v, [ integer.desc ])
    | li ->
        Error.fatal_unknown_pos @@ Error.BadArity ("DecStr", 1, List.length li)

  let hex_str = function
    | [ V_Int i ] -> V_String (Printf.sprintf "%a" Z.sprint i) |> return_one
    | [ v ] ->
        Error.fatal_unknown_pos @@ Error.MismatchType (v, [ integer.desc ])
    | li ->
        Error.fatal_unknown_pos @@ Error.BadArity ("DecStr", 1, List.length li)

  let ascii_range = Constraint_Range (!$0, !$127)
  let ascii_integer = T_Int (Some [ ascii_range ])

  let ascii_str =
    let open! Z in
    function
    | [ V_Int i ] when geq zero i && leq ~$127 i ->
        V_String (char_of_int (Z.to_int i) |> String.make 1) |> return_one
    | [ v ] ->
        Error.fatal_unknown_pos @@ Error.MismatchType (v, [ ascii_integer ])
    | li ->
        Error.fatal_unknown_pos @@ Error.BadArity ("DecStr", 1, List.length li)

  let log2 = function
    | [ V_Int i ] when Z.gt i Z.zero -> [ V_Int (Z.log2 i |> Z.of_int) ]
    | [ v ] -> Error.fatal_unknown_pos @@ Error.MismatchType (v, [ T_Int None ])
    | li -> Error.fatal_unknown_pos @@ Error.BadArity ("Log2", 1, List.length li)

  let primitives =
    let with_pos = add_dummy_pos in
    let t_bits e = T_Bits (BitWidth_SingleExpr e, []) |> with_pos in
    let e_var x = E_Var x |> with_pos in
    let d_func_string i =
      D_Func
        {
          name = "print";
          parameters = [];
          args = List.init i (fun j -> ("s" ^ string_of_int j, string));
          body = SB_Primitive print;
          return_type = None;
          subprogram_type = ST_Procedure;
        }
    in
    let here = ASTUtils.add_pos_from_pos_of in
    [
      D_Func
        {
          name = "UInt";
          parameters = [ ("N", Some integer) ];
          args = [ ("x", t_bits (e_var "N")) ];
          body = SB_Primitive uint;
          return_type = Some integer;
          subprogram_type = ST_Function;
        }
      |> __POS_OF__ |> here;
      D_Func
        {
          name = "SInt";
          parameters = [ ("N", Some integer) ];
          args = [ ("x", t_bits (e_var "N")) ];
          body = SB_Primitive sint;
          return_type = Some integer;
          subprogram_type = ST_Function;
        }
      |> __POS_OF__ |> here;
      D_Func
        {
          name = "DecStr";
          parameters = [];
          args = [ ("x", integer) ];
          body = SB_Primitive dec_str;
          return_type = Some string;
          subprogram_type = ST_Function;
        }
      |> __POS_OF__ |> here;
      D_Func
        {
          name = "HexStr";
          parameters = [];
          args = [ ("x", integer) ];
          body = SB_Primitive hex_str;
          return_type = Some string;
          subprogram_type = ST_Function;
        }
      |> __POS_OF__ |> here;
      D_Func
        {
          name = "AsciiStr";
          parameters = [];
          args = [ ("x", integer) ];
          body = SB_Primitive ascii_str;
          return_type = Some string;
          subprogram_type = ST_Function;
        }
      |> __POS_OF__ |> here;
      D_Func
        {
          name = "Log2";
          parameters = [];
          args = [ ("x", integer) ];
          body = SB_Primitive log2;
          return_type = Some integer;
          subprogram_type = ST_Function;
        }
      |> __POS_OF__ |> here;
      d_func_string 0 |> __POS_OF__ |> here;
      d_func_string 1 |> __POS_OF__ |> here;
      d_func_string 2 |> __POS_OF__ |> here;
      d_func_string 3 |> __POS_OF__ |> here;
      d_func_string 4 |> __POS_OF__ |> here;
    ]
end

module NativeInterpreter (C : Interpreter.Config) =
  Interpreter.Make (NativeBackend) (C)

let exit_value = function
  | V_Int i -> i |> Z.to_int
  | v -> Error.fatal_unknown_pos (Error.MismatchType (v, [ T_Int None ]))

let instrumentation_buffer = function
  | Some true ->
      (module Instrumentation.SingleSetBuffer : Instrumentation.BUFFER)
  | Some false | None ->
      (module Instrumentation.NoBuffer : Instrumentation.BUFFER)

let interprete strictness ?instrumentation ?static_env ast =
  let module B = (val instrumentation_buffer instrumentation) in
  let module C : Interpreter.Config = struct
    let type_checking_strictness = strictness
    let unroll = 0

    module Instr = Instrumentation.Make (B)
  end in
  let module I = NativeInterpreter (C) in
  B.reset ();
  let res =
    match static_env with
    | Some static_env -> I.run_typed ast static_env
    | None ->
        let ast = List.rev_append NativePrimitives.primitives ast in
        I.run ast
  in
  (exit_value res, B.get ())

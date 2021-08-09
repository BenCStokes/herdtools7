(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* Jade Alglave, University College London, UK.                             *)
(* Luc Maranget, INRIA Paris, France.                                       *)
(*                                                                          *)
(* Copyright 2020-present Institut National de Recherche en Informatique et *)
(* en Automatique and the authors. All rights reserved.                     *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law and   *)
(* abiding by the rules of distribution of free software. You can use,      *)
(* modify and/ or redistribute the software under the terms of the CeCILL-B *)
(* license as circulated by CEA, CNRS and INRIA at the following URL        *)
(* "http://www.cecill.info". We also give a copy in LICENSE.txt.            *)
(****************************************************************************)

open Printf

module Attrs = struct
  type t = StringSet.t

  (* By default we assume the attributes of the memory malloc would
     return on Linux. This is architecture specific, however, for now,
     translation is supported only for AArch64. *)
  let default =
    List.fold_right StringSet.add
      [ "Normal" ; "Inner-shareable"; "Inner-write-back"; "Outer-write-back" ]
      StringSet.empty

  let compare a1 a2 = StringSet.compare a1 a2
  let eq a1 a2 = StringSet.equal a1 a2
  let pp a = String.concat ", " (StringSet.elements a)
  let as_list a = StringSet.elements a
  let of_list l = StringSet.of_list l
end

type oa_t = PTE of string | PHY of string

let pp_oa_old = function
| PTE s -> Misc.add_pte s
| PHY s -> Misc.add_physical s

let pp_oa = function
| PTE s -> Misc.pp_pte s
| PHY s -> Misc.pp_physical s

let oa_compare oa1 oa2 = match oa1,oa2 with
| (PHY s1,PHY s2)
| (PTE s1,PTE s2)
  -> String.compare s1 s2
| PHY _,PTE _ -> -1
| PTE _,PHY _ -> 1

let oa_eq oa1 oa2 = match oa1,oa2 with
| (PHY s1,PHY s2)
| (PTE s1,PTE s2)
  -> Misc.string_eq s1 s2
| (PHY _,PTE _)
| (PTE _,PHY _)
  -> false

let as_physical = function
| PHY s -> Some s
| PTE _ -> None

let as_pte = function
| PTE s -> Some s
| PHY _ -> None

let oa_refers_virtual = function
| PTE s|PHY s -> Some s

type t = {
  oa : oa_t ;
  valid : int;
  af : int;
  db : int;
  dbm : int;
  el0 : int;
  attrs: Attrs.t;
  }

(* For ordinary tests not to fault, the dirty bit has to be set. *)
let prot_default =  { oa=PHY ""; valid=1; af=1; db=1; dbm=0; el0=1; attrs=Attrs.default; }
let default s = { prot_default with  oa=PHY s; }

(* Page table entries for pointers into the page table
   have el0 flag unset. Namely, page table access from
   EL0 is disallowed. This correspond to expected behaviour:
   user code cannot access the page table. *)
let of_pte s = { prot_default with  oa=PTE s; el0=0; }

let pp_field ok pp eq ac p k =
  let f = ac p in if not ok && eq f (ac prot_default) then k else pp f::k

let pp_int_field ok name = pp_field ok (sprintf "%s:%i" name) Misc.int_eq
let pp_valid ok = pp_int_field ok "valid" (fun p -> p.valid)
and pp_af ok = pp_int_field ok "af" (fun p -> p.af)
and pp_db ok = pp_int_field ok "db" (fun p -> p.db)
and pp_dbm ok = pp_int_field ok "dbm" (fun p -> p.dbm)
and pp_el0 ok = pp_int_field ok "el0" (fun p -> p.el0)
and pp_attrs ok = pp_field ok (fun a -> Attrs.pp a) Attrs.eq (fun p -> p.attrs)

let set_oa p s = { p with oa = PHY s; }

let is_default t =
  let d = prot_default in
  t.valid=d.valid && t.af=d.af && t.db=d.db && t.dbm=d.dbm && t.el0=d.el0 &&
    t.attrs=Attrs.default

(* If showall is true, field will always be printed.
   Otherwise, field will be printed only if non-default.
   While computing hashes, backward compatibility commands that:
   (1) Fields older than el0 are always printed.
   (2) Fields from el0 (included) are printed if non-default. *)

let do_pp showall old_oa p =
  let k = pp_attrs false p [] in
  let k = pp_el0 false p k in
  let k = pp_valid showall p k in
  let k = pp_dbm showall p k in
  let k = pp_db showall p k in
  let k = pp_af showall p k in
  let k = sprintf "oa:%s" ((if old_oa then pp_oa_old else pp_oa) p.oa)::k  in
  let fs = String.concat ", " k in
  sprintf "(%s)" fs

(* By default pp does not list fields whose value is default *)
let pp = do_pp false false
(* For initial values dumped for hashing, pp_hash is different,
   for not altering hashes as much as possible *)
let pp_hash = do_pp true true

let my_int_of_string s v =
  let v = try int_of_string v with
    _ -> Warn.user_error "PTE field %s should be an integer" s
  in v

type pte_prop =
  | KV of (string * string)
  | Attrs of string list

let tr_oa s = match Misc.tr_physical s with
| Some s -> PHY s
| None ->
   begin
     match Misc.tr_pte s with
     | Some s -> PTE s
     | None ->
        Warn.user_error
          "identifier %s cannot be used as output address" s
   end

let do_of_list p l =
  let add_field a v = match v with
    | KV (s, v) -> begin
        match s with
        | "oa" -> { a with oa = tr_oa v }
        | "af" -> { a with af = my_int_of_string s v }
        | "db" -> { a with db = my_int_of_string s v }
        | "dbm" -> { a with dbm = my_int_of_string s v }
        | "valid" -> { a with valid = my_int_of_string s v }
        | "el0" -> { a with el0 = my_int_of_string s v }
        | _ ->
           Warn.user_error "Illegal PTE property %s" s
      end
    | Attrs l -> { a with attrs = Attrs.of_list l }
  in
  let rec of_list a = function
    | [] -> a
    | h::t -> of_list (add_field a h) t in

  of_list p l

let of_list s = do_of_list (default s)
and of_list0 = do_of_list prot_default

let lex_compare c1 c2 x y  = match c1 x y with
| 0 -> c2 x y
| r -> r

let compare =
  let cmp = (fun p1 p2 -> Misc.int_compare p1.el0 p2.el0) in
  let cmp =
    lex_compare (fun p1 p2 -> Misc.int_compare p1.valid p2.valid) cmp in
  let cmp =
    lex_compare (fun p1 p2 -> Misc.int_compare p1.dbm p2.dbm) cmp in
  let cmp =
    lex_compare (fun p1 p2 -> Misc.int_compare p1.db p2.db) cmp in
  let cmp =
    lex_compare (fun p1 p2 -> Misc.int_compare p1.af p2.af) cmp in
  let cmp =
    lex_compare (fun p1 p2 -> oa_compare p1.oa p2.oa) cmp in
  let cmp =
    lex_compare (fun p1 p2 -> Attrs.compare p1.attrs p2.attrs) cmp in
  cmp

let eq p1 p2 =
  oa_eq p1.oa p2.oa &&
  Misc.int_eq p1.af p2.af &&
  Misc.int_eq p1.db p2.db &&
  Misc.int_eq p1.dbm p2.dbm &&
  Misc.int_eq p1.valid p2.valid &&
  Misc.int_eq p1.el0 p2.el0 &&
  Attrs.eq p1.attrs p2.attrs

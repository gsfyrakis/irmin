(*
 * Copyright (c) 2013 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt

let debug fmt =
  IrminLog.debug "CRUD" fmt

exception Error of string

let uri t path = match Uri.path t :: path with
  | []   -> t
  | path -> Uri.with_path t (String.concat "/" path)

type ('a, 'b) response =
  (IrminJSON.t -> 'a) -> (Cohttp_lwt_unix.Response.t * Cohttp_lwt_body.t) option -> 'b

let result_of_json json =
  let json = IrminJSON.to_dict json in
  let error =
    try Some (List.assoc "error" json)
    with Not_found -> None in
  let result =
    try Some (List.assoc "result" json)
    with Not_found -> None in
  match error, result with
  | None  , None   -> raise (Error "result_of_json")
  | Some e, None   -> raise (Error (IrminJSON.output e))
  | None  , Some r -> r
  | Some _, Some _ -> raise (Error "result_of_json")

let map_string_response fn = function
  | None       -> fail (Error "map_string_response")
  | Some (_,b) ->
    Cohttp_lwt_body.string_of_body b >>= function b ->
      debug "response: body=%s" b;
      let j = IrminJSON.input b in
      try return (fn (result_of_json j))
      with Error e -> fail (Error e)

let map_stream_response fn = function
  | None       -> raise (Error "map_stream_response")
  | Some (_,b) ->
    let stream = Cohttp_lwt_body.stream_of_body b in
    let stream = IrminJSON.of_stream stream in
    let stream = Lwt_stream.map result_of_json stream in
    Lwt_stream.map fn stream

let map_get t path fn =
  debug "get %s" (Uri.to_string (uri t path));
  Cohttp_lwt_unix.Client.get (uri t path) >>=
  fn

let get t path fn =
  map_get t path (map_string_response fn)

let get_stream t path fn  =
  let (stream: 'a Lwt_stream.t option ref) = ref None in
  let rec get () =
    match !stream with
    | Some s -> Lwt_stream.get s
    | None   ->
      map_get t path (fun b ->
          let s = map_stream_response fn b in
          stream := Some s;
          return_unit) >>= fun () ->
       get () in
  Lwt_stream.from get

let delete t path fn =
  debug "delete %s" (Uri.to_string (uri t path));
  Cohttp_lwt_unix.Client.delete (uri t path) >>=
  map_string_response fn

let post t path body fn =
  debug "post %s" (Uri.to_string (uri t path));
  let body =
    let params = `O [ "params", body ] in
    match Cohttp_lwt_body.body_of_string (IrminJSON.output params) with
    | Some c -> c
    | None   -> assert false in
  Cohttp_lwt_unix.Client.post ~body (uri t path) >>=
  map_string_response fn

module type U = sig
  val uri: Uri.t
end

module X (U: U) (K: IrminKey.S) (V: IrminBase.S) = struct

  let debug fmt =
    IrminLog.debug ("CRUD" ^ Uri.path U.uri) fmt

  type t = Uri.t

  type key = K.t

  type value = V.t

  let some fn x =
    Some (fn x)

  let unknown k =
    fail (K.Unknown (K.pretty (K.of_string k)))

  let create () =
    return U.uri

  let read t key =
    debug "read %s" (K.pretty key);
    catch
      (fun () -> get t ["read"; K.pretty key] (some V.of_json))
      (fun _  -> return_none)

  let read_exn t key =
    debug "read_exn %s" (K.pretty key);
    get t ["read"; K.pretty key] V.of_json

  let mem t key =
    debug "mem %s" (K.pretty key);
    get t ["mem"; K.pretty key] IrminJSON.to_bool

  let list t key =
    debug "list %s" (K.pretty key);
    get t ["list"; K.pretty key] (IrminJSON.to_list K.of_json)

  let contents t =
    debug "contents";
    get t ["contents"] (IrminJSON.to_list (IrminJSON.to_pair K.of_json V.of_json))

end

module A (U: U) (K: IrminKey.S) (V: IrminBase.S) = struct

  include X(U)(K)(V)

  let add t value =
    debug "add %s"(V.pretty value);
    post t ["add"] (V.to_json value) K.of_json

end

module M (U: U) (K: IrminKey.S) (V: IrminBase.S) = struct

  include X(U)(K)(V)

  let update t key value =
    debug "update %s %s" (K.pretty key) (V.pretty value);
    post t ["update"; K.pretty key] (V.to_json value) IrminJSON.to_unit

  let remove t key =
    debug "remove %s" (K.pretty key);
    delete t ["remove"; K.pretty key] IrminJSON.to_unit

end

module S (U: U) (K: IrminKey.S) (V: IrminBase.S) (R: IrminKey.BINARY) (D: IrminBase.S) = struct

  include M(U)(K)(V)

  type revision = R.t

  type dump = D.t

  let snapshot t =
    debug "snapshot";
    get t ["snapshot"] R.of_json

  let revert t rev =
    debug "revert";
    get t ["revert"; R.pretty rev] IrminJSON.to_unit

  let watch t path =
    debug "watch";
    get_stream t ["watch"; K.pretty path] (IrminJSON.to_pair K.of_json R.of_json)

  let export t revs =
    debug "export %s" (IrminMisc.pretty_list R.pretty revs);
    get t ("export" :: List.map R.to_hex revs) D.of_json

  let import t dump =
    debug "dump";
    post t ["import"] (D.to_json dump) IrminJSON.to_unit

end

let simple u =
  let module Value = A(struct
      let uri = uri u ["value"]
    end) in
  let module Tree = A(struct
      let uri = uri u ["tree"]
    end) in
  let module Revision = A(struct
      let uri = uri u ["revision"]
    end )in
  let module Tag = M(struct
      let uri = uri u ["tag"]
    end) in
  let module Store = S(struct
      let uri = u
    end) in
  let module K = IrminKey.SHA1 in
  let module V = IrminValue.Simple in
  let module Simple = Irmin.Proxy
      (Store)
      (IrminKey.SHA1)(IrminValue.Simple)(IrminTag.Simple)
      (Value)
      (Tree)
      (Revision)
      (Tag) in
  (module Simple: Irmin.SIMPLE)
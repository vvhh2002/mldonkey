(* Copyright 2001, 2002 b8_bavard, b8_fee_carabine, INRIA *)
(*
    This file is part of mldonkey.

    mldonkey is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    mldonkey is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with mldonkey; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
*)

open Md4
open CommonShared
open Printf2
open CommonInteractive
open CommonClient
open CommonComplexOptions
open CommonTypes
open CommonFile
open Options
open BasicSocket
open TcpBufferedSocket

open CommonGlobals
open CommonOptions

(* We should implement a common uploader too for all networks where
upload is done linearly. *)
  
(*******************************************************************

  
                         TYPES

  
*******************************************************************)

  
  
type shared_file = {
    shared_fullname : string;
    shared_codedname : string;
    shared_size : int64;
    shared_fd : Unix32.t;
    shared_id : int;
    shared_format : CommonTypes.format;
    shared_impl : shared_file shared_impl;
    mutable shared_uids : file_uid list;
    mutable shared_uids_wanted : 
    (file_uid_id * (shared_file -> file_uid -> unit)) list;
  }

and shared_tree =
  { 
    shared_dirname : string;
    mutable shared_files : shared_file list;
    mutable shared_dirs : (string * shared_tree) list;
  }

let network = CommonNetwork.new_network "Global Shares"
    (fun _ -> "")
    (fun _ -> "")

let _ = 
  network.op_network_connected <- (fun _ -> false);
  network.op_network_is_enabled <- (fun _ -> raise IgnoreNetwork);
  network.op_network_info <- (fun _ -> raise Not_found)
  
let (shared_ops : shared_file CommonShared.shared_ops) = 
  CommonShared.new_shared_ops network

  
  
  
  
(*******************************************************************

  
                    HASHES COMPUTATION

  
*******************************************************************)
  
  
let waiting_shared_files = ref []

(* The shared files indexed by the strings (lowercase), corresponding to
their uids *)
let shareds_by_uid = Hashtbl.create 13
  
let current_job = ref None

let rec start_job_for sh (wanted_id, handler) = 
  try
    List.iter (fun id ->
        match wanted_id,id with
          BITPRINT, Bitprint _ 
        | SHA1, Sha1 _
        | ED2K, Ed2k _
        | MD5, Md5 _ 
          -> (try handler sh id with _ -> ()); raise Exit
        | _ -> ()
    ) sh.shared_uids;
    
    match wanted_id with
      SHA1 -> 
        CommonHasher.compute_sha1 (Unix32.filename sh.shared_fd)
        zero sh.shared_size (fun job ->
            if job.CommonHasher.job_error then begin
                lprintf "Error during hashing of %s\n" sh.shared_fullname; 
                current_job := None;
              end else
              begin
                let sha1 = Sha1.direct_of_string job.CommonHasher.job_result
                in
                let urn = Printf.sprintf "urn:sha1:%s" (Sha1.to_string sha1)
                in
                lprintf "%s has uid %s (%s)\n" sh.shared_fullname urn
                (Base16.to_string 20 job.CommonHasher.job_result)
                ;
                let uid = Sha1 (urn,sha1) in
                sh.shared_uids <- uid :: sh.shared_uids;
                Hashtbl.add shareds_by_uid (String.lowercase urn) sh;
                start_job_for sh (wanted_id, handler)  
              end
        );
    | _ -> raise Exit
    
  with Exit -> 
      current_job := None
  
  
let shared_files_timer _ =
  match !current_job with
  | Some _ -> ()
  | None ->
      match !waiting_shared_files with
        [] -> ()
      | sh :: tail ->
          match sh.shared_uids_wanted with
            [] ->  waiting_shared_files := tail;
          | uid :: tail ->
              sh.shared_uids_wanted <- tail;
              current_job := Some sh;
              start_job_for sh uid

let ask_for_uid sh uid f =
  sh.shared_uids_wanted <- (uid,f) :: sh.shared_uids_wanted;
  waiting_shared_files := sh :: !waiting_shared_files
              
(*******************************************************************

  
                      DATA STRUCTURES

  
*******************************************************************)
  
let shareds_counter = ref 0
let shared_counter = ref (Int64.zero)
let shared_files = Hashtbl.create 13 
  
module Document = struct
    type t = shared_file
      
    let num t = t.shared_id
    let filtered t = false
    let filter t bool = ()
  end

module DocIndexer = Indexer2.FullMake(Document)
  
let index = DocIndexer.create ()
let table = Hashtbl.create 1023     

let filesize_field = "size"
  
(*******************************************************************

  
                      INDEXER

  
*******************************************************************)

  
module Indexer = struct
        
let stem s =
  let s = String.lowercase (String.copy s) in
  for i = 0 to String.length s - 1 do
    let c = s.[i] in
    match c with
      'a'..'z' | '0' .. '9' -> ()
    | _ -> s.[i] <- ' ';
  done;
  String2.split_simplify s ' '

let name_bit = 1
(* "size" *)
(* "bitrate" *)
let artist_bit = 2 (* tag "Artiste" *)
let title_bit = 4  (* tag "Title" *)
let album_bit = 8 (* tag "Album" *)
let media_bit = 16 (* "type" *)
let format_bit = 32 (* "format" *)
      
let index_string doc s fields =
  let words = stem s in
  List.iter (fun s ->
(*      lprintf "ADD [%s] in index" s; lprint_newline (); *)
      DocIndexer.add  index s doc fields
  ) words 
  
let index_name doc name = 
  index_string doc name 1 (* general search have field 1 *)

(***********************************************)

let bit_of_field field =
  match field with
  | Field_Filename -> name_bit
  | Field_Artist -> artist_bit
  | Field_Title -> title_bit
  | Field_Album -> album_bit
  | Field_Format -> format_bit 
  | Field_Type -> media_bit
  | _ -> raise Not_found
        
let rec query_to_query t = 
  match t with
  | QAnd (q1,q2) -> Indexer.And (query_to_query q1, query_to_query q2)
  | QOr (q1, q2) -> Indexer.Or (query_to_query q1, query_to_query q2)
  | QAndNot (q1,q2) -> Indexer.AndNot (query_to_query q1, query_to_query q2)
  | QHasWord w -> Indexer.HasWord w
  | QHasField (field, w) -> Indexer.HasField(bit_of_field field, w)
  | QHasMinVal (field, minval) -> 
      Indexer.Predicate (fun s -> 
          match field with 
          | Field_Size -> s.shared_size >= minval
          | _ -> true)
  | QHasMaxVal (field, maxval) -> 
      Indexer.Predicate (fun s -> 
          match field with 
          | Field_Size -> s.shared_size <= maxval
          | _ -> true)
    
      
  | _ -> failwith "Query not implemented by server"
      
(*
  
type query =
  QAnd of query * query
| QOr of query * query
| QAndNot of query * query
| QHasWord of string
| QHasField of string * string
| QHasMinVal of string * int32
| QHasMaxVal of string * int32
  
type 'a query =
  And of 'a query * 'a query
| Or of 'a query * 'a query
| AndNot of 'a query * 'a query
| HasWord of string
| HasField of int * string
| Predicate of ('a -> bool)

    *)

let index_file s =
  index_string s s.shared_codedname name_bit

  (*
  List.iter (fun tag ->
      match tag with
      | { tag_name = "filename"; tag_value = String s } -> 
          index_string doc s name_bit
      | { tag_name = "Artist"; tag_value = String s } -> 
          index_string doc s artist_bit
      | { tag_name = "Title"; tag_value = String s } -> 
          index_string doc s title_bit
      | { tag_name = "Album"; tag_value = String s } -> 
          index_string doc s album_bit
      | { tag_name = "format"; tag_value = String s } -> 
          index_string doc s format_bit
      | { tag_name = "type"; tag_value = String s } -> 
          index_string doc s media_bit
      | _ -> ()
  ) file.f_tags  
*)
  
(*
let add file = 
  try
    let doc = Hashtbl.find table file.f_md4 in
    let file2 = Store.get store doc in

    if file <> file2 then
      index_file doc file;
    (*lprintf "Must check files with same md4"; lprint_newline ();*)
    ()
  with _ ->
      let doc = Store.add store file in
      Hashtbl.add table file.f_md4 doc;
      index_file doc file;
      ()   

let get_def file_md4 =
  let doc = Hashtbl.find table file_md4 in
    (Store.get store doc)
  *)

let find query = DocIndexer.query index query 
        
let find_map query = 
  DocIndexer.query_map index query

(*
let get docs num = 
  let len = Array.length docs.docs in
  let rec iter pos num list =
    if num = 0 || pos >= len then
      begin
        docs.next_doc <- pos;
        if pos >= len then
          docs.docs <- [||];
        list
      end
    else
      iter (pos+1) (num-1) (Store.get store docs.docs.(pos) :: list)
  in
  iter docs.next_doc num []
*)
end
  
(*******************************************************************

  
                      FUNCTIONS

  
*******************************************************************)

  
let new_shared_dir dirname = {
    shared_dirname = dirname;
    shared_files = [];
    shared_dirs = [];
  }

let shared_tree = new_shared_dir ""

let rec add_shared_file node sh dir_list =
  match dir_list with
    [] -> assert false
  | [filename] ->
      node.shared_files <- sh :: node.shared_files
  | dirname :: dir_tail ->
      let node =
        try
          List.assoc dirname node.shared_dirs
        with _ ->
            let new_node = new_shared_dir dirname in
            node.shared_dirs <- (dirname, new_node) :: node.shared_dirs;
            new_node
      in
      add_shared_file node sh dir_tail
  
let add_shared full_name codedname size =
  try
    Hashtbl.find shared_files codedname
  with Not_found ->
      incr shareds_counter;
      
      let rec impl = {
          impl_shared_update = 1;
          impl_shared_fullname = full_name;
          impl_shared_codedname = codedname;
          impl_shared_size = size;
          impl_shared_id = Md4.random ();
          impl_shared_num = 0;
          impl_shared_uploaded = Int64.zero;
          impl_shared_ops = shared_ops;
          impl_shared_val = sh;
          impl_shared_requests = 0;
        } 
      and sh = {
          shared_fullname = full_name;
          shared_codedname = codedname;
          shared_size = size;
          shared_id = !shareds_counter;
          shared_fd=  Unix32.create full_name [Unix.O_RDONLY] 0o444;
          shared_format = CommonMultimedia.get_info full_name;
          shared_impl = impl;
          shared_uids_wanted = [];
          shared_uids = [];
        } in
      
      update_shared_num impl;
      
      lprintf "FILE ADDED: %s" codedname; lprint_newline ();
      Hashtbl.add table !shareds_counter sh;
      Hashtbl.add shared_files codedname sh;
      Indexer.index_file sh;
      add_shared_file shared_tree sh (String2.split codedname '/');
      shared_counter := Int64.add !shared_counter size;
      lprintf "Total shared : %s" (Int64.to_string !shared_counter);
      lprint_newline () ;
      sh
      
let query q = Indexer.find (Indexer.query_to_query q)
  
let find_by_name name = Hashtbl.find shared_files name
  
let find_by_num num = Hashtbl.find table num

(**********************************************************************


                     UPLOAD SCHEDULER


***********************************************************************)

let client_is_connected c = is_connected (client_state c)
  

(* Move the uploaders and nu commands to driver *)







let upload_clients = (Fifo.create () : client Fifo.t)


let (pending_slots_map : client Intmap.t ref) = ref Intmap.empty
(* let (pending_slots_fifo : int Fifo.t)  = Fifo.create () *)

let remaining_bandwidth = ref 0    
let total_bandwidth = ref 0    
let complete_bandwidth = ref 0
let counter = ref 1    
let sent_bytes = Array.create 10 0
let has_upload = ref 0
let upload_credit = ref 0


let can_write_len sock len =
  can_write_len sock len && 
  (let upload_rate = 
      (if !!max_hard_upload_rate = 0 then 10000 else !!max_hard_upload_rate)
      * 1024 in
    not_buffer_more sock (upload_rate * (Fifo.length upload_clients)))

let upload_to_one_client () =
  if !remaining_bandwidth < 10000 then begin
      let c = Fifo.take upload_clients in
      client_can_upload c  !remaining_bandwidth
    end else
  let per_client = 
    let len = Fifo.length upload_clients in
    if len * 10000 < !remaining_bandwidth then
(* Each client in the Fifo can receive 10000 bytes.
Divide the bandwidth between the clients
*)
      (!remaining_bandwidth / 10000 / len) * 10000
    else mini 10000 !remaining_bandwidth in
  let c = Fifo.take upload_clients in
  client_can_upload c per_client

let rec fifo_uploads n =
  if n>0 && !remaining_bandwidth > 0 then
    begin
      upload_to_one_client ();
      fifo_uploads (n-1)
    end

let rec next_uploads () =
(*  lprintf "next_uploads %d\n" !remaining_bandwidth; *)
  let old_remaining_bandwidth = !remaining_bandwidth in
  let len = Fifo.length upload_clients in
  fifo_uploads len;
  if !remaining_bandwidth < old_remaining_bandwidth then
    next_uploads ()

let next_uploads () = 
  sent_bytes.(!counter-1) <- sent_bytes.(!counter-1) - !remaining_bandwidth;
  if !verbose_upload then begin
      lprintf "Left %d\n" !remaining_bandwidth; 
    end;
  complete_bandwidth := !complete_bandwidth + !remaining_bandwidth;
  incr counter;
  if !counter = 11 then begin
      counter := 1;
      total_bandwidth := 
      (if !!max_hard_upload_rate = 0 then 10000 * 1024
        else (maxi (!!max_hard_upload_rate - 1) 1) * 1024 );
      complete_bandwidth := !total_bandwidth;
      if !verbose_upload then begin
          lprintf "Init to %d\n" !total_bandwidth; 
        end;
      remaining_bandwidth := 0          
    end;
  
  let last_sec = ref 0 in
  for i = 0 to 9 do
    last_sec := !last_sec + sent_bytes.(i)
  done;
  
  if !verbose_upload then begin
      lprintf "last sec: %d/%d (left %d)" !last_sec !total_bandwidth
        (!total_bandwidth - !last_sec);
      lprint_newline (); (*
      for i = 0 to 9 do
        lprintf "    last[%d] = %d\n" i  sent_bytes.(i)
      done; *)
      
    end;
  
  remaining_bandwidth := mini (mini (mini 
        (maxi (!remaining_bandwidth + !total_bandwidth / 10) 10000) 
      !total_bandwidth) !complete_bandwidth) 
  (!total_bandwidth - !last_sec);
  complete_bandwidth := !complete_bandwidth - !remaining_bandwidth;
  if !verbose_upload then begin
      lprintf "Remaining %d[%d]\n" !remaining_bandwidth !complete_bandwidth; 
    end;
  sent_bytes.(!counter-1) <- !remaining_bandwidth;
  if !remaining_bandwidth > 0 then 
    next_uploads ()

let reset_upload_timer () = ()
    
let reset_upload_timer _ =
  reset_upload_timer ()
  
let upload_credit_timer _ =
  if !has_upload = 0 then 
    (if !upload_credit < 300 then incr upload_credit)
  else
    decr has_upload
    
let ready_for_upload c =
  Fifo.put upload_clients c
    
let add_pending_slot c =
  if client_has_a_slot c then begin
      lprintf "Avoided inserting an uploader in pending slots!";
      lprint_newline ()
    end 
  else 
  if not (Intmap.mem (client_num c) !pending_slots_map) then
    begin
(* This is useless since it is the goal of the pending_slots_map 
        else if Fifo.mem pending_slots_fifo (client_num c) then begin
	lprintf "Avoided inserting a client twice in pending slots";
	lprint_newline ()
      end else *)
      pending_slots_map := Intmap.add (client_num c) c !pending_slots_map;
    end
    
let remove_pending_slot c =
  if Intmap.mem (client_num c) !pending_slots_map then
    pending_slots_map := Intmap.remove (client_num c) !pending_slots_map
    
let rec give_a_slot c =
  remove_pending_slot c;
  if not (client_is_connected c) then begin
      find_pending_slot ()
    end
  else begin
      set_client_has_a_slot c true;
      client_enter_upload_queue c
    end
    
and find_pending_slot () =
  try
    let rec iter () =
      let c = Intmap.top !pending_slots_map in
      give_a_slot c
    in
    iter ()
  with _ -> ()

let add_pending_slot c =
  let csh = client_upload c in
  let cdir = shared_dir csh in
  let cprio = ref (shared_prio csh) in
  (* if cdir <> "" then
    lprintf "Testing cdir %s\n" cdir; *)
  Intmap.iter (fun _ c -> 
    let sh = client_upload c in
    if shared_dir sh = cdir then decr cprio
  ) !CommonClient.uploaders;
  (* if cdir <> "" then
    lprintf "Testing cprio %d\n" !cprio; *)
  if !cprio > 0 then begin
    remove_pending_slot c;
    if client_is_connected c then begin
      set_client_has_a_slot c true;
      client_enter_upload_queue c
    end
  end else
    add_pending_slot c

let static_refill_upload_slots () =
  let len = Intmap.length !CommonClient.uploaders in
  if len < !!max_upload_slots then find_pending_slot ()

(* Since dynamic slots allocation is based on feedback, it should not 
 * allocate new slots too fast, since connections need some time to reach 
 * a stable state. 
 * To compensate for that slow pace, slots are allocated quadratically
 * as long as the link is not saturated. 
 *)

let not_saturated_count = ref 0
let allocation_cluster = ref 1
  
let dynamic_refill_upload_slots () =
  let reset_state () =
    not_saturated_count := 0;
    allocation_cluster := 1 in

  let open_slots n =
    let i = ref n in
    if !verbose_upload then begin
      lprintf "try to allocate %d more slots" n;
      lprint_newline ()
    end;
    while !i > 0 do
      find_pending_slot ();
      decr i
    done in

  let slot_bw = 3072 in
  let min_upload_slots = 3 in
(*  let estimated_capacity = !!max_hard_upload_rate * 1024 in *)
  let estimated_capacity = detected_uplink_capacity () in
  if !verbose_upload then begin
    lprintf "usage: %d(%d) capacity: %d "
      (short_delay_upload_usage ()) 
      (upload_usage ()) 
      estimated_capacity;
    lprint_newline ()
  end;
  let len = Intmap.length !CommonClient.uploaders in
  if len < !!max_upload_slots then begin

(* enough free bw for another slot *)
    if short_delay_upload_usage () + slot_bw < estimated_capacity then begin
      if !verbose_upload then begin
	lprintf "uplink not fully used";
	lprint_newline ()
      end;
      incr not_saturated_count
    end else reset_state ();
          
    if len < min_upload_slots then begin
      if !verbose_upload then begin
	lprintf "too few upload slots";
	lprint_newline ()
      end;
      open_slots (min_upload_slots - len);
      reset_state ()
    end else if !not_saturated_count >= 2 then begin
      open_slots (min !allocation_cluster (!!max_upload_slots - len));
      incr allocation_cluster
    end
  end

let turn = ref (-1)

let refill_upload_slots () =
  incr turn;
  if !turn = 5 then
    turn := 0;
  if !!dynamic_slots then begin
    if !turn = 0 then
      (* call every 5s *)
      dynamic_refill_upload_slots ()
  end else
    (* call every 1s *)
    static_refill_upload_slots ();

  if !turn = 0 then
    (* call every 5s *)
    update_upload_history ()


let consume_bandwidth len =
  remaining_bandwidth := !remaining_bandwidth - len

let remaining_bandwidth () = !remaining_bandwidth
  
  

(**********************************************************************


                     DOWNLOAD SCHEDULER


***********************************************************************)

let download_credit = ref 0 
let download_fifo = Fifo.create ()

    
let download_engine () =
  if not (Fifo.empty download_fifo) then begin
      let credit = !!max_hard_download_rate in
      let credit = 2 * (if credit = 0 then 10000 else credit) in
      download_credit := !download_credit + credit;
      let rec iter () =
        if !download_credit > 0 && not (Fifo.empty download_fifo) then  
          begin
            (try
                let (f, len) = Fifo.take download_fifo in
                download_credit := !download_credit - (len / 1000 + 1);
                f ()
              with _ -> ());
            iter ()
          end
      in
      iter ()
    end

let queue_download_request f len =  
  if !!max_hard_download_rate = 0 then 
    f ()
  else
    Fifo.put download_fifo (f,len)    

    (*
  (* timer started every 1/10 seconds *)
let download_timer () =
  *)


  (* timer started every 1/10 seconds *)
let upload_download_timer () =
  (try download_engine () 
    with e -> 
        lprintf "Exception %s in download_engine\n"  (Printexc2.to_string e)
  );
  (try next_uploads ()
  with e ->  lprintf "exc %s in upload\n" (Printexc2.to_string e))
              
  
  
  
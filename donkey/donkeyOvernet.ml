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

open Options

open BasicSocket
open TcpBufferedSocket
open LittleEndian

open GuiTypes
open CommonTypes
open CommonGlobals
open CommonInteractive
open CommonNetwork
open CommonOptions

open DonkeyTypes
open DonkeyGlobals
open DonkeyOptions
open DonkeyMftp
open DonkeyProtoOvernet
    
module PeerOption = struct
    
    let value_to_peer v = 
      match v with
        SmallList [md4; ip; port; kind]
      | List [md4; ip; port; kind] ->
          {
            peer_md4 = Md4.value_to_md4 md4; 
            peer_ip = Ip.value_to_ip ip; 
            peer_port = value_to_int port; 
            peer_kind = value_to_int kind; 
            peer_last_msg = last_time ();
          }
      | _ -> assert false
          
    let peer_to_value p = 
      SmallList [
        Md4.md4_to_value p.peer_md4; 
        Ip.ip_to_value p.peer_ip;
        int_to_value p.peer_port;
        int_to_value p.peer_kind]
      
    let t = define_option_class "Peer" value_to_peer peer_to_value      
      
  end
  
let overnet_port = 
  define_option downloads_ini ["overnet_port"] "port for overnet" 
    int_option (2000 + Random.int 20000)

let overnet_max_known_peers = 
  define_option downloads_ini ["overnet_max_known_peers"] 
  "maximal number of peers to keep for overnet boot" 
    int_option 2000

let overnet_search_keyword = 
  define_option downloads_ini ["overnet_search_keyword"] 
  "allow extended search to search on overnet" bool_option false

let overnet_search_sources = 
  define_option downloads_ini ["overnet_search_sources"] 
  "allow extended search to search on overnet" bool_option false

let overnet_max_connected_peers = 
  define_option downloads_ini ["overnet_max_connected_peers"] 
  "maximal number of peers mldonkey should connect at beginning" 
    int_option 50

let overnet_peers = define_option servers_ini 
    ["overnet_peers"] "List of overnet peers"
    (list_option PeerOption.t)
  []
      
let overnet_search_timeout = 
  define_option downloads_ini ["overnet_search_timeout"] 
  "How long shoud a search on Overnet wait for the last reply before terminating"
    float_option 120. 
      
let overnet_query_peer_period = 
  define_option downloads_ini ["overnet_query_peer_period"] 
  "Period between two queries in the overnet tree"
    float_option 10. 

      
let overnet_max_search_hits = 
  define_option downloads_ini ["overnet_max_search_hits"] 
  "Max number of hits in a search on Overnet"
    int_option 200 
      
let overnet_max_waiting_peers = 
  define_option downloads_ini ["overnet_max_waiting_peers"] 
  "Max number of peers waiting in a search on Overnet"
    int_option 50 

      
let gui_overnet_options_panel = 
  define_option downloads_ini ["gui_overnet_options_panel"]
  "Which options are configurable in the GUI option panel, and in the
  Overnet section. Last entry indicates the kind of widget used (B=Boolean,T=Text)"
    (list_option (tuple3_option (string_option, string_option, string_option)))
  [
    "Port", shortname overnet_port, "T";
    "Search for keywords", shortname overnet_search_keyword, "B";
    "Search for sources", shortname overnet_search_sources, "B";
    "Max Connected Peers", shortname overnet_max_connected_peers, "T";
    "Search Timeout", shortname overnet_search_timeout, "T";
    "Search Internal Period", shortname overnet_query_peer_period, "T";
    "Verbose", shortname verbose_overnet, "B";
    "Search Max Hits", shortname overnet_max_search_hits, "T";
    "Search Max Waiting Peers", shortname overnet_max_waiting_peers, "T";
  ]
  
  
let udp_sock = ref None  

let buf = Buffer.create 2000
  
let udp_send ip port msg =
  match !udp_sock with
    None -> ()
  | Some sock ->
      let addr = Unix.ADDR_INET (Ip.to_inet_addr ip, port) in
      try
        Buffer.clear buf;
        buf_int8 buf 227;
        DonkeyProtoOvernet.write buf msg;
        let s = Buffer.contents buf in
        if !!verbose_overnet then begin            
            Printf.printf "Sending UDP to %s:%d" (Ip.to_string ip) port;
            print_newline ();
            dump s;
            print_newline ();
          end;
        let len = String.length s in
        UdpSocket.write sock s 0 (String.length s) addr
      with e ->
          Printf.printf "Exception %s in udp_send" (Printexc.to_string e);
          print_newline () 
            
let (peers_queue : (Ip.t * int) Fifo.t) = Fifo.create ()
  
let peers_by_md4 = Hashtbl.create 1000

let search_hits = ref 0
let source_hits = ref 0
  
let add_peer peer =
  if not (Hashtbl.mem peers_by_md4 peer.peer_md4) then
    begin
      overnet_peers =:= peer :: !!overnet_peers;
      Hashtbl.add peers_by_md4 peer.peer_md4 peer;
      Fifo.put peers_queue (peer.peer_ip, peer.peer_port)
    end
    
let connected_peers = ref []
let nconnected_peers = ref 0

module XorSet = Set.Make (struct
      type t = Md4.t * peer
      let compare (m1,p1) (m2,p2) = 
        compare (m1,p1.peer_md4, p1.peer_ip) (m2,p2.peer_md4, p2.peer_ip)
    end)

type search_for =
  FileSearch of file
| KeywordSearch of local_search
  
type overnet_search = {
    mutable search_last_packet : float;
    search_md4 : Md4.t;
    search_kind : search_for;
    search_known_peers : (Ip.t * int, peer) Hashtbl.t;
    mutable search_next_peers : XorSet.t;
    mutable search_closed : bool;
    mutable search_waiting_peers : int;
  }
    
let overnet_searches = Hashtbl.create 13

let add_search_peer s p = 
  if not (Hashtbl.mem s.search_known_peers (p.peer_ip, p.peer_port)) then
    begin
      Hashtbl.add s.search_known_peers (p.peer_ip, p.peer_port) p;
      let distance = Md4.xor s.search_md4 p.peer_md4 in
      if s.search_waiting_peers > !!overnet_max_waiting_peers then begin
          let (dd,pp) as e = XorSet.max_elt s.search_next_peers in
          if dd>distance then begin
              s.search_next_peers <- XorSet.remove (dd, pp) s.search_next_peers;     
              s.search_next_peers <- XorSet.add (distance, p) s.search_next_peers;   
            end
            
        end
      else begin
          s.search_next_peers <- XorSet.add (distance, p) s.search_next_peers;
          s.search_waiting_peers <- s.search_waiting_peers +1        
         end
    end

    
let try_connect () =
  if (!!overnet_search_sources || !!overnet_search_keyword) &&
    !nconnected_peers < !!overnet_max_connected_peers && 
    not (Fifo.empty peers_queue) then begin
      let (ip, port) = Fifo.take peers_queue in
      udp_send ip port  (OvernetConnect (!!client_md4, Ip.null, 
          !!overnet_port, 0))
    end

let create_simple_search kind md4 =   
  let search = {
      search_last_packet = last_time ();
      search_md4 = md4;
      search_known_peers = Hashtbl.create 13;
      search_next_peers = XorSet.empty;
      search_kind = kind;
      search_closed = false;
      search_waiting_peers = 0;
    } in
(*   Printf.printf "STARTED SEARCH FOR %s" (Md4.to_string md4); print_newline (); *)
  Hashtbl.add overnet_searches md4 search;
  search

let create_search kind md4 =   
  let search = create_simple_search kind md4 in
  List.iter (fun (peer, _) ->
      add_search_peer search peer;
  ) !connected_peers
  
let recover_file (file : DonkeyTypes.file) = 
  if !!overnet_search_sources &&
    not (Hashtbl.mem overnet_searches file.file_md4) then
    create_search (FileSearch file) file.file_md4
        
let recover_all_files () =
  if !!overnet_search_sources then
    List.iter (fun file ->
        if file_state file = FileDownloading then
          recover_file file          
    ) !DonkeyGlobals.current_files
    
let udp_client_handler t p =
  match t with
  | OvernetConnectReply peers ->
      begin
        let peers = List.rev peers in
        match peers with
          peer :: tail ->
            add_peer peer;
            peer.peer_last_msg <- last_time ();
            connected_peers := (peer, last_time ()) :: !connected_peers;
            if !!verbose_overnet then begin                
                Printf.printf "Connected %d to %s:%d" !nconnected_peers(Ip.to_string peer.peer_ip)
                peer.peer_port; print_newline ();
              end;
            incr nconnected_peers;
            List.iter add_peer tail;
            Hashtbl.iter (fun _ search ->
                add_search_peer search peer) 
            overnet_searches;
            List.iter (fun file ->
                if file_state file = FileDownloading           
                    && !!overnet_search_sources &&
                  not (Hashtbl.mem overnet_searches file.file_md4) then
                  let search = create_simple_search 
                      (FileSearch file) file.file_md4 in
                  add_search_peer search peer;
            )  !DonkeyGlobals.current_files
        | _ -> ()
      end
  
  | OvernetSearchReply (md4, peers) ->
      begin
        try
          let s = Hashtbl.find overnet_searches md4 in
          begin
            try
              let (s_ip, s_port) as s_addr =
                match p.UdpSocket.addr with
                | Unix.ADDR_INET(ip, port) -> Ip.of_inet_addr ip, port
                | _ -> 
                    Printf.printf "NO SENDER"; print_newline ();
                    raise Not_found
              in
              let sender = Hashtbl.find s.search_known_peers s_addr in
              sender.peer_last_msg <- last_time ();
              udp_send s_ip s_port (OvernetGetSearchResults (md4,0,0,100));
              if !!verbose_overnet then begin
                  Printf.printf "DISTANCES: origin %s from %s" (Md4.to_string
                      (Md4.xor sender.peer_md4 md4))
                  (Md4.to_string sender.peer_md4)
                  ; print_newline ();
                end;
            with _ ->
                Printf.printf "Sender firewalled ?"; print_newline ();
          end;
          List.iter (fun p ->
              if !!verbose_overnet then begin
                  Printf.printf "DISTANCES: peer   %s from %s" (Md4.to_string
                      (Md4.xor p.peer_md4 md4))
                  (Md4.to_string p.peer_md4)
                  ; print_newline ();
                end;
              add_search_peer s p
          ) peers
        with _ ->
            Printf.printf "NO SUCH SEARCH ??"; print_newline ();
      end
  
  | OvernetSearchResult (md4, r_md4, r_tags) ->
      
      begin
        try
          let s = Hashtbl.find overnet_searches md4 in
          begin
            try
              begin
                try 
                  let (s_ip, s_port) as s_addr =
                    match p.UdpSocket.addr with
                    | Unix.ADDR_INET(ip, port) -> Ip.of_inet_addr ip, port
                    | _ -> 
                        Printf.printf "NO SENDER"; print_newline ();
                        raise Not_found
                  in                  
                  let sender = 
                    Hashtbl.find s.search_known_peers s_addr 
                  in
                  sender.peer_last_msg <- last_time ();
                  if !!verbose_overnet then begin
                      Printf.printf "REPLY FROM %s --> %s:%d" 
                        (Md4.to_string sender.peer_md4) (Ip.to_string s_ip) s_port;
                      print_newline ();
                    end;
                with _ -> 
                    Printf.printf "Sender firewalled ?"; print_newline ();
              end;
              match s.search_kind with
                FileSearch file ->
                  
                  List.iter (fun tag ->
                      if tag.tag_name = "loc" then begin
                          match tag.tag_value with
                            String bcp ->
                              if String2.starts_with bcp "bcp://" then
                                let bcp2 = String.sub bcp 6 (String.length bcp - 6) 
                                in
                                match String2.split_simplify bcp2 ':' with
                                | [_ ;ip;port]
                                | [ip;port] ->
                                    incr source_hits;
                                    let ip = Ip.of_string ip in
                                    let port = int_of_string port in
                                    if !!verbose_overnet then begin
                                        Printf.printf "Creating client %s:%d"
                                          (Ip.to_string ip) port;
                                        print_newline ();
                                      end;
                                    if Ip.valid ip then
                                    let c = new_client (Known_location (ip, port)) in
                                    if not (Intmap.mem (client_num c) file.file_sources) then
                                      new_source file c;
                                    
                                    DonkeyClient.add_interesting_client c 
                                | _ ->
                                    Printf.printf "Ill formed bcp: %s" bcp;
                                    print_newline ();
                              else begin
                                  Printf.printf "Not a bcp!!!"; print_newline ();
                                end
                          | _ -> 
                              Printf.printf "NOot a string location ??"; 
                              print_newline ();
                        end
                  ) r_tags;
              | KeywordSearch ss ->
                  incr search_hits;
                  DonkeyOneFile.search_found ss.search_search r_md4 r_tags;
                  if ss.search_search.search_nresults > 
                    !!overnet_max_search_hits then
                    s.search_closed <- true
            with _ -> 
                Printf.printf "No info on sender"; print_newline ();
          end;
          if !!verbose_overnet then begin
              Printf.printf "RESULT:"; print_newline ();
              print_tags r_tags; print_newline ();
            end;
        
        with _ ->
            Printf.printf "NO SUCH SEARCH ??"; print_newline ();
      end
      
      
  | _ -> 
      if !!verbose_overnet then begin
          Printf.printf "UNUSED MESSAGE"; print_newline ()
        end
    
let query_min_peer s =
  if not s.search_closed then
  try
    let (_,p) as e = XorSet.min_elt s.search_next_peers in
    if !!verbose_overnet then begin
        Printf.printf "Query New Peer"; print_newline ();
      end;
      s.search_next_peers <- XorSet.remove e s.search_next_peers;
      s.search_waiting_peers <- s.search_waiting_peers - 1;
    s.search_last_packet <- last_time ();
    udp_send p.peer_ip p.peer_port  (OvernetSearch (2, s.search_md4))     
  with _ -> ()
        
let query_next_peers () =
  Hashtbl2.safe_iter (fun s ->
      query_min_peer s;
      query_min_peer s;
      if s.search_last_packet +. !!overnet_search_timeout < last_time () then
        begin
          if !!verbose_overnet then begin              
              Printf.printf "Search for %s finished"
              (Md4.to_string s.search_md4);
              print_newline ();
            end;
          Hashtbl.remove overnet_searches s.search_md4
        end        
  ) overnet_searches

let remove_old_connected_peers () =
  let connected_peers = ref [] in
  List.iter (fun (peer, ctime) ->
      if ctime < last_time () -. 1200. then begin
          decr nconnected_peers;
          Fifo.put peers_queue (peer.peer_ip, peer.peer_port);
        end else begin
          connected_peers := (peer, ctime) :: !connected_peers
        end) !connected_peers
  

let purge_peer_list () =
  let list = Sort.list (fun p1 p2 ->
        p2.peer_last_msg > p1.peer_last_msg
    ) !!overnet_peers in
  let recent_peers, old = 
    List2.cut !!overnet_max_known_peers list
  in
  overnet_peers =:= recent_peers
  
let enable enabler = 

  let peers = !!overnet_peers in
  overnet_peers =:= [];
  List.iter add_peer peers;
  
  udp_sock := Some (UdpSocket.create (Ip.to_inet_addr !!donkey_bind_addr)
    (!!overnet_port) 
    (udp_handler udp_client_handler));
  add_session_timer enabler 1. try_connect;
  add_session_option_timer enabler overnet_query_peer_period query_next_peers;
  add_session_timer enabler 1200. (fun _ ->
      recover_all_files ();
      remove_old_connected_peers ();
      purge_peer_list ();
  )

let _ =
  option_hook overnet_query_peer_period (fun _ ->
      if !!overnet_query_peer_period < 5. then
        overnet_query_peer_period =:= 5.)
  
let disable () = 
  match !udp_sock with
    None -> ()
  | Some sock -> 
      udp_sock := None;
      UdpSocket.close sock "disabled";
      Hashtbl.clear peers_by_md4;
      Fifo.clear peers_queue

let parse_overnet_url url =
  match String2.split (String.escaped url) '|' with
  | "fha://" :: "boot" :: name :: port :: _
  | "boot" :: name :: port :: _ ->
      let ip = Ip.from_name name in
      let port = int_of_string port in
      Fifo.put peers_queue (ip, port);
      try_connect ();
      true
  | _ -> false
      
      
let _ =
  register_commands 
    [
    "boot", Arg_two (fun ip port o ->
        Fifo.put peers_queue (Ip.of_string ip, int_of_string port);
        try_connect ();
        "peer added"
    ), " <ip> <port> : add an Overnet peer";
    
    
    "ovlink", Arg_multiple (fun args o ->        
        let buf = o.conn_buf in
        let url = String2.unsplit args ' ' in
        if parse_overnet_url url then
          "download started"
        else "bad syntax"
    ), " <fhalink> : download fha:// link";
    
    "ovstats", Arg_none (fun o ->
        let buf = o.conn_buf in
        Printf.bprintf buf "Overnet statistics:\n"; 
        Printf.bprintf buf "  Connected Peers: %d\n" !nconnected_peers;
        List.iter (fun (p,_) ->
            Printf.bprintf buf "      %s:%d\n" (Ip.to_string p.peer_ip) 
            p.peer_port;
        ) !connected_peers;
        Printf.bprintf buf "  Search hits: %d\n" !search_hits;
        Printf.bprintf buf "  Source hits: %d\n" !source_hits;
        
        "";
    ), ": Overnet Stats";
    
    "ovweb", Arg_none (fun o ->
        load_url "ocl" "http://www.overnet2000.de/FHA/contact.ocl";
        "web boot started"
    ), ": download http://www.overnet2000.de/FHA/contact.ocl";
  ];
  add_web_kind "ocl" (fun filename ->
      let s = File.to_string filename in
      let s = String2.replace s '"' "" in
      let lines = String2.split_simplify s '\n' in
      List.iter (fun s ->
          match String2.split_simplify s ',' with
            name :: port :: _ ->
              let ip = Ip.from_name name in
              let port = int_of_string port in
              Fifo.put peers_queue (ip, port);
              try_connect ();              
          | _ -> 
              Printf.printf "BAD LINE ocl: %s" s;
              print_newline ();
      ) lines
  )


let search_keyword ss w =
  let key = Md4.string w in
  create_search (KeywordSearch ss) key
  
let overnet_search (s : local_search) =
  if !!overnet_search_keyword then
    let ss = s.search_search in
    let q = ss.search_query in
    let ws = keywords_of_query q in
    List.iter (fun w ->
        search_keyword s w;
    ) ws

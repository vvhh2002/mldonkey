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
(*
val search_found :
  DonkeyTypes.search -> 'a -> Md4.t -> Mftp.tag list -> unit
*)
val force_check_locations : unit -> unit
val search_handler :
  DonkeyTypes.local_search ->  DonkeyProtoServer.QueryReply.t -> unit
val reset_upload_timer : unit -> unit
val upload_timer : unit -> unit
val upload_credit_timer : unit -> unit
val udp_client_handler: DonkeyProtoServer.t -> UdpSocket.udp_packet -> unit 
val find_search : int -> DonkeyTypes.local_search
val make_xs : DonkeyTypes.local_search -> unit
  
val fill_clients_list : unit -> unit
val check_clients : unit -> unit
val remove_old_clients : unit -> unit
val new_friend : DonkeyTypes.client -> unit
val add_user_friend : DonkeyTypes.server -> DonkeyTypes.user -> unit
  
val browse_client : DonkeyTypes.client -> unit
(*
Original Code - Copyright (c) 2001 Anthony L Shipman
MLton Port Modifications - Copyright (c) Ray Racine

Permission is granted to anyone to use this version of the software
for any purpose, including commercial applications, and to alter it and
redistribute it freely, subject to the following restrictions:

    1. Redistributions in source code must retain the above copyright
    notice, this list of conditions, and the following disclaimer.

    2. The origin of this software must not be misrepresented; you must
    not claim that you wrote the original software. If you use this
    software in a product, an acknowledgment in the product documentation
    would be appreciated but is not required.

    3. If any files are modified, you must cause the modified files to
    carry prominent notices stating that you changed the files and the
    date of any change.

Disclaimer

    THIS SOFTWARE IS PROVIDED "AS IS" AND ANY EXPRESSED OR IMPLIED
    WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
    OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    DISCLAIMED. IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY DIRECT,
    INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
    (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
    SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
    HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
    STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
    IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.

Modification History
====================
Ray Racine 6/3/2005 - MLton Port and idiomatic fixups.
*)

(*  Copyright (c) 2001 Anthony L Shipman *)

(* $Id: http10.sml,v 1.37 2002/03/10 17:18:25 felix Exp $ *)

(*  This runs the HTTP v1.0 protocol over the socket.

@#34567890123456789012345678901234567890123456789012345678901234567890
*)

signature HTTP_1_0 =
sig

    val talk:	Connect.Conn -> unit

end


structure HTTP_1_0: HTTP_1_0 =
struct

    open Common

    structure Sy = SyncVar
    structure TF = TextFrag
    structure SS = Substring
    structure Status = HTTPStatus
    structure Hdr = HTTPHeader
    structure Req = HTTPMsg
    structure G   = Globals

    (*	This is the maximum number of bytes of a body entity that we will
     * keep in memory. *)
    val	body_limit = 10000
    val csmrList : Entity.consumer list = List.tabulate (Common.numConns, fn _ =>  CML.channel ())

    exception Bad of Status.Status
    exception EOF			(* got unexpected EOF on the connection *)

    fun talk conn =
    let val _ = ( Log.setLevel Log.Debug; Log.inform Log.Debug ( fn () => TF.str "Reading request/talking" ) )
	val req = MyProfile.timeIt "HTTP_1_0 get" get_request conn
    in
	if G.testing G.TestShowRequest
	then Req.dumpRequest req
	else ();

	MyProfile.timeIt "HTTP_1_0 to_store" (fn()=>to_store conn req) ()
    end
    handle Bad status => send_status conn status


    and get_request conn  : Req.Request =
    let
	val (method, url, protocol) = get_request_line conn
	val headers = get_all_headers conn
	val entity  = get_entity headers conn
    in
	Log.testInform G.TestShowRequest Log.Debug
	    (fn()=>TF.str "got a request");

	Req.Request {
	    method  = method,
	    url	    = url,
	    protocol= protocol,
	    headers = headers,
	    entity  = entity,

	    port    = Connect.getPort conn,
	    client  = Connect.getAddress conn,

	    rvar    = Sy.iVar(),
	    abort   = Connect.getAbort conn
	    }
    end


    (*	This raises Bad if the request line is not understandable.
    *)
    and get_request_line conn : (Req.Method * URL.URL * string) =
    let
	fun split line =
	(
	    Log.testInform G.TestShowRequest Log.Debug (fn()=>TF.str line);

	    case String.tokens Char.isSpace line of
	      [met, url, ver] =>
	    (
		(*  Konqueror always sends 1.1 *)
		if true orelse ver = "HTTP/1.0"
		then
		    parse met url ver
		else
		(
		    Log.error ["Bad Request Version: ", ver];
		    raise Bad Status.UnrecVersion
		)
	    )

	    | [met, url] => parse met url "HTTP/1.0"

	    | _ =>
	    (
		Log.error ["Bad Request: ", line];
		raise Bad Status.BadRequest
	    )
	)

	and parse met url ver =
	let
	    val method =    (* case sensitive *)
		    case met of
		      "GET"  => Req.GET
		    | "HEAD" => Req.HEAD
		    | "POST" => Req.POST
		    | _      =>
		    (
			Log.error ["Bad Request Method: ", met];
			raise Bad Status.BadRequest
		    )

	    val url = (URL.parseURL url)
			handle URL.BadURL msg =>
			(
			    Log.error ["Bad Request URL: ", msg];
			    raise Bad Status.BadRequest
			)
	in
	    (method, url, ver)
	end
    in
	case Connect.readLine conn of
	  NONE      => raise EOF
	| SOME line => split line
    end




    (*	This will raise Bad on a junk header.
    *)
    and get_all_headers conn : Hdr.Header list =
    let
	val headers = Hdr.readAllHeaders (fn () => Connect.readLine conn)

	(*  Raise our error condition on an unparsable header. *)
	fun check (Hdr.HdrBad h) =
	(
	    Log.error ["Bad Request Header: ", h];
	    raise Bad Status.BadRequest
	)
	|   check _ = ()

    in
	app check headers;
	headers
    end



    (*  Read the given number of lines from the connection.

	If the length is greater than the server's request limit then
	we reject it.

	If the length is greater than body_limit then we
	save it into a file.

	If the disk is full we will get an IO exception and
	return ServerFail.
    *)
    and get_entity headers conn : Entity.entity =
    let	val Config.ServerConfig { max_req_size, ... } = Config.getServerConfig ()
	val chunk_size = 8192

	fun read_file len =
	    let val _ = Log.testInform G.TestShowRequest Log.Debug
				       ( fn () => TF.concat [ "HTTP reading into file len=",
							      Int.toString len ] )
		val ( tmp_file, writer ) = create_body_file conn len
		val strm = BinIOWriter.get writer

		fun loop 0 = ()
		  |   loop n =
		      (
		       case Connect.read conn chunk_size of
			   NONE        => Log.log Log.Warn (TF.str "short body")
			 | SOME (s, _) =>
			   (
			    BinIO.output(strm, Byte.stringToBytes s);
			    loop ( n - ( size s ) )
			   )
		      )
	    in
		loop len;
		BinIOWriter.closeIt writer;
		Entity.tmpProducer tmp_file
	    end
	    handle x => (Log.logExn x; raise Bad Status.ServerFail)


	fun read_mem len =
	let
	    val _ = Log.testInform G.TestShowRequest Log.Debug
		(fn()=>TF.concat ["HTTP reading into mem len=",
		             Int.toString len])

	    val (frag, _) = Connect.readAll conn len
	in
	    Entity.textProducer frag
	end
	handle x => (Log.logExn x; raise Bad Status.ServerFail)


	(*  ReqTooLarge is v1.1 only but it's too good to avoid. *)
	fun check_req_limit len =
	    (
	     case max_req_size of
		 NONE   => ()
	       | SOME m => if len > m
			   then raise Bad Status.ReqTooLarge
			   else ()
	    )

	val einfo = Hdr.toEntityInfo headers
	val Info.Info { length, ... } = einfo
    in
	case length of
	    NONE   => Entity.None
	  | SOME n => let val n = Int64.toInt n
			  val () = check_req_limit n
			  val body = if n > body_limit
				     then read_file n
				     else read_mem n
		      in
			  Entity.Entity { info    = einfo,
					  body    = body }
		      end
    end

    (*	This builds a set of headers from the entity info. *)
    and from_entity_info einfo : Hdr.Header list =
    let
	val Info.Info {etype, encoding, length, last_mod} = einfo

	val h1 =
	    case etype of
	      NONE     => []
	    | SOME typ => [Hdr.HdrConType typ]

	val h2 =
	    case encoding of
	      NONE     => []
	    | SOME enc => [Hdr.HdrConEnc enc]

	val h3 =
	    case length of
	      NONE     => []
	    | SOME len => [ Hdr.HdrConLen ( Int64.toInt len ) ]

	val h4 =
	    case last_mod of
	      NONE     => []
	    | SOME lst => [Hdr.HdrLastModified lst]
    in
	List.concat [h1, h2, h3, h4]
    end



(*------------------------------------------------------------------------------*)

    (*	Create a temporary file using the port number of the connection
	as the name.  This returns a BinIO writer to write into the file.
	It will raise Bad if there is some error.

	If the open fails the error message has already been logged.
    *)

    and create_body_file conn len :(TmpFile.TmpFile * BinIOWriter.holder)=
    let
	val Config.ServerConfig {tmp_dir, ...} = Config.getServerConfig()
	val port  = Connect.getPort conn
	val abort = Connect.getAbort conn
    in
	case TmpFile.newBodyFile abort tmp_dir len port of
	  (* errors have already been logged *)
	  NONE => raise Bad Status.ServerFail

	| SOME tmp =>
	    (tmp, valOf(BinIOWriter.openIt abort (TmpFile.getName tmp)))
		handle x => raise Bad Status.ServerFail
    end

(*------------------------------------------------------------------------------*)

    (*	Here we pass a request to the store and return its response to
	the client.

	This runs in the thread that is handling the connection. It
	blocks awaiting the response from the store.

	If the connection is aborted e.g. due to a timeout then this
	returns doing nothing.

    *)

    and to_store conn req  =
    let
	val Req.Request {rvar, abort, ...} = req
    in
	Log.testInform G.TestStoreProto Log.Debug
	    (fn()=>TF.str "HTTP: sending to the store");

	Store.deliver req;

	(*  Get a response or do nothing if there is an abort condition.
	*)
	CML.select[
	    CML.wrap(Abort.evt abort, fn () => ()),

	    CML.wrap(Sy.iGetEvt rvar,
		    MyProfile.timeIt "HTTP_1_0 response"
			(handle_response conn req ))
	    ]
    end



    (*	If the method is HEAD then delete any body.
	A cooperative node will not have generated one.

	If the connection is broken we'll get some I/O exception. We force
	the abort condition to signal to any trailing producer.
    *)
    and handle_response conn req response  : unit =
    let	val Req.Request {method, abort, ...} = req
	val Req.Response {status, headers, entity} = response
    in
	Log.testInform G.TestShowResponse Log.Debug
	    (fn()=>TF.str "HTTP Protocol got a response");

	(
	    send_status  conn status;
	    send_headers conn headers;

	    MyProfile.timeIt "HTTP_1_0 stream_entity"
		(fn() => stream_entity abort conn (SOME entity)
			(method = Req.HEAD)
			(Status.needsBody status)
            )
		()
	)
	handle
	  Connect.Timeout => (Abort.force abort)
	| x => (Log.logExn x; Abort.force abort)
    end



    and send_status conn status =
    let
    in
	Log.testInform G.TestShowResponse Log.Debug
	    (fn()=>TF.concat ["Returning ", Status.formatStatus status]);

	Connect.write conn "HTTP/1.0 ";
	Connect.write conn (Status.formatStatus status);
	Connect.write conn "\r\n"
    end



    (*  Send the entity headers. *)
    and send_headers conn headers =
    let
	fun send hdr =
	    let
	    val h = Hdr.formatHeader hdr
	    val s = TF.toString ( TF.seq [ h, TF.nl ] )
	    in
		Log.testInform G.TestShowResponse Log.Debug
			       ( fn ()=> TF.concat [ "HTTP send hdr: ",		(* skip \r\n *)
						     String.substring ( s, 0, size s - 2 ) ] );

		Connect.write conn s
	    end
    in
	app send headers
    end


    (* This ends the header section. It provides a hook
     * for fudging the Connection header of HTTP/1.1. *)
    and end_headers conn =
	let
	in
	    Connect.write conn "Connection: close\r\n";
	    Connect.write conn "\r\n"		(* end the headers *)
	end

    (*	Stream an entity to the connection using the producer/consumer
     * interface. This will terminate the header section.

     * If the method is HEAD then we discard all the bytes of the
     * body. We should let the producer produce them in case it is
     * coming from a CGI script.  This empties the pipe and lets the
     * script terminate normally.  REVISIT - It would be nice to tell
     * other producers to not bother sending the body but HEAD requests
     * are probably rare.

     * REVISIT - We should be careful to erase the entity headers from
     * the response before sending these ones below. *)
    and stream_entity abort conn entity head_method needs_body  =
	let
        (*val _ = MLton.Thread.atomically (fn () =>
                    Common.currCh := ((!(Common.currCh) + 1) mod
                    Common.numConns))*)
        val curr = Abort.getCurr abort
        val csmr = List.nth (csmrList, curr)
	    fun receiver() =
		case CML.recv csmr  of
		    Entity.XferInfo info   => (send_info info; receiver())
		  | Entity.XferBytes bytes => ((*send_bytes bytes;*) receiver())
		  | Entity.XferDone        => ()
		  | Entity.XferAbort       => ()


	    (*  Send the entity headers. *)
	    and send_info info =
		let val hdrs = from_entity_info info
		in
		    send_headers conn hdrs;
		    end_headers conn
		end


	    and send_bytes bytes =
		(
		 if head_method
		 then
		     ()
		 else
		     Connect.write conn (Byte.bytesToString  bytes)
		)
	in
	    case entity of
		NONE => ( if needs_body			(* see RFC1945 7.2 *)
			  then Connect.write conn "Content-Length: 0\r\n"
			  else ();
			  end_headers conn
			)
	      | SOME Entity.None => ( if needs_body			(* see RFC1945 7.2 *)
				      then Connect.write conn "Content-Length: 0\r\n"
				      else ();
				      end_headers conn
				    )

	      | _ => let val pthread = Entity.startProducer abort entity csmr
		     (* val _  = TraceCML.watch("producer", pthread) *)
		     in
			 (*	Don't skip the join. The producer must be allowed to
			  * clean up a CGI process nicely. *)
			 receiver() handle x => Log.logExn x;
			 CML.sync (CML.joinEvt pthread)  (* wait for producer to stop *)
		     end
	end

end
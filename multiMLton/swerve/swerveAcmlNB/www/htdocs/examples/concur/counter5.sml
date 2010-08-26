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

(*  Copyright (c) 2001 Anthony L Shipman *)


signature COUNTER =
sig
    type Counter

    val new:	int -> Counter 
    val incr:	Counter -> int -> unit
    val get:	Counter -> int
    val getEvt:	Counter -> int MLton.PCML.event

end



structure Counter: COUNTER =
struct

    datatype Request = 
	    ReqIsIncr of int
	|   ReqIsGet of int MLton.PCML.SyncVar.ivar

    and Counter = Counter of {
    		    req_chan:	Request MLton.PCML.chan
		    }


    fun delay n = MLton.PCML.sync (CML.timeOutEvt (Time.fromSeconds n))


    fun new init =
    let
	val req_chan = MLton.PCML.channel()

	fun counter() =
	let
	    fun loop count =
	    (
		case MLton.PCML.recv req_chan of
		  ReqIsIncr n => loop (count + n)

		| ReqIsGet rpl_var => 
		(
		    (* delay 2; *)
		    MLton.PCML.SyncVar.iPut(rpl_var, count);
		    loop count
		)
	    )
	in
	    loop init
	end

	val thread = MLton.PCML.spawn counter
    in
	Counter
	{
	    req_chan = req_chan
	}
    end


    fun incr (Counter {req_chan, ...}) n =
    (
	MLton.PCML.send(req_chan, ReqIsIncr n)
    )


    fun getEvt (Counter {req_chan, ...}) =
    let
	fun send() =
	let
	    val rpl_var = MLton.PCML.SyncVar.iVar()

	    fun sender() = MLton.PCML.send(req_chan, ReqIsGet rpl_var)
	in
	    MLton.PCML.spawn sender;
	    MLton.PCML.SyncVar.iGetEvt rpl_var
	end
    in
	MLton.PCML.guard send
    end

    fun get counter = MLton.PCML.sync(getEvt counter)

end






structure Main =
struct
    fun toErr msg = TextIO.output(TextIO.stdErr, msg)


    fun run() =
    let
	val obj = Counter.new 0

	fun time_out t = MLton.PCML.wrap(
			    MLton.PCML.timeOutEvt(Time.fromSeconds t),
			    fn () => ~1)
    in
	Counter.incr obj 3;
	Counter.incr obj ~1;

	let
	    val c = MLton.PCML.select [Counter.getEvt obj, time_out 1]
	in
	    print(concat["The counter's value is ",
	    	         Int.toString c, "\n"])
	end
    end



    fun main(arg0, argv) =
    let
    in
	MLton.RunPCML.doit(run, NONE);
        OS.Process.success
    end
    handle
      x =>
    (
	toErr(concat["Uncaught exception: ", exnMessage x, " from\n"]);
	app (fn s => (print "\t"; print s; print "\n")) (SMLofNJ.exnHistory x);
	OS.Process.failure
    )

    val _ = SMLofNJ.exportFn("counter5", main)
end



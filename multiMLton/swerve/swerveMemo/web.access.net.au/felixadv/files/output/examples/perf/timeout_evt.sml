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


(*  This experiments with delivering time-out events using an Ivar.
    The goal is to have one manager thread that does the timing. It
    broadcasts an event to all timed-out threads.

*)

structure Main =
struct
    fun toErr msg = TextIO.output(TextIO.stdErr, msg)


    (*	The number of thousands of threads to spawn. *)
    val M = 1

    fun toTime n = Time.fromSeconds(LargeInt.fromInt n)

(*===================================================================*)


    fun thread n evt () =
    let
	fun report() = print(concat["Thread ", Int.toString n,
			" finishes at ",
			Time.fmt 6 (Time.now()), "\n"])
    in
	CML.sync(CML.wrap(evt, report))
    end
    handle x => toErr(concat["Uncaught exception: ", exnMessage x,
    			     " from thread ", Int.toString n, "\n"])



    (*	This models the behaviour of the web server which creates a time-out
	event and then spawns a thread to wait for it.
    *)
    fun spawner evt 0 = ()
    |   spawner evt n =
    let
	val name = concat["Thread ", Int.toString n]
    in
	Timing.timeIt name (fn() => ignore(CML.spawn (thread n evt)));
	spawner evt (n-1)
    end


    fun run arg () =
    let
	val evt = 
	    case arg of
	      "time" => CML.atTimeEvt(Time.+(Time.now(), toTime(M * 5)))
	    | _      => CML.timeOutEvt(toTime(M * 5))
    in
	spawner evt (M * 1000);
	Timing.report()
    end



    fun main(arg0, argv) =
    let
	val arg = if null argv then "" else hd argv
    in
	RunCML.doit(run arg, NONE);
        OS.Process.success
    end
    handle
      x =>
    (
	toErr(concat["Uncaught exception: ", exnMessage x, " from\n"]);
	app (fn s => (print "\t"; print s; print "\n")) (SMLofNJ.exnHistory x);
	OS.Process.failure
    )

    val _ = SMLofNJ.exportFn("timeout_evt", main)
end


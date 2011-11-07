structure Main : MAIN =
struct

  open Critical

  structure S = Scheduler
  structure SQ = SchedulerQueues
  structure SH = SchedulerHooks
  structure TO = Timeout
  structure TID = ThreadID
  structure MT = MLtonThread
  structure PT = ProtoThread

  structure Assert = LocalAssert(val assert = false)
  structure Debug = LocalDebug(val debug = true)

  fun debug msg = Debug.sayDebug ([atomicMsg, TID.tidMsg], msg)
  fun debug' msg = debug (fn () => msg()^" : "^Int.toString(PacmlFFI.processorNumber()))



  (* Enabling preemption for processor 0
   * For other processors, preemprtion is enabled when they are scheduled
   *)
  val _ = PacmlFFI.enablePreemption ()

  (* Dummy signal handler *)
  (* Since signals are handled by a separate pthread, the working threads are
  * not interrupted and thus failing to interrupt the syscalls that could be
  * restarted. Hence, the signal handler thread sends SIGUSR2 to each worker
  * thread, which corresponds to this handler *)

  val h = MLtonSignal.Handler.handler (fn t => t)

  fun closureReceiver () =
  let
    val myProcId = PacmlFFI.processorNumber ()

    fun phase1 () =
    let
      val sender = PacmlFFI.readIntentArray (PacmlFFI.SEND_INTENT, myProcId)
    in
      if sender <> ~1 then
        (debug' (fn () => "closureReceiver: moving to phase2");
        phase2 (sender))
      else
        (Thread.yield (); phase1 ())
    end

    and phase2 (sender) =
    let
      val res = PacmlFFI.writeIntentArray (PacmlFFI.RECV_INTENT,
                                           sender, ~1, myProcId)
    in
      if res = ~1 then
        (debug' (fn () => "closureReceiver: moving to phase3");
        phase3 (sender))
      else
        (Thread.yield (); phase2 sender)
    end

    and phase3 (sender) =
    let
      val rhost : RepTypes.runnable_host = !(MLtonRcce.recv sender)
      val _ = S.readyForSpawn (rhost)
      val res = PacmlFFI.writeIntentArray (PacmlFFI.SEND_INTENT, myProcId, sender, ~1)
      val _ = if res <> sender then (print "FAIL\n"; raise Fail "closureReceiver.phase3.write1") else ()
      val res = PacmlFFI.writeIntentArray (PacmlFFI.RECV_INTENT, sender, myProcId, ~1)
      val _ = if res <> myProcId then (print "FAIL\n"; raise Fail "closureReceiver.phase3.write2") else ()
    in
      (debug' (fn () => "closureReceiver: back to phase1");
      phase1 ())
    end
  in
    phase1 ()
  end

  fun spawnClosureReceiver () =
    if Primitive.Controls.directCloXfer then
      (ignore (Thread.spawnOnProc (closureReceiver, PacmlFFI.processorNumber ()));
      (* Closure receiver will run forever. Hence, we will decrement num
      * live threads so that it does not hinder program termination. *)
      ignore (Config.decrementNumLiveThreads ()))
    else ()


  fun thread_main () =
  let
    val _ = MLtonProfile.init ()
    val _ = PacmlFFI.disablePreemption ()
    val _ = MLtonSignal.setHandler (Posix.Signal.usr2, h)

    fun wait () =
      if !Config.isRunning then
        ()
      else
        (PacmlFFI.maybeWaitForGC ();
         PacmlFFI.wait ();
         wait ())

    val _ = wait ()

    fun loop procNum =
    let
      val _ = spawnClosureReceiver ()
      val _ = PacmlFFI.maybeWaitForGC ()
    in
      case doAtomic (fn () => SQ.dequeHost (RepTypes.PRI)) of
           NONE => (PacmlFFI.wait (); loop procNum)
         | SOME (t) =>
             let
               val _ = if !Config.isRunning then ()
                       else (loop procNum)
               val _ = atomicBegin ()
               val _ = PacmlFFI.enablePreemption ()
             in
               S.atomicSwitch (fn _ => t)
             end
    end
  in
    loop (PacmlFFI.processorNumber ())
  end

  val () = (_export "Parallel_run": (unit -> unit) -> unit;) thread_main

  fun alrmHandler thrd =
    let
      val () = Assert.assertAtomic' ("RunCML.alrmHandler", SOME 1)
      val () = debug' (fn () => "alrmHandler(1)") (* Atomic 1 *)
      val () = S.preempt thrd
      val () = TO.preemptTime ()
      val _ = TO.preempt ()
      val nextThrd = S.next()
      val () = debug' (fn () => "alrmHandler(2)")
    in
      nextThrd
    end

  fun pause () =
  let
    fun tightLoop2 n =
      if n=0 then ()
      else tightLoop2 (n-1)

    fun tightLoop n = (* tightLoop (1000) ~= 1ms on 1.8Ghz core *)
      if n=0 then ()
      else (tightLoop2 300; tightLoop (n-1))
  in
    tightLoop (Config.pauseToken)
  end


  fun pauseHook (iter, to) =
    let
      val to = if iter=0 then TO.preempt () else to
      val iter = case to of
                    NONE => if (iter > Config.maxIter) then (PacmlFFI.wait (); iter-1) else iter
                  | _ => if (iter > Config.maxIter) then (TO.preemptTime (); ignore (TO.preempt ()); 0) else iter
      val () = if not (!Config.isRunning) then (atomicEnd ();ignore (SchedulerHooks.deathTrap())) else ()
    in
      S.nextWithCounter (iter + 1, to)
    end

  fun reset running =
      (S.reset running
      ; SH.reset ()
      ; TID.reset ()
      ; TO.reset ())


  val numIOThreads = PacmlFFI.numIOProcessors

  fun shutdown status =
    if (!Config.isRunning)
      then S.switch (fn _ => PT.getRunnableHost(PT.prepVal (!SH.shutdownHook, status)))
      else raise Fail "CML is not running"

  fun runtimeInit () =
  let
    val () = PacmlPrim.initRefUpdate (S.preemptOnWriteBarrier)
    (* init MUST come after waitForWorkLoop has been exported *)
    val () = Primitive.MLton.parallelInit ()
    (* Install handler for processor 0*)
    val _ = MLtonSignal.setHandler (Posix.Signal.usr2, h)
  in
    ()
  end


  fun run (initialProc : unit -> unit) =
  let
    (* DO NOT REMOVE *)
    val _ = runtimeInit ()
    val installAlrmHandler = fn (h) => MLtonSignal.setHandler (Posix.Signal.alrm, h)
    val status =
        S.switchToNext
        (fn thrd =>
        let
          fun lateInit () =
          let
            val () = Config.isRunning := true
            val () = debug' (fn () => "lateInit")
            val () = spawnClosureReceiver ()
            (* Spawn the Non-blocking worker threads *)
            val _ = List.tabulate (numIOThreads * 5, fn _ => NonBlocking.mkNBThread ())
            val _ = List.tabulate (numIOThreads, fn i => PacmlFFI.wakeUp (PacmlFFI.numComputeProcessors + i, 1))
          in
            ()
          end
          val () = debug' (fn () => concat ["numberOfProcessors = ", Int.toString (PacmlFFI.numberOfProcessors)])
          val () = debug' (fn () => concat ["numComputeProcessors = ", Int.toString (PacmlFFI.numComputeProcessors)])
          val () = debug' (fn () => concat ["numIOProcessors = ", Int.toString (PacmlFFI.numIOProcessors)])
          val () = reset true
          val handler = MLtonSignal.Handler.handler (S.unwrap alrmHandler Thread.reifyHostFromParasite)
          val () = installAlrmHandler handler
          val () = debug' (fn () => "Main(-2)")
          val () = SH.shutdownHook := PT.prepend (thrd, fn arg => (atomicBegin (); arg))
          val () = debug' (fn () => "Main(-1)")
          val () = SH.pauseHook := pauseHook
          val () = debug' (fn () => "Main(0)")
          val () = ignore (Thread.spawn (fn ()=> (lateInit (); initialProc ())))
        in
            ()
        end)
      val () = reset false
      val () = Config.isRunning := false
      val () = atomicEnd ()
    in
      status
    end

end

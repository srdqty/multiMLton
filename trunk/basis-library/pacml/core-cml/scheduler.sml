structure Scheduler : SCHEDULER =
struct

  structure Assert = LocalAssert(val assert = false)
  structure Debug = LocalDebug(val debug = false)

  open Critical

  structure SQ = SchedulerQueues
  structure TID = ThreadID
  structure GlobalDebug = Debug
  structure MT = MLtonThread
  structure PT = ProtoThread
  structure R = RepTypes
  structure SH = SchedulerHooks

  fun debug msg = Debug.sayDebug ([atomicMsg, TID.tidMsg], msg)
  fun debug' msg = debug (fn () => msg^" : "^Int.toString(PacmlFFI.processorNumber()))
  fun debug'' msg = print (msg^" : "^Int.toString(PacmlFFI.processorNumber())^"\n")

  datatype thread_type = datatype RepTypes.thread_type
  datatype thread = datatype RepTypes.thread
  datatype rdy_thread = datatype RepTypes.rdy_thread
  type parasite = RepTypes.parasite
  datatype runnable_host = datatype RepTypes.runnable_host

  fun enque1 thrd =
   (Assert.assertAtomic' ("Scheduler.enque1", NONE)
    ; SQ.enque (thrd, R.PRI))

  fun enque2 thrd =
   (Assert.assertAtomic' ("Scheduler.enque2", NONE)
    ; SQ.enque (thrd, R.SEC))

  fun deque1 () =
   (Assert.assertAtomic' ("Scheduler.deque1", NONE)
    ; SQ.deque (R.ANY))

  fun deque2 () =
   (Assert.assertAtomic' ("Scheduler.deque2", NONE)
   ; SQ.deque (R.SEC))

  fun promote () =
   (Assert.assertAtomic' ("Scheduler.promote", NONE)
   ; case deque2 () of
          NONE => ()
        | SOME t => enque1 t)

  fun atomicReady (rt : rdy_thread) =
    (Assert.assertAtomic' ("Scheduler.atomicReady(1)[tid:"^(TID.tidMsg())^"]", SOME 1)
    ; case rt of
      H_RTHRD (rhost) => (SQ.enque (rhost, R.PRI); atomicEnd ())
    | P_RTHRD (par) => PT.atomicPrefixAndSwitchTo (par) (* Implicit atomic end *)
    ; Assert.assertNonAtomic (fn () => "Scheduler.atomicReady(2)[tid:"^(TID.tidMsg())^"]"))

  fun ready (rt : rdy_thread) =
    (atomicBegin ();
     atomicReady (rt))

  fun reset running =
      (if running then debug' "Scheduler.reset true"
        else  debug' "Scheduler.reset false"
      ; SQ.clean ())

  fun readyForSpawn (t : runnable_host) =
    (ignore (Config.incrementNumLiveThreads ())
    ; enque1 t)



  fun unwrap (f : runnable_host -> runnable_host) (reify : parasite -> runnable_host) (host: MT.Runnable.t) : MT.Runnable.t =
    let
      val () = debug' "Scheduler.unwrap"
      val () = Assert.assertAtomic' ("Scheduler.unwrap", NONE)
      val thrdType = PT.getThreadType ()
      val pBottom = PT.getParasiteBottom ()
      val primHost = MT.toPrimitive host
      val host = MT.fromPrimitive primHost
      val host' = case thrdType of
                    PARASITE => if ((not (PT.proceedToExtractParasite (primHost, pBottom))) orelse (pBottom=0) orelse (not (PT.toPreemptParasite ()))) then
                                  let
                                    val _ = debug' "Scheduler.unwrap.PARASITE(1)"
                                    val tid = TID.getCurThreadId ()
                                    val RHOST (tid', host') = f (RHOST (tid, host))
                                    val () = TID.setCurThreadId tid'
                                  in
                                    host'
                                  end
                                else
                                  let
                                    val _ = debug' "Scheduler.unwrap.PARASITE(2)"
                                    val host' = MT.toPrimitive host
                                    val thlet = PT.extractParasiteFromHost (host', pBottom)
                                    val newHost = reify (thlet)
                                    val _ = readyForSpawn newHost
                                    val host'' = MT.fromPrimitive host'
                                  in
                                    host''
                                  end
                  | HOST =>
                      let
                        val _ = debug' "Scheduler.unwrap.HOST"
                        val tid = TID.getCurThreadId ()
                        val RHOST (tid', host') = f (RHOST (tid, host))
                        val () = TID.setCurThreadId tid'
                      in
                        host'
                      end
    in
      host'
    end

  fun nextWithCounter iter =
    if SQ.empty () then
      (!SH.pauseHook(iter))
    else
      (let
        val () = Assert.assertAtomic' ("Scheduler.nextWithCounter", NONE)
        val thrd =
            case deque1 () of
              NONE =>  !SH.pauseHook (iter)
            | SOME thrd => thrd
      in
        thrd
      end)

  fun next () = nextWithCounter 0

  (* what to do at a preemption (with the current thread) *)
  fun preempt (thrd as RHOST (tid, _)) =
      let
        val () = Assert.assertAtomic' ("Scheduler.preempt", NONE)
        val () =
          if TID.isMarked tid
          then (TID.unmark tid
                ; promote ()
                ; SQ.enque (thrd, R.PRI))
          else SQ.enque (thrd,R.SEC)
      in
        ()
      end

  fun atomicSwitchAux msg (f : 'a thread -> runnable_host) : 'a =
    (Assert.assertAtomic (fn () => "Scheduler."^msg, NONE);
    case PT.getThreadType () of
         HOST =>
           MT.atomicSwitch (fn t =>
           let
             val tid = TID.getCurThreadId ()
             val _ = TID.mark tid
             val RHOST (tid', t') = f (H_THRD(tid, t))
             val _ = TID.setCurThreadId tid'
           in
             t'
           end)
       | PARASITE =>
           let
             val r : (unit -> 'a) ref = ref (fn () => raise Fail "atomicSwithc : Switching to a unprepared thread")
             fun dummyFrame () =
             let
               val tid = TID.getCurThreadId ()
               val _ = TID.mark tid
               val parasite = PT.copyParasite (PT.getParasiteBottom())
               val thrd = P_THRD (parasite, fn x => r := x)
               val rt = f (thrd)
               val () = Assert.assert' ("atomicSwitchAux : state corrupted. Unintended inflation??",
                                        fn () => case PT.getThreadType () of
                                                      HOST => false
                                                    | _ => true)
               val _ = SQ.enque (rt, R.PRI) (* ready the given thread *)
               val _ = PT.disableParasitePreemption ()
               val _ = PT.jumpDown (PT.getParasiteBottom ()) (* Implicit atomic end *)
             in
               print "Should not see this\n"
             end
             val _ = Primitive.dontInline (dummyFrame)
             val _ = (atomicBegin (); atomicEnd ())
           in
             !r()
           end)

  fun atomicSwitch (f) = atomicSwitchAux "atomicSwitch" f

  fun atomicSwitchToNext (f : 'a thread -> unit) =
    case PT.getThreadType () of
         HOST => atomicSwitchAux "atomicSwitchToNext" (fn thrd => (f thrd; next ()))
       | PARASITE =>
           let
             val r : (unit -> 'a) ref = ref (fn () => raise Fail "atomicSwitchToNext : Switching to a unprepared thread")
             val _ = debug' ("Scheduler.atomicSwitchToNext on "^(PT.getThreadTypeString ()))
             fun dummyFrame () =
             let
               val tid = TID.getCurThreadId ()
               val _ = TID.mark tid
               val parasite = PT.copyParasite (PT.getParasiteBottom())
               val thrd = P_THRD (parasite, fn x => r := x)
               val () = f (thrd)
               val () = Assert.assert' ("atomicSwitchToNext : state corrupted. Unintended inflation??",
                                        fn () => case PT.getThreadType () of
                                                      HOST => false
                                                    | _ => true)
               val _ = PT.disableParasitePreemption ()
               val _ = PT.jumpDown (PT.getParasiteBottom ()) (* Implicit atomic end *)
             in
               print "Should not see this\n"
             end
             val _ = Primitive.dontInline (dummyFrame)
             val _ = (atomicBegin (); atomicEnd ())
           in
             !r()
           end

  fun switchToNext (f : 'a thread -> unit) = (atomicBegin (); atomicSwitchToNext (f))

end
/* Copyright (C) 1999-2008 Henry Cejtin, Matthew Fluet, Suresh
 *    Jagannathan, and Stephen Weeks.
 * Copyright (C) 1997-2000 NEC Research Institute.
 *
 * MLton is released under a BSD-style license.
 * See the file MLton-LICENSE for details.
 */

void MLton_RCCE_send (GC_state s, pointer p, int dest) {
  assert (isPointer (p));

  if (DEBUG_RCCE)
    fprintf (stderr, "MLton_RCCE_send p="FMTPTR" dest=%d\n",
             (uintptr_t)p, dest);

  int me = Proc_processorNumber (s);
  assert (me != dest && me < s->numberOfProcs);
  me++; //dummy to eliminate gcc warning

  size_t size = GC_size (s, p);
  objptr op = pointerToObjptr (p, s->heap->start);
  void* buffer = malloc_safe (size);
  s->forwardState.toStart = s->forwardState.back = buffer;
  s->forwardState.toLimit = (pointer)((char*)buffer + size);

  ENTER_LOCAL0 (s);
  copyObjptr (s, &op);
  foreachObjptrInRange (s, s->forwardState.toStart, &s->forwardState.back, copyObjptr, TRUE);
  LEAVE_LOCAL0 (s);

  MLton_RCCE_sendRecvControlPacket cp;
  cp.objectClosureSize = size;
  cp.toSpaceStart = (pointer) buffer;
  if (DEBUG_RCCE)
    fprintf (stderr, "MLton_RCCE_send: sending control packet to %d\n", dest);
  RCCE_send ((char*)&cp, sizeof (MLton_RCCE_sendRecvControlPacket), dest);
  if (DEBUG_RCCE)
    fprintf (stderr, "MLton_RCCE_send: sending object closure of size %zu to %d\n",
             size, dest);
  RCCE_send ((char*)buffer, size, dest);
  if (DEBUG_RCCE)
    fprintf (stderr, "MLton_RCCE_send: send object closure to %d\n", dest);

  free (buffer);
}

pointer MLton_RCCE_recv (GC_state s, int src) {
  if (DEBUG_RCCE)
    fprintf (stderr, "MLton_RCCE_send src=%d\n", src);
  MLton_RCCE_sendRecvControlPacket cp;
  if (DEBUG_RCCE)
    fprintf (stderr, "MLton_RCCE_recv: waiting for control packet from %d\n", src);
  RCCE_recv ((char*)&cp, sizeof (MLton_RCCE_sendRecvControlPacket), src);

  void* buffer = malloc_safe (cp.objectClosureSize);
  if (DEBUG_RCCE)
    fprintf (stderr, "MLton_RCCE_recv: waiting for object closure of size %zu from %d\n",
             cp.objectClosureSize, src);
  RCCE_recv ((char*)buffer, cp.objectClosureSize, src);
  if (DEBUG_RCCE)
    fprintf (stderr, "MLton_RCCE_recv: received object closure from %d\n", src);

  ENTER_LOCAL0 (s);
  ensureHasHeapBytesFreeAndOrInvariantForMutator (s, FALSE, TRUE, FALSE, 0,
                                                  cp.objectClosureSize, FALSE, 0);
  GC_memcpy (buffer, s->frontier, cp.objectClosureSize);
  assert (s->frontier + cp.objectClosureSize < s->limit);
  pointer to = s->frontier;
  s->frontier += cp.objectClosureSize;
  translateRange (s, cp.toSpaceStart, to, cp.objectClosureSize);
  LEAVE_LOCAL0 (s);
  free (buffer);
  pointer result = advanceToObjectData (s, to);
  if (DEBUG_RCCE)
    fprintf (stderr, "MLton_RCCE_recv: returning object "FMTPTR"\n", (uintptr_t)result);
  return result;
}
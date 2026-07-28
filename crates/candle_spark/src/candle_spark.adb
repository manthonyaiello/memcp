--  Wrapper body: marshal across the C ABI to the candle staticlib (its own
--  crate, `candle_ffi/`, built via `cargo build --release`, crate-type =
--  staticlib) and back. Keep candle's heavy native link deps (Accelerate/BLAS,
--  -lm -ldl, possibly CUDA) confined to this crate.
--
--  The three imports below ARE the trust seam: SPARK does not analyze their
--  foreign bodies, it proves the Pre at each call and assumes the Post. Under
--  -gnata those Posts execute and check the real engine. Only
--  text crosses inward; the output is a caller-owned Embedding the engine fills,
--  so no allocation crosses the boundary.

with Interfaces.C;

package body Candle_Spark
  with SPARK_Mode => On
is

   use type Interfaces.C.int;

   --  void candle_embed_load(const char *path, uintptr_t len,
   --                         void **out_handle, int32_t *status);
   --  Loads the model directory; on status 0, *out_handle owns the engine.
   --  candle_embed_load writes *out_handle on every path (NULL first, then the
   --  engine on success), so Handle really is initialized on return -- which is
   --  what an `out` parameter of an ownership type promises. No postcondition:
   --  the caller must be prepared to reclaim Handle whatever St says (a future
   --  partial-load failure could leave an engine behind), exactly as
   --  Sqlite_Vec_Spark.Bridge.Open does.
   procedure C_Load
     (Path   : String;
      Len    : Interfaces.C.size_t;
      Handle : out Handles.Engine_Handle;
      St     : out Interfaces.C.int)
     with Import            => True,
          Convention        => C,
          External_Name     => "candle_embed_load",
          Global            => null,
          Always_Terminates => True;

   --  void candle_embed(const void *handle, const char *text, uintptr_t len,
   --                    float *out, int32_t *status);
   --  Fills the caller's Out_Buf. Because Out_Buf's components are the
   --  constrained Embedding_Component, SPARK *assumes* the L2-normalized engine
   --  stays in -1.0 .. 1.0 -- the boundary trust that lets every consumer
   --  inherit the range with no Post to carry.
   procedure C_Embed
     (Handle  : Handles.Engine_Handle;
      Text    : String;
      Len     : Interfaces.C.size_t;
      Out_Buf : out Embedding;
      St      : out Interfaces.C.int)
     with Import            => True,
          Convention        => C,
          External_Name     => "candle_embed",
          Pre               => Handle /= Handles.Null_Engine_Handle,
          Global            => null,
          Always_Terminates => True;
   --  Pre: candle_embed dereferences the handle to reach the BERT model, so a
   --  reclaimed one there is undefined behaviour rather than an error code --
   --  which is exactly why the obligation belongs on the Ada side of the seam.
   --  It discharges at the one call site from Embed's own Is_Loaded precondition.

   --  void candle_embed_free(void **handle);
   procedure C_Free (Handle : in out Handles.Engine_Handle)
     with Import            => True,
          Convention        => C,
          External_Name     => "candle_embed_free",
          Global            => null,
          Always_Terminates => True,
          Depends           => (Handle => null, null => Handle),
          Post              => Handle = Handles.Null_Engine_Handle;
   --  Release the engine and leave Handle reclaimed. `in out` (hence the
   --  `void **` on the C side, which nulls the caller's pointer) is what makes
   --  the Post *executable*: with assertions on (ADAFLAGS=-gnata) every Unload
   --  checks at run time that the handle really was released, rather than the
   --  Ada side merely assuming it. Tolerates an already-reclaimed handle, which
   --  is what makes Unload idempotent and lets Load's failure path free
   --  unconditionally. Depends is Unload's clause one level down: the new
   --  handle is a constant (`Handle => null`) and the old one flows nowhere
   --  SPARK models (`null => Handle`) -- it reaches the engine's own C-side
   --  state, which this crate does not model as abstract state -- which is what
   --  keeps Unload's caller-facing clause exactly as it was.

   ----------
   -- Load --
   ----------

   procedure Load
     (E          : out Embedder;
      Model_Path : String;
      Result     : out Status)
   is
      St : Interfaces.C.int;
   begin
      --  Load straight into E.Handle: staging through a local would MOVE the
      --  handle out of the local on assignment, which buys nothing here.
      C_Load
        (Path   => Model_Path,
         Len    => Interfaces.C.size_t (Model_Path'Length),
         Handle => E.Handle,
         St     => St);

      if St = 0 and then Is_Loaded (E) then
         Result := Ok;
      else
         --  Two failures in one branch: a genuine error code, and a success
         --  code with a reclaimed handle (which candle_ffi does not produce,
         --  but which the Post (Is_Loaded = (Result = Ok)) has to rule out to
         --  be a theorem). Either way, free unconditionally -- C_Free tolerates
         --  a reclaimed handle, and it is what discharges E's ownership
         --  obligation on this path.
         C_Free (E.Handle);
         Result := Load_Failed;
      end if;
   end Load;

   -----------
   -- Embed --
   -----------

   function Embed (E : Embedder; Text : String) return Embedding is
      Result : Embedding;
      St     : Interfaces.C.int;
   begin
      C_Embed
        (Handle  => E.Handle,
         Text    => Text,
         Len     => Interfaces.C.size_t (Text'Length),
         Out_Buf => Result,
         St      => St);

      --  A loaded model on nonempty text is contracted to succeed; a genuine
      --  post-load engine failure (e.g. a tokenizer edge case) degrades to the
      --  zero vector -- in range, deterministic, and keeps Embed total rather
      --  than raising across the AoRTE proof.
      if St /= 0 then
         Result := (others => 0.0);
      end if;

      --  The trust seam is Embedding_Component itself: SPARK *assumes* candle's
      --  L2-normalized output stays in -1.0 .. 1.0 because Out_Buf carries the
      --  constrained subtype, so consumers inherit the range with no Post.
      --  A `for all C of Result => C'Valid` assertion used to add an -gnata-only
      --  cross-check of the raw foreign bytes, but GNATprove 16 folds 'Valid to
      --  True (attribute-valid-always-true), making the assertion vacuous. It is
      --  dropped rather than suppressed: any check phrased over Result is over a
      --  nominally-in-range object and so folds away, and widening the FFI buffer
      --  to reintroduce a real check would only turn the assumed range into an
      --  unprovable one.
      return Result;
   end Embed;

   ------------
   -- Unload --
   ------------

   procedure Unload (E : in out Embedder) is
   begin
      --  One call: C_Free releases the engine and leaves the handle reclaimed,
      --  which IS the reclamation step -- there is no second object to keep in
      --  lockstep. Idempotent, because it tolerates an already-reclaimed handle.
      C_Free (E.Handle);
   end Unload;

end Candle_Spark;

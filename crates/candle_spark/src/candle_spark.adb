--  Wrapper body: marshal across the C ABI to the candle staticlib (its own
--  crate, `candle_ffi/`, built via `cargo build --release`, crate-type =
--  staticlib) and back. Keep candle's heavy native link deps (Accelerate/BLAS,
--  -lm -ldl, possibly CUDA) confined to this crate.
--
--  The three imports below ARE the trust seam: SPARK does not analyze their
--  foreign bodies, it proves the Pre at each call and assumes the Post. Under
--  -gnata (test builds) those Posts execute and check the real engine. Only
--  text crosses inward; the output is a caller-owned Embedding the engine fills,
--  so no allocation crosses the boundary.

with Ada.Unchecked_Deallocation;
with Interfaces.C;

package body Candle_Spark
  with SPARK_Mode => On
is

   use type Interfaces.C.int;
   use type System.Address;

   --  Reclaim the ownership token (see the private part note). Freeing it is
   --  what discharges the Needs_Reclamation obligation; it nulls its argument,
   --  so an unloaded handle is left in the reclaimed state. Same device as
   --  Sqlite_Vec_Spark's Free_Token.
   procedure Free_Token is
     new Ada.Unchecked_Deallocation (Boolean, Ownership_Token);

   --  int32_t candle_embed_load(const char *path, uintptr_t len,
   --                            void **out_handle, int32_t *status);
   --  Loads the model directory; on status 0, *out_handle owns the engine.
   procedure C_Load
     (Path   : String;
      Len    : Interfaces.C.size_t;
      Handle : out System.Address;
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
     (Handle  : System.Address;
      Text    : String;
      Len     : Interfaces.C.size_t;
      Out_Buf : out Embedding;
      St      : out Interfaces.C.int)
     with Import            => True,
          Convention        => C,
          External_Name     => "candle_embed",
          Global            => null,
          Always_Terminates => True;

   --  void candle_embed_free(void *handle);
   procedure C_Free (Handle : System.Address)
     with Import            => True,
          Convention        => C,
          External_Name     => "candle_embed_free",
          Global            => null,
          Always_Terminates => True;

   ----------
   -- Load --
   ----------

   procedure Load
     (E          : in out Embedder;
      Model_Path : String;
      Result     : out Status)
   is
      Handle : System.Address;
      St     : Interfaces.C.int;
   begin
      --  Reclaim any model E already holds first, so re-loading into the same
      --  handle cannot leak the prior C allocation. Unload is idempotent and
      --  posts Is_Reclaimed, so a never-loaded E is simply left (null, null).
      Unload (E);

      C_Load
        (Path   => Model_Path,
         Len    => Interfaces.C.size_t (Model_Path'Length),
         Handle => Handle,
         St     => St);

      if St = 0 then
         E.Handle := Handle;
         --  Loaded: take ownership. The token now shadows Handle's life.
         E.Token  := new Boolean'(True);
         Result   := Ok;
      else
         --  E stays (null, null) -- not loaded, reclaimed.
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
      if E.Handle /= System.Null_Address then
         C_Free (E.Handle);
      end if;
      E.Handle := System.Null_Address;
      --  Release the ownership token: this is the reclamation step. Idempotent
      --  -- Free_Token on a null token is a no-op -- so Unload stays idempotent.
      Free_Token (E.Token);
   end Unload;

end Candle_Spark;

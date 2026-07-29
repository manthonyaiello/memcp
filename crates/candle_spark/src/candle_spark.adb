--  Proven-SPARK wrappers over the candle staticlib built from `candle_ffi/`.
--  Candle's heavy native link dependencies (Accelerate/BLAS, -lm -ldl, possibly
--  CUDA) stay confined to this crate.

with Interfaces.C;

package body Candle_Spark
  with SPARK_Mode => On
is

   use type Interfaces.C.int;

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
   --  Load the model directory: `void candle_embed_load (const char *path,
   --  uintptr_t len, void **out_handle, int32_t *status)`. Writes Handle on
   --  every path -- NULL first, the engine on success -- which is what an `out`
   --  parameter of an ownership type promises. No postcondition: the caller must
   --  be prepared to reclaim Handle whatever St says.
   --  @param Path Model directory, passed as Len bytes with no NUL.
   --  @param Len Byte length of Path.
   --  @param Handle The engine handle: owning on success, reclaimed otherwise.
   --  @param St Zero on success.

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
   --  Fill Out_Buf with the embedding of Text: `void candle_embed (const void
   --  *handle, const char *text, uintptr_t len, float *out, int32_t *status)`.
   --  Out_Buf's components are the constrained Embedding_Component, so the
   --  L2-normalized range is assumed of the engine here, at the seam. The Pre is
   --  a real obligation, not a formality: candle_embed dereferences the handle,
   --  so a reclaimed one is undefined behaviour rather than an error code.
   --  @param Handle A loaded engine handle.
   --  @param Text The text to embed, passed as Len bytes with no NUL.
   --  @param Len Byte length of Text.
   --  @param Out_Buf The embedding the engine fills.
   --  @param St Zero on success.

   procedure C_Free (Handle : in out Handles.Engine_Handle)
     with Import            => True,
          Convention        => C,
          External_Name     => "candle_embed_free",
          Global            => null,
          Always_Terminates => True,
          Depends           => (Handle => null, null => Handle),
          Post              => Handle = Handles.Null_Engine_Handle;
   --  Release the engine and leave Handle reclaimed: `void candle_embed_free
   --  (void **handle)`. The `void **` is why Handle is `in out` -- C nulls the
   --  caller's pointer, which makes the Post executable under -gnata. Tolerates
   --  an already-reclaimed handle, so Unload is idempotent and Load's failure
   --  path can free unconditionally.
   --  @param Handle The engine handle, left reclaimed.

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
      --  Load straight into E.Handle: staging through a local would move the
      --  handle on assignment, buying nothing.
      C_Load
        (Path   => Model_Path,
         Len    => Interfaces.C.size_t (Model_Path'Length),
         Handle => E.Handle,
         St     => St);

      if St = 0 and then Is_Loaded (E) then
         Result := Ok;
      else
         --  Two failures in one branch: an error code, and a success code with
         --  a reclaimed handle, which candle_ffi does not produce but the Post
         --  must rule out. Either way free unconditionally, which discharges E's
         --  ownership obligation on this path.
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

      --  A post-load engine failure (a tokenizer edge case, say) degrades to the
      --  zero vector: in range, deterministic, and keeps Embed total.
      if St /= 0 then
         Result := (others => 0.0);
      end if;

      return Result;
   end Embed;

   ------------
   -- Unload --
   ------------

   procedure Unload (E : in out Embedder) is
   begin
      C_Free (E.Handle);
   end Unload;

end Candle_Spark;

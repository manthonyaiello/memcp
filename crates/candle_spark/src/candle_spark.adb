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

with Interfaces.C;

package body Candle_Spark
  with SPARK_Mode => On
is

   use type Interfaces.C.int;

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
   --  stays in -1.0 .. 1.0 -- the boundary trust. The wrapper turns that
   --  assumption into a runtime check (see Embed) so -gnata still catches a
   --  misbehaving engine.
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
     (E          : out Embedder;
      Model_Path : String;
      Result     : out Status)
   is
      Handle : System.Address;
      St     : Interfaces.C.int;
   begin
      C_Load
        (Path   => Model_Path,
         Len    => Interfaces.C.size_t (Model_Path'Length),
         Handle => Handle,
         St     => St);

      if St = 0 then
         E      := (Handle => Handle, Loaded => True);
         Result := Ok;
      else
         E      := (Handle => System.Null_Address, Loaded => False);
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

      --  Embedding_Component makes SPARK *assume* the engine stayed in range;
      --  this turns the assumption into a real check of the foreign output under
      --  -gnata, keeping the "trust in proof, verify under assertions" boundary
      --  discipline the old range Post gave us -- now without a contract for the
      --  type's consumers to carry. 'Valid (not a membership test, which the
      --  compiler would fold to True since Result's components are nominally
      --  in-range already) is the tool that actually inspects unchecked foreign
      --  data at runtime; GNATprove necessarily assumes it, hence the suppress.
      pragma Warnings
        (GNATprove, Off, "attribute Valid is assumed to return True",
         Reason => "-gnata makes this a real range check of candle's output");
      pragma Assert (for all C of Result => C'Valid);
      pragma Warnings
        (GNATprove, On, "attribute Valid is assumed to return True");

      return Result;
   end Embed;

   ------------
   -- Unload --
   ------------

   procedure Unload (E : in out Embedder) is
   begin
      if E.Loaded then
         C_Free (E.Handle);
      end if;
      E := (Handle => System.Null_Address, Loaded => False);
   end Unload;

end Candle_Spark;

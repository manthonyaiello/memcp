--  candle_spark: SPARK binding to a native embedding engine (candle +
--  the Rust `tokenizers` crate), running all-MiniLM-L6-v2.
--
--  Replaces memcp's sentence-transformers seam (src/memcp/embed.py). The Python
--  side already keeps "no numpy/torch leakage at the seam" and hands back a
--  plain list[float] -- that list is exactly `Embedding` below, and this
--  package is that seam in Ada.
--
--  Shape of the binding (decided 2026-07-13):
--
--    * Handle, not free function. The model is genuinely global, loadable
--      state that can fail to load, so it lives behind an opaque `Embedder`
--      (mirrors Python's `Embedder` object and `Sqlite_Vec_Spark.Database`).
--      `Load` is the one fallible step; `Embed` is total once loaded.
--    * Caller allocates. The output is a fixed `Dimension` floats, so `Embed`
--      hands the foreign body a buffer to fill -- there is no malloc/free
--      ownership dance across the FFI (unlike `Spark_Mcp.Http`). Text only ever
--      crosses inward.
--    * Invariant in the type. `Embedding_Component` is a 32-bit IEEE float
--      (the width candle returns and sqlite-vec stores as packed
--      float[Dimension] -- not Standard.Float, which need not be 32-bit)
--      constrained to -1.0 .. 1.0, the L2-normalization range. Carrying both in
--      the subtype means `Embed` needs no range Post and consumers inherit it.
--
--  SPARK_Mode is On: the wrapper is proven, and only the foreign inference body
--  is trusted. The Pre/Post here are the boundary contract -- SPARK proves the
--  Pre at call sites and assumes the Post; a test build with assertions enabled
--  (-gnata) executes the Post to check the real engine honours it.

with Interfaces;
with System;

package Candle_Spark
  with SPARK_Mode => On
is

   use type Interfaces.IEEE_Float_32;  --  operators for the range bounds below

   Dimension : constant := 384;
   --  Matches store.py EMBEDDING_DIM (all-MiniLM-L6-v2 is 384-dimensional).

   subtype Embedding_Component is
     Interfaces.IEEE_Float_32 range -1.0 .. 1.0;
   --  A single component of an embedding vector. Two properties are baked into
   --  the type rather than restated as contracts:
   --    * width -- IEEE_Float_32 is the f32 candle returns and sqlite-vec stores
   --      as a packed float[Dimension] blob, fixed by the peers on both sides of
   --      this crate (do not assume Standard.Float is 32 bits);
   --    * range -- candle L2-normalizes, so every component lands in -1.0 .. 1.0.
   --      Carrying that in the subtype means Embed needs no range Post, and every
   --      consumer (the Store, the vec0 blob) inherits the invariant for free.

   type Embedding is array (1 .. Dimension) of Embedding_Component;
   --  A full embedding vector: Dimension components in declaration order.

   type Status is (Ok, Load_Failed);
   --  How a Load attempt ended. Post-load per-call engine failures do not
   --  surface here (Embed is total by design); see the body.
   --  @enum Ok The model loaded successfully.
   --  @enum Load_Failed The weights were missing or malformed; the returned
   --    Embedder is not loaded.

   type Embedder is private;
   --  Opaque model handle. Wraps the foreign engine allocation; copyable value
   --  carrying a raw pointer plus the loaded flag consumers query.

   function Is_Loaded (E : Embedder) return Boolean;
   --  Whether E holds a successfully loaded model and may be passed to Embed.
   --  @param E The embedder handle to query.
   --  @return True if E is loaded, False otherwise.

   procedure Load
     (E          : out Embedder;
      Model_Path : String;
      Result     : out Status)
     with Pre  => Model_Path'Length > 0,
          Post => (Is_Loaded (E) = (Result = Ok));
   --  Load all-MiniLM-L6-v2 from a pre-provisioned model directory (weights +
   --  tokenizer + config; see scripts/install-model.sh). This is the one
   --  fallible step -- weights may be missing or malformed. On Ok the returned
   --  Embedder Is_Loaded; otherwise it is not and must not be passed to Embed.
   --  @param E The embedder handle set by the load attempt.
   --  @param Model_Path Directory holding the model weights, tokenizer, config.
   --  @param Result Ok if the model loaded; Load_Failed otherwise.

   function Embed (E : Embedder; Text : String) return Embedding
     with Pre => Is_Loaded (E) and then Text'Length > 0;
   --  Embed one text. Mirrors Embedder.embed(text) -> list[float].
   --
   --  Total once loaded: the foreign body mean-pools and L2-normalizes, so the
   --  result satisfies Embedding_Component by construction -- the type carries
   --  the range, so there is no Post to restate it. A genuine post-load engine
   --  failure degrades to the zero vector (in range, safe) -- see the body --
   --  rather than raising, keeping Embed AoRTE-total.
   --  @param E A loaded embedder handle.
   --  @param Text The text to embed; must be non-empty.
   --  @return The embedding vector for Text.

   procedure Unload (E : in out Embedder)
     with Post => not Is_Loaded (E);
   --  Release the foreign allocation. Idempotent; leaves E not-loaded.
   --  @param E The embedder handle to release.

   --  TODO(embed): batch variant mirroring Embedder.embed_batch, used by
   --  upload_session to embed all turns of a transcript in one call. Stays
   --  caller-allocates: the caller knows N, so it passes an N * Dimension out
   --  buffer -- still no ownership dance. Signature designed, deferred per
   --  roadmap (single Embed unblocks the Store; replay tests inject vectors).

private

   type Embedder is record
      Handle : System.Address := System.Null_Address;
      --  Raw pointer to the foreign engine allocation; Null_Address when unloaded.
      Loaded : Boolean        := False;
      --  Whether Handle refers to a live, loaded model.
   end record;
   --  Concrete representation of the opaque Embedder handle.

   function Is_Loaded (E : Embedder) return Boolean is (E.Loaded);
   --  Whether E holds a successfully loaded model and may be passed to Embed.
   --  @param E The embedder handle to query.
   --  @return True if E is loaded, False otherwise.

end Candle_Spark;

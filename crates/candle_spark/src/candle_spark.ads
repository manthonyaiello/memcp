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

   --  Opaque model handle over the foreign engine allocation. Limited: it owns
   --  a C resource (the candle EmbedModel that candle_embed_free reclaims), so
   --  it must not be copied -- a copy would alias one native model behind two
   --  Ada values, the double-free / use-after-free hazard that ownership
   --  tracking rules out. This mirrors Sqlite_Vec_Spark.Database/Statement.
   --
   --  Needs_Reclamation: a loaded model owns a C allocation that Unload must
   --  release. The full view anchors that ownership on a small Ada access
   --  "token" (allocated when the C load succeeds, freed by Unload), because
   --  the raw engine pointer -- a bare System.Address -- is not subject to
   --  SPARK ownership on its own. GNATprove then proves, at every call site,
   --  that a loaded Embedder is Unloaded before it is dropped.
   type Embedder is limited private
     with Annotate => (GNATprove, Ownership, "Needs_Reclamation"),
          Default_Initial_Condition =>
            not Is_Loaded (Embedder) and then Is_Reclaimed (Embedder);

   function Is_Loaded (E : Embedder) return Boolean;
   --  Whether E holds a successfully loaded model and may be passed to Embed.
   --  @param E The embedder handle to query.
   --  @return True if E is loaded, False otherwise.

   function Is_Reclaimed (E : Embedder) return Boolean
     with Ghost, Annotate => (GNATprove, Ownership, "Is_Reclaimed");
   --  Reclamation predicate for the Needs_Reclamation annotation above. An
   --  unloaded embedder holds no C allocation and no token, so that is the
   --  reclaimed state GNATprove requires before the object is dropped. Ghost:
   --  it exists only for proof, never at run time.
   --  @param E The embedder handle to test.
   --  @return True iff E owns no model (equivalently, not Is_Loaded (E)).

   procedure Load
     (E          : in out Embedder;
      Model_Path : String;
      Result     : out Status)
     with Pre  => Model_Path'Length > 0,
          Post => (Is_Loaded (E) = (Result = Ok))
                  and then (Is_Reclaimed (E) = (Result /= Ok));
   --  Load all-MiniLM-L6-v2 from a pre-provisioned model directory (weights +
   --  tokenizer + config; see scripts/install-model.sh). This is the one
   --  fallible step -- weights may be missing or malformed. On Ok the returned
   --  Embedder Is_Loaded; otherwise it is not and must not be passed to Embed.
   --  E is `in out`: Load reclaims any model E already holds before loading, so
   --  callers may re-load into the same handle without a manual Unload and
   --  without leaking the prior C allocation (a never-loaded E is left as is).
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
     with Post    => not Is_Loaded (E) and then Is_Reclaimed (E),
          Depends => (E => null, null => E);
   --  Release the foreign allocation. Idempotent; leaves E not-loaded.
   --  Depends: E's new value is a constant (null handle/token) and its old
   --  handle reaches C only as a System.Address (flowing nowhere in SPARK), so
   --  a caller that never reads E afterwards needs no "set but not used"
   --  suppression. (Unload has no global effect SPARK can see, so a call whose
   --  reclaiming write is then overwritten still reads as "no effect" -- that is
   --  a separate flow fact this clause does not address.)
   --  @param E The embedder handle to release.

   --  TODO(embed): batch variant mirroring Embedder.embed_batch, used by
   --  upload_session to embed all turns of a transcript in one call. Stays
   --  caller-allocates: the caller knows N, so it passes an N * Dimension out
   --  buffer -- still no ownership dance. Signature designed, deferred per
   --  roadmap (single Embed unblocks the Store; replay tests inject vectors).

private

   --  Hide the representation from clients' proof context: an Ownership type
   --  requires its private part to be either SPARK_Mode (Off) or hidden, and
   --  hiding keeps the wrapper body IN SPARK (unlike SPARK_Mode (Off), which
   --  would eject it). Clients reason about Embedder abstractly -- through
   --  Is_Loaded, the Needs_Reclamation obligation, and the operation contracts
   --  -- exactly as for Sqlite_Vec_Spark.Database and Memcp_Json.Doc.
   pragma Annotate (GNATprove, Hide_Info, "Private_Part");

   type Ownership_Token is access Boolean;
   --  The SPARK ownership anchor. The raw engine pointer is a bare
   --  System.Address, which SPARK does not track as an owned resource; so the
   --  full view carries, alongside the address, a one-Boolean heap allocation
   --  whose lifetime shadows the C handle's: allocated the instant the C load
   --  succeeds, freed the instant Unload releases the C handle. Because this
   --  component is a genuine Ada access, the enclosing record is "subject to
   --  ownership", which is what lets Needs_Reclamation apply. The Boolean
   --  payload is irrelevant -- only null vs non-null (reclaimed vs owned)
   --  matters. Same device as Sqlite_Vec_Spark's Ownership_Token.

   type Embedder is limited record
      Handle : System.Address  := System.Null_Address;
      --  Raw pointer to the foreign engine allocation; Null_Address when unloaded.
      Token  : Ownership_Token := null;
      --  Ownership anchor; non-null exactly while Handle names a loaded model
      --  (maintained in lockstep by Load/Unload).
   end record;
   --  Full view of the opaque Embedder handle. The raw C pointer (only
   --  null-comparison is ever used) plus the ownership token, default-
   --  initialized to (null, null) so a fresh handle is not-loaded, reclaimed,
   --  and an unloaded one stays that way.

   function Is_Loaded (E : Embedder) return Boolean is (E.Token /= null);
   --  A model is loaded iff it holds an ownership token. Token tracks the C
   --  handle's liveness (see Load/Unload), so this is equivalent to a non-null
   --  Handle while keeping the liveness and reclamation predicates on one field.
   --  @param E The embedder handle to query.
   --  @return True iff E holds an ownership token.

   function Is_Reclaimed (E : Embedder) return Boolean is (E.Token = null);
   --  Completion of the reclamation predicate: reclaimed exactly when the
   --  ownership token has been freed (equivalently, not Is_Loaded (E)).

end Candle_Spark;

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
--  Pre at call sites and assumes the Post; a build with assertions enabled
--  (-gnata) executes the Post to check the real engine honours it.

with Interfaces;

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
   --  release, and GNATprove proves at every call site that a loaded Embedder
   --  is Unloaded before it is dropped. The obligation rests on the engine
   --  pointer itself, which the private part models as a SPARK ownership type
   --  (see the note there) -- so "reclaimed" means the pointer was released,
   --  not that some parallel bookkeeping was updated.
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
   --  unloaded embedder holds no C allocation, so that is the reclaimed state
   --  GNATprove requires before the object is dropped. Ghost: it exists only
   --  for proof, never at run time.
   --  @param E The embedder handle to test.
   --  @return True iff E owns no model (equivalently, not Is_Loaded (E)).

   procedure Load
     (E          : out Embedder;
      Model_Path : String;
      Result     : out Status)
     with Pre  => Model_Path'Length > 0,
          Post => (Is_Loaded (E) = (Result = Ok))
                  and then (Is_Reclaimed (E) = (Result /= Ok));
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
     with Post    => not Is_Loaded (E) and then Is_Reclaimed (E),
          Depends => (E => null, null => E);
   --  Release the foreign allocation. Idempotent; leaves E not-loaded.
   --  Depends: E's new value is a constant (the reclaimed handle) and its old
   --  handle flows nowhere SPARK models -- it reaches the engine's own C-side
   --  state, which this crate does not model as abstract state -- so a caller
   --  that never reads E afterwards needs no "set but not used" suppression.
   --  This is exactly what the C_Free import's own `Handle => null` says, one
   --  level down. (Unload has no global effect SPARK can see, so a call whose
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
   --  -- exactly as for Sqlite_Vec_Spark.Database and Memcp.Json.Doc.
   pragma Annotate (GNATprove, Hide_Info, "Private_Part");

   --  The raw engine pointer, modelled as a SPARK *ownership type*.
   --
   --  This is where the crate's resource discipline is anchored. Engine_Handle
   --  is a private type whose full view is outside SPARK (the nested private
   --  part below is SPARK_Mode (Off)) carrying the Ownership annotation -- the
   --  shape SPARK's ownership annotations exist for, and the one the SPARK
   --  User's Guide uses for Text_IO.File_Descriptor and C_Strings.Chars_Ptr.
   --  Inside SPARK the handle then behaves like an owning access value:
   --  assigning it MOVES it, dropping or overwriting a non-reclaimed one is a
   --  leak GNATprove reports, and the only way to reach the reclaimed value is
   --  to call the release operation whose postcondition says so.
   --
   --  Why this rather than an access-to-Boolean "ownership token" beside the
   --  address (the shape this crate carried until now): the token was a second
   --  object whose lifetime had to shadow the C handle's, and *that* invariant
   --  -- free the token exactly when the C resource is released -- was true by
   --  review only, enforced nowhere. An Unload that freed the token and never
   --  called candle_embed_free proved clean, leaking the engine. Here the
   --  object SPARK tracks IS the pointer, so there is nothing to keep in
   --  lockstep. What remains is a single assumption of the form this crate
   --  already makes everywhere: that the C behind an import does what its
   --  contract says. It sits on C_Free's postcondition, and because
   --  candle_embed_free takes the handle by reference and nulls it, that
   --  assumption is *executable* rather than merely assumed: in a build with
   --  assertions on (ADAFLAGS=-gnata -- this crate's Alire profile is release,
   --  so they are off by default) every Unload checks at run time that the
   --  handle really was released. Verified non-vacuous by deleting the Rust
   --  side's `*handle = null` and watching that postcondition fail.
   --
   --  The type is deliberately NOT limited: Load and Unload reset a handle by
   --  assigning Null_Engine_Handle, which a limited type would forbid.
   --  Ada-level copying is blocked one level up -- Embedder is limited -- and
   --  inside SPARK a copy is a move, so the source is unusable afterwards.
   --
   --  The declaration pattern below -- Needs_Reclamation plus a
   --  Reclaimed_Value constant, Predefined_Equality restricted to that
   --  constant, and a ghost Is_Null tying the two together -- is lifted from
   --  SPARK.C.Strings.chars_ptr in the shipped SPARK library, which models
   --  exactly this situation (an owned C pointer), and matches
   --  Sqlite_Vec_Spark's Handles package. Two details are load-bearing:
   --
   --    * Predefined_Equality => "Only_Null" / "Null_Value". "=" on a hidden
   --      pointer is not a meaning SPARK can reason about in general (two
   --      handles are interchangeable in no useful sense), so the annotations
   --      license exactly the comparison this crate makes -- against the
   --      reclaimed value -- and reject any other.
   --
   --    * The Default_Initial_Condition goes through the ghost Is_Null rather
   --      than naming Null_Engine_Handle directly. It has to: a DIC that
   --      mentions a deferred constant freezes it at the type declaration,
   --      before its full declaration below, which is illegal ("full constant
   --      declaration appears too late") as soon as assertions are enabled.
   --      Routing through a function whose *postcondition* names the constant
   --      defers that freeze.
   package Handles is

      type Engine_Handle is private
        with Default_Initial_Condition => Is_Null (Engine_Handle),
             Annotate => (GNATprove, Ownership, "Needs_Reclamation"),
             Annotate => (GNATprove, Predefined_Equality, "Only_Null");
      --  The C `void *` from candle_embed_load. Owns the loaded engine (a
      --  boxed Rust EmbedModel) until candle_embed_free releases it.

      Null_Engine_Handle : constant Engine_Handle
        with Annotate => (GNATprove, Ownership, "Reclaimed_Value"),
             Annotate => (GNATprove, Predefined_Equality, "Null_Value");
      --  The reclaimed value: an Engine_Handle equal to this owns nothing, so
      --  GNATprove permits dropping or overwriting it. This annotation is what
      --  ties "the pointer is null" to "the engine has been released".

      function Is_Null (H : Engine_Handle) return Boolean
        with Ghost, Global => null,
             Post => Is_Null'Result = (H = Null_Engine_Handle);
      --  Ghost spelling of "reclaimed", for the Default_Initial_Condition
      --  above. Executable code uses the comparison directly.
      --  @param H The handle to test.
      --  @return True iff H is the reclaimed value.

   private
      pragma SPARK_Mode (Off);

      type Embed_Model is limited null record;
      --  Placeholder designated type for the boxed Rust EmbedModel. Never
      --  allocated or dereferenced on the Ada side -- every value comes from
      --  candle_ffi and goes back to it -- so the representation only has to
      --  give us a pointer that is null by default and comparable to null.

      type Engine_Handle is access all Embed_Model;
      --  Full view: a plain C pointer, and nothing else.

      Null_Engine_Handle : constant Engine_Handle := null;
      --  Full view of the reclaimed value: the null pointer.

      function Is_Null (H : Engine_Handle) return Boolean is (H = null);
      --  Completion of the ghost predicate.
      --  @param H The handle to test.
      --  @return True iff H is the null pointer.
   end Handles;

   use type Handles.Engine_Handle;
   --  For the null comparisons in the predicates below.

   type Embedder is limited record
      Handle : Handles.Engine_Handle;
      --  The owned engine pointer; Null_Engine_Handle (the default) when not
      --  loaded.
   end record;
   --  Full view of Embedder: the owning handle, and nothing beside it. The
   --  record survives only to keep Embedder limited (no Ada-level copy of a
   --  loaded model) and to leave room for future per-engine state; the
   --  ownership obligation Needs_Reclamation puts on Embedder is discharged
   --  through this component, whose own type carries it.

   function Is_Loaded (E : Embedder) return Boolean is
     (E.Handle /= Handles.Null_Engine_Handle);
   --  A model is loaded iff its handle is not the reclaimed value. Liveness and
   --  reclamation are now the same fact about the same object, rather than two
   --  facts about a pointer and a token.
   --  @param E The embedder handle to query.
   --  @return True iff E holds a loaded model.

   function Is_Reclaimed (E : Embedder) return Boolean is
     (E.Handle = Handles.Null_Engine_Handle);
   --  Completion of the reclamation predicate: reclaimed exactly when the
   --  handle is the reclaimed value (equivalently, not Is_Loaded (E)).
   --  @param E The embedder to test.
   --  @return True iff E owns no engine.

end Candle_Spark;

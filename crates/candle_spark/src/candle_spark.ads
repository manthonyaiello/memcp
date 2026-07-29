--  candle_spark: SPARK binding to a native embedding engine (candle plus the
--  Rust `tokenizers` crate), running all-MiniLM-L6-v2. Load is the one fallible
--  step; Embed is total once loaded. No allocation crosses the FFI, and text
--  only ever crosses inward.

with Interfaces;

package Candle_Spark
  with SPARK_Mode => On
is

   use type Interfaces.IEEE_Float_32;

   Dimension : constant := 384;
   --  Component count of an embedding; all-MiniLM-L6-v2 is 384-dimensional.

   subtype Embedding_Component is
     Interfaces.IEEE_Float_32 range -1.0 .. 1.0;
   --  A single component of an embedding vector. IEEE_Float_32 is the f32 the
   --  engine returns and a packed float[Dimension] blob stores; the bounds are
   --  the L2-normalization range, carried in the subtype so Embed needs no
   --  range Post.

   type Embedding is array (1 .. Dimension) of Embedding_Component;
   --  A full embedding vector: Dimension components in declaration order.

   type Status is (Ok, Load_Failed);
   --  How a Load attempt ended.
   --  @enum Ok The model loaded successfully.
   --  @enum Load_Failed The weights were missing or malformed; the returned
   --    Embedder is not loaded.

   type Embedder is limited private
     with Annotate => (GNATprove, Ownership, "Needs_Reclamation"),
          Default_Initial_Condition =>
            not Is_Loaded (Embedder) and then Is_Reclaimed (Embedder);
   --  Opaque embedding-model handle.

   function Is_Loaded (E : Embedder) return Boolean;
   --  Whether E holds a successfully loaded model and may be passed to Embed.
   --  @param E The embedder handle to query.
   --  @return True if E is loaded, False otherwise.

   function Is_Reclaimed (E : Embedder) return Boolean
     with Ghost, Annotate => (GNATprove, Ownership, "Is_Reclaimed");
   --  Reclamation predicate for Embedder: an unloaded embedder holds no C
   --  allocation.
   --  @param E The embedder handle to test.
   --  @return True iff E owns no model (equivalently, not Is_Loaded (E)).

   procedure Load
     (E          : out Embedder;
      Model_Path : String;
      Result     : out Status)
     with Pre  => Model_Path'Length > 0,
          Post => (Is_Loaded (E) = (Result = Ok))
                  and then (Is_Reclaimed (E) = (Result /= Ok));
   --  Load all-MiniLM-L6-v2 from a pre-provisioned model directory (weights,
   --  tokenizer and config; provisioned by this crate's
   --  scripts/install-model.sh). On Ok the Embedder Is_Loaded; otherwise it is
   --  not, and must not be passed to Embed.
   --  @param E The embedder handle set by the load attempt.
   --  @param Model_Path Directory holding the model weights, tokenizer, config.
   --  @param Result Ok if the model loaded; Load_Failed otherwise.

   function Embed (E : Embedder; Text : String) return Embedding
     with Pre => Is_Loaded (E) and then Text'Length > 0;
   --  Embed one text. Total once loaded: a post-load engine failure degrades to
   --  the zero vector rather than raising.
   --  @param E A loaded embedder handle.
   --  @param Text The text to embed; must be non-empty.
   --  @return The embedding vector for Text.

   procedure Unload (E : in out Embedder)
     with Post    => not Is_Loaded (E) and then Is_Reclaimed (E),
          --  E's old handle flows only to the engine's C-side state, which this
          --  crate does not model, so a caller that drops a released Embedder
          --  needs no "set but not used" suppression.
          Depends => (E => null, null => E);
   --  Release the foreign allocation. Idempotent; leaves E not-loaded.
   --  @param E The embedder handle to release.

   --  TODO(embed): batch variant, embedding every turn of a transcript in one
   --  call; still caller-allocates, since the caller knows the count.

private

   pragma Annotate (GNATprove, Hide_Info, "Private_Part");
   --  Required for GNATprove Ownership

   --  The raw engine pointer, an ownership type: this is where the crate's
   --  resource discipline is anchored. It is not limited, because Load and
   --  Unload reset a handle by assigning Null_Engine_Handle.
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
      --  GNATprove permits dropping or overwriting it.

      function Is_Null (H : Engine_Handle) return Boolean
        with Ghost, Global => null,
             Post => Is_Null'Result = (H = Null_Engine_Handle);
      --  Ghost spelling of "reclaimed", for the Default_Initial_Condition
      --  above; executable code compares directly.
      --  @param H The handle to test.
      --  @return True iff H is the reclaimed value.

   private
      pragma SPARK_Mode (Off);

      type Embed_Model is limited null record;
      --  Designated type for the boxed Rust EmbedModel. Never allocated or
      --  dereferenced on the Ada side: every value comes from candle_ffi and
      --  goes back to it, so all the representation owes us is a pointer
      --  comparable to null.

      type Engine_Handle is access all Embed_Model;
      --  The C void * from candle_embed_load, owned until freed; full view a
      --  plain C pointer.

      Null_Engine_Handle : constant Engine_Handle := null;
      --  The reclaimed Engine_Handle value: the null pointer.

      function Is_Null (H : Engine_Handle) return Boolean is (H = null);
      --  Completion of the Engine_Handle ghost predicate.
      --  @param H The handle to test.
      --  @return True iff H is the null pointer.
   end Handles;

   use type Handles.Engine_Handle;

   type Embedder is limited record
      Handle : Handles.Engine_Handle;
      --  The owned engine pointer; Null_Engine_Handle (the default) when not
      --  loaded.
   end record;
   --  Opaque embedding-model handle.

   function Is_Loaded (E : Embedder) return Boolean is
     (E.Handle /= Handles.Null_Engine_Handle);
   --  A model is loaded iff its handle is not the reclaimed value.
   --  @param E The embedder handle to query.
   --  @return True iff E holds a loaded model.

   function Is_Reclaimed (E : Embedder) return Boolean is
     (E.Handle = Handles.Null_Engine_Handle);
   --  Reclaimed exactly when the handle is the reclaimed value (equivalently,
   --  not Is_Loaded (E)).
   --  @param E The embedder to test.
   --  @return True iff E owns no engine.

end Candle_Spark;

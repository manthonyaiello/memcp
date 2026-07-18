--  The tool layer's JSON marshalling helper: the ONE json-touching unit besides
--  Memcp_Envelope. Inbound, it parses a tool's `arguments` object (raw JSON
--  text off the seam) and hands back typed fields; outbound, it renders scalars
--  as JSON text (strings escaped via the proved Spark_Mcp.Writer).
--
--  SPARK_Mode On: proved AoRTE + ownership/leak-freedom. The parse never raises
--  (bad or non-object JSON yields Valid => False); the json observers it walks
--  stay confined to the body (every getter returns a plain value, never an
--  access), so no JSON access type crosses this package's boundary. It stands
--  on proved units (json v7 Silver, Spark_Mcp.Writer Silver).

with Interfaces;

with Memcp_Store;

package Memcp_Json with SPARK_Mode => On is

   --  A parsed `arguments` object. Own it: Open parses (never raising -- bad or
   --  non-object JSON just yields Valid => False), Close frees. It owns a heap
   --  value tree, so it is an ownership type whose resource Close reclaims --
   --  the Needs_Reclamation annotation lets GNATprove see that a Closed Doc
   --  holds nothing (Is_Closed), which a bare wrapper Close cannot convey.
   type Doc is limited private
     with Annotate => (GNATprove, Ownership, "Needs_Reclamation"),
          Default_Initial_Condition => Is_Closed (Doc);

   function Is_Closed (D : Doc) return Boolean
     with Ghost, Annotate => (GNATprove, Ownership, "Is_Reclaimed");
   --  True when D holds no value tree: freshly declared, or after Close. An
   --  object of an ownership type must be reclaimed (Is_Closed) before it goes
   --  out of scope.
   --  @param D The document to test.
   --  @return True when D holds no value tree (reclaimed or never opened).

   procedure Open (D : out Doc; Text : String);
   --  Parse Text as a JSON object. Valid (D) is True only when Text is
   --  well-formed JSON whose top level is an object; the getters below assume
   --  that shape, so a tool checks Valid and reports Invalid_Params otherwise.
   --  @param D The document to populate; owns the parsed value tree on return.
   --  @param Text The raw JSON argument text to parse.

   procedure Close (D : in out Doc) with Post => Is_Closed (D);
   --  Reclaim D's value tree, leaving it closed.
   --  @param D The document to close; Is_Closed (D) holds afterwards.

   function Valid (D : Doc) return Boolean;
   --  True when D was opened from well-formed JSON whose top level is an object.
   --  @param D The document to test.
   --  @return True when the parse succeeded and the top level is an object.

   ---------------------
   -- Inbound getters --
   ---------------------

   function Has (D : Doc; Key : String) return Boolean;
   --  True when the object has a non-null member for Key (any type).
   --  @param D The parsed arguments object.
   --  @param Key The member name to look up.
   --  @return True when a non-null member named Key is present.

   function Get_Str
     (D : Doc; Key : String; Default : String := "") return String;
   --  The string member Key, or Default when absent / not a string.
   --  @param D The parsed arguments object.
   --  @param Key The member name to look up.
   --  @param Default The value returned when Key is absent or not a string.
   --  @return The string value of Key, or Default.

   function Has_Str (D : Doc; Key : String) return Boolean;
   --  True when Key is present and a string (used to distinguish an absent
   --  optional string from an explicitly-empty one, e.g. save's session_id).
   --  @param D The parsed arguments object.
   --  @param Key The member name to look up.
   --  @return True when Key is present and its value is a string.

   function Get_Int
     (D : Doc; Key : String; Default : Interfaces.Integer_64)
      return Interfaces.Integer_64;
   --  The integer member Key, or Default when absent / not an integer.
   --  @param D The parsed arguments object.
   --  @param Key The member name to look up.
   --  @param Default The value returned when Key is absent or not an integer.
   --  @return The integer value of Key, or Default.

   function Has_Int (D : Doc; Key : String) return Boolean;
   --  True when Key is present and an integer (an absent optional int -- e.g.
   --  fetch_turns' last/start/end -- must be distinguishable from a supplied 0).
   --  @param D The parsed arguments object.
   --  @param Key The member name to look up.
   --  @return True when Key is present and its value is an integer.

   function Get_Names (D : Doc; Key : String) return Memcp_Store.Name_List;
   --  The string-array member Key as a Store Name_List (project / session_id
   --  filters). Absent, null, or not-an-array yields an empty list; non-string
   --  elements are skipped. The Store refuses a list longer than
   --  Max_Filter_Terms, so no cap is applied here.
   --  @param D The parsed arguments object.
   --  @param Key The member name to look up.
   --  @return The array's string elements as a Name_List (empty when none).

   ----------------------
   -- Outbound scalars --
   ----------------------

   function Q (S : String) return String;
   --  A complete JSON string literal for S (escaped + quoted); Spark_Mcp.Writer.
   --  Total: a field longer than Max_Field (never, in practice -- the whole
   --  result is capped there) quotes as "" rather than tripping Writer.Quoted's
   --  length precondition, so callers need no precondition of their own.
   --  @param S The raw string to encode.
   --  @return A quoted, escaped JSON string literal for S.

   function N (V : Interfaces.Integer_64) return String
     with Post => N'Result'Length <= 21;
   --  A JSON integer literal (no leading blank). Bounded (a 64-bit integer is
   --  at most 20 digits plus a sign), so callers may concatenate it directly.
   --  @param V The integer value to render.
   --  @return The decimal JSON literal for V (at most 21 characters).

   function F (V : Interfaces.IEEE_Float_64) return String;
   --  A JSON number literal for a distance (finite, non-negative in practice).
   --  @param V The floating-point value to render.
   --  @return The JSON number literal for V.

private

   --  Doc is an ownership type (Needs_Reclamation, above); its full view is an
   --  access, so the private part is hidden from clients' proof -- they see Doc
   --  abstractly through Is_Closed, while this unit's body proves the getters
   --  against the real representation.
   pragma Annotate (GNATprove, Hide_Info, "Private_Part");

   type Impl_Record;
   type Impl_Access is access Impl_Record;
   --  Taft-amendment type: the parser + parsed value tree live in a record
   --  completed in the body, so this spec never `with`s the json crate (only
   --  Memcp_Json's body decodes JSON, keeping the json dependency contained
   --  exactly as Memcp_Envelope does). null when Open failed / after Close.

   type Doc is limited record
      Is_Valid : Boolean := False;   --  True when Open parsed object JSON.
      Impl     : Impl_Access;        --  Value tree; null if not open / closed.
   end record;
   --  Full view of Doc: an ownership wrapper over the body's parsed value tree.

   function Is_Closed (D : Doc) return Boolean is (D.Impl = null);
   --  Completion of Is_Closed: closed exactly when the value tree is null.
   --  @param D The document to test.
   --  @return True when D holds no value tree.

end Memcp_Json;

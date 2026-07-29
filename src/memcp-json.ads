--  Memcp.Json: the tool layer's JSON marshalling helper. Inbound, it parses an
--  `arguments` object -- raw JSON text off the seam -- into typed fields;
--  outbound, it renders scalars as JSON text. No JSON access type crosses this
--  package's boundary: every getter hands back a plain value.

with Interfaces;

with Memcp.Store;

package Memcp.Json with SPARK_Mode => On is

   type Doc is limited private
     with Annotate => (GNATprove, Ownership, "Needs_Reclamation"),
          Default_Initial_Condition => Is_Closed (Doc);
   --  A parsed `arguments` object, owning the value tree Open builds and Close
   --  reclaims.

   function Is_Closed (D : Doc) return Boolean
     with Ghost, Annotate => (GNATprove, Ownership, "Is_Reclaimed");
   --  Reclamation predicate for Doc: True when D holds no value tree, freshly
   --  declared or after Close.
   --  @param D The document to test.
   --  @return True when D holds no value tree (reclaimed or never opened).

   procedure Open (D : out Doc; Text : String);
   --  Parse Text as a JSON object. Never raises: Valid (D) is True only when
   --  Text is well-formed JSON whose top level is an object, and the getters
   --  below assume that shape.
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
   --  True when Key is present and a string, distinguishing an absent optional
   --  string from an explicitly empty one.
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
   --  True when Key is present and an integer, distinguishing an absent optional
   --  integer from a supplied 0.
   --  @param D The parsed arguments object.
   --  @param Key The member name to look up.
   --  @return True when Key is present and its value is an integer.

   function Get_Names (D : Doc; Key : String) return Memcp.Store.Name_List;
   --  The string-array member Key as a Memcp.Store.Name_List. Absent, null or
   --  not-an-array yields an empty list, and non-string elements are skipped.
   --  Uncapped, because the Store refuses a list longer than Max_Filter_Terms.
   --  @param D The parsed arguments object.
   --  @param Key The member name to look up.
   --  @return The array's string elements as a Name_List (empty when none).

   ----------------------
   -- Outbound scalars --
   ----------------------

   function Q (S : String) return String;
   --  A complete JSON string literal for S: escaped and quoted. Total -- a
   --  string longer than Max_Field quotes as "" rather than tripping
   --  Writer.Quoted's length precondition -- so callers need none of their own.
   --  @param S The raw string to encode.
   --  @return A quoted, escaped JSON string literal for S.

   function N (V : Interfaces.Integer_64) return String
     with Post => N'Result'Length <= 21;
   --  A JSON integer literal, with no leading blank. Bounded at 20 digits plus a
   --  sign, so callers may concatenate it directly.
   --  @param V The integer value to render.
   --  @return The decimal JSON literal for V (at most 21 characters).

   function F (V : Interfaces.IEEE_Float_64) return String;
   --  A JSON number literal, with no leading blank.
   --  @param V The floating-point value to render.
   --  @return The JSON number literal for V.

private

   pragma Annotate (GNATprove, Hide_Info, "Private_Part");
   --  Required for GNATprove Ownership: clients see Doc only through Is_Closed,
   --  while this unit's body proves the getters against the representation.

   type Impl_Record;
   --  Incomplete type completed in the body, so this spec never `with`s the json
   --  crate.

   type Impl_Access is access Impl_Record;
   --  The owning pointer to the value tree; null when Open failed or after
   --  Close.

   type Doc is limited record
      Is_Valid : Boolean := False;   --  True when Open parsed object JSON.
      Impl     : Impl_Access;        --  Value tree; null if not open / closed.
   end record;
   --  A parsed `arguments` object, as an ownership wrapper over the body's value
   --  tree.

   function Is_Closed (D : Doc) return Boolean is (D.Impl = null);
   --  Closed exactly when the value tree is null.
   --  @param D The document to test.
   --  @return True when D holds no value tree.

end Memcp.Json;

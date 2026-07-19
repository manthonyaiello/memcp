package body Memcp_Resources with
  SPARK_Mode    => On,
  Refined_State => (Store_State    => (The_Store, Opened),
                    Embedder_State => (The_Embedder, Have_Model))
is

   --  Library-level singletons + their status flags. The_Store owns a SQLite
   --  connection; The_Embedder a (non-owning) candle handle.
   The_Store    : MS.Store;
   The_Embedder : Candle_Spark.Embedder;

   Opened     : Boolean := False;
   Have_Model : Boolean := False;

   use type MS.Open_Status;
   use type Candle_Spark.Status;

   ----------
   -- Open --
   ----------

   procedure Open
     (DB_Path : String; Model_Path : String; Status : out Open_Status)
   is
      Store_St : MS.Open_Status;
   begin
      Opened     := False;
      Have_Model := False;

      --  DB_Path validity is a precondition, so Store_State is always fully
      --  written here (Output) -- its prior contents are never leaked.
      MS.Open (The_Store, DB_Path, Store_St);
      if Store_St /= MS.Opened then
         Status := Store_Failed;
         return;
      end if;
      Opened := True;

      if Model_Path'Length > 0 then
         declare
            Load_St : Candle_Spark.Status;
         begin
            --  Load takes The_Embedder as an out parameter, overwriting it. As
            --  an owning (Needs_Reclamation) handle it must be reclaimed first,
            --  or a prior model would leak on a re-Open. Unload is idempotent
            --  and posts Is_Reclaimed, so this both discharges that obligation
            --  and rules out the double-ownership hazard the annotation exists
            --  to catch.
            --
            --  Unload's reclaiming write to The_Embedder is then immediately
            --  overwritten by the out-mode Load, so flow analysis reports that
            --  write as dead ("no effect" / "set but not used after the call").
            --  That is orthogonal to what Unload is for -- releasing the prior
            --  C model -- exactly the flow-vs-ownership gap the Memcp_Store
            --  Finalize suppression documents; silence just those two messages.
            pragma Warnings (GNATprove, Off, "statement has no effect",
              Reason => "Unload's reclaiming write is overwritten by Load");
            pragma Warnings
              (GNATprove, Off,
               "*is set by ""Unload"" but not used after the call",
               Reason => "Unload reclaims the prior model; the nulled handle "
                         & "is rebound by Load and never read in between");
            Candle_Spark.Unload (The_Embedder);
            pragma Warnings (GNATprove, On,
              "*is set by ""Unload"" but not used after the call");
            pragma Warnings (GNATprove, On, "statement has no effect");
            Candle_Spark.Load (The_Embedder, Model_Path, Load_St);
            Have_Model := (Load_St = Candle_Spark.Ok);
         end;
      end if;

      Status := Ready;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close is
   begin
      if Have_Model then
         Candle_Spark.Unload (The_Embedder);
         Have_Model := False;
      end if;
      if Opened then
         MS.Close (The_Store);
         Opened := False;
      end if;
   end Close;

   -------------
   -- Queries --
   -------------

   function Is_Open return Boolean is (Opened and then MS.Is_Open (The_Store));

   function Embedder_Loaded return Boolean is (Have_Model);

   ------------------
   -- Recent_Diary --
   ------------------

   procedure Recent_Diary
     (Projects : MS.Name_List;
      N        : Natural;
      Result   : out MS.Diary_Entry_List;
      Status   : out MS.Op_Status)
   is
   begin
      if not Is_Open then
         Result := MS.Diary_Vectors.Empty_Vector;
         Status := MS.Db_Error;
         return;
      end if;
      MS.Recent_Diary (The_Store, Projects, N, Result, Status);
   end Recent_Diary;

   -------------------
   -- List_Projects --
   -------------------

   procedure List_Projects
     (Result : out MS.Project_Info_List;
      Status : out MS.Op_Status)
   is
   begin
      if not Is_Open then
         Result := MS.Project_Vectors.Empty_Vector;
         Status := MS.Db_Error;
         return;
      end if;
      MS.List_Projects (The_Store, Result, Status);
   end List_Projects;

   -------------------
   -- Fetch_Summary --
   -------------------

   procedure Fetch_Summary
     (Id     : MS.Row_Id;
      Result : out MS.Summary_Ptr;
      Status : out MS.Op_Status)
   is
   begin
      if not Is_Open then
         Result := null;
         Status := MS.Db_Error;
         return;
      end if;
      MS.Fetch_Summary (The_Store, Id, Result, Status);
   end Fetch_Summary;

   ----------------------
   -- Search_Summaries --
   ----------------------

   procedure Search_Summaries
     (Query_Emb : Candle_Spark.Embedding;
      Projects  : MS.Name_List;
      Limit     : Natural;
      Has_Since : Boolean;
      Since     : String;
      Has_Until : Boolean;
      Until_At  : String;
      Result    : out MS.Summary_Hit_List;
      Status    : out MS.Op_Status)
   is
   begin
      if not Is_Open then
         Result := MS.Summary_Hit_Vectors.Empty_Vector;
         Status := MS.Db_Error;
         return;
      end if;
      MS.Search_Summaries
        (The_Store, Query_Emb, Projects, Limit,
         Has_Since, Since, Has_Until, Until_At, Result, Status);
   end Search_Summaries;

   -------------------
   -- Search_Chunks --
   -------------------

   procedure Search_Chunks
     (Query_Emb   : Candle_Spark.Embedding;
      Projects    : MS.Name_List;
      Session_Ids : MS.Name_List;
      Limit       : Natural;
      Has_Since   : Boolean;
      Since       : String;
      Has_Until   : Boolean;
      Until_At    : String;
      Result      : out MS.Chunk_Hit_List;
      Status      : out MS.Op_Status)
   is
   begin
      if not Is_Open then
         Result := MS.Chunk_Hit_Vectors.Empty_Vector;
         Status := MS.Db_Error;
         return;
      end if;
      MS.Search_Chunks
        (The_Store, Query_Emb, Projects, Session_Ids, Limit,
         Has_Since, Since, Has_Until, Until_At, Result, Status);
   end Search_Chunks;

   -----------------
   -- Fetch_Turns --
   -----------------

   procedure Fetch_Turns
     (Session_Id  : String;
      Has_Project : Boolean;
      Project     : String;
      Has_Start   : Boolean;
      Start_Ord   : MS.Row_Id;
      Has_End     : Boolean;
      End_Ord     : MS.Row_Id;
      Has_Tail    : Boolean;
      Tail        : Positive;
      Result      : out MS.Chunk_List;
      Status      : out MS.Op_Status)
   is
   begin
      --  MS.Fetch_Turns forbids combining a tail with start/end.
      if not Is_Open or else (Has_Tail and then (Has_Start or else Has_End)) then
         Result := MS.Chunk_Vectors.Empty_Vector;
         Status := MS.Db_Error;
         return;
      end if;
      MS.Fetch_Turns
        (The_Store, Session_Id, Has_Project, Project,
         Has_Start, Start_Ord, Has_End, End_Ord, Has_Tail, Tail,
         Result, Status);
   end Fetch_Turns;

   ----------
   -- Save --
   ----------

   procedure Save
     (Project      : String;
      Diary_Body   : String;
      Summary_Body : String;
      Embedding    : Candle_Spark.Embedding;
      Has_Session  : Boolean;
      Session_Id   : String;
      Has_Created  : Boolean;
      Created_At   : String;
      Result       : out MS.Save_Result;
      Status       : out MS.Op_Status)
   is
   begin
      if not Is_Open
        or else Project'Length = 0
        or else Project'Last = Natural'Last
        or else Summary_Body'Last = Integer'Last
      then
         Result := (Summary_Id => 0, Diary_Id => 0,
                    Already_Existed => False, Replaced => False);
         Status := MS.Db_Error;
         return;
      end if;
      MS.Save
        (The_Store, Project, Diary_Body, Summary_Body, Embedding,
         Has_Session, Session_Id, Has_Created, Created_At, Result, Status);
   end Save;

   --------------------
   -- Forget_Summary --
   --------------------

   procedure Forget_Summary
     (Id      : MS.Row_Id;
      Deleted : out Boolean;
      Status  : out MS.Op_Status)
   is
   begin
      if not Is_Open then
         Deleted := False;
         Status  := MS.Db_Error;
         return;
      end if;
      MS.Forget_Summary (The_Store, Id, Deleted, Status);
   end Forget_Summary;

   ------------------
   -- Save_Session --
   ------------------

   procedure Save_Session
     (Project     : String;
      Session_Id  : String;
      Transcript  : String;
      Chunks      : MS.Chunk_Input_List;
      Has_Created : Boolean;
      Created_At  : String;
      Result      : out MS.Session_Save_Result;
      Status      : out MS.Op_Status)
   is
   begin
      if not Is_Open
        or else Project'Length = 0
        or else Project'Last = Natural'Last
        or else Session_Id'Last = Natural'Last
      then
         Result := (Session_Row_Id => 0, Chunk_Count => 0,
                    Already_Existed => False, Raw_Path_Set => False);
         Status := MS.Db_Error;
         return;
      end if;
      MS.Save_Session
        (The_Store, Project, Session_Id, Transcript, Chunks,
         Has_Created, Created_At, Result, Status);
   end Save_Session;

   -------------------
   -- Save_Autorecap --
   -------------------

   procedure Save_Autorecap
     (Project     : String;
      Session_Id  : String;
      Recap_Text  : String;
      Embedding   : Candle_Spark.Embedding;
      Has_Created : Boolean;
      Created_At  : String;
      Summary_Id  : out MS.Row_Id;
      Diary_Id    : out MS.Row_Id;
      Written     : out Boolean;
      Status      : out MS.Op_Status)
   is
   begin
      if not Is_Open
        or else Project'Length = 0
        or else Project'Last = Natural'Last
        or else Recap_Text'Last = Integer'Last
      then
         Summary_Id := 0;
         Diary_Id   := 0;
         Written    := False;
         Status     := MS.Db_Error;
         return;
      end if;
      MS.Save_Autorecap
        (The_Store, Project, Session_Id, Recap_Text, Embedding,
         Has_Created, Created_At, Summary_Id, Diary_Id, Written, Status);
   end Save_Autorecap;

   -----------
   -- Embed --
   -----------

   function Embed
     (Text : String) return Candle_Spark.Embedding
   is
   begin
      if Text'Length = 0
        or else not Have_Model
        or else not Candle_Spark.Is_Loaded (The_Embedder)
      then
         return [others => 0.0];
      end if;
      return Candle_Spark.Embed (The_Embedder, Text);
   end Embed;

end Memcp_Resources;

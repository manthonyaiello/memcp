--  Memcp.Resources body: each operation guards its own preconditions, then
--  passes through to the owned Store or Embedder.

package body Memcp.Resources with SPARK_Mode => On is

   use type MS.Open_Status;
   use type Candle_Spark.Status;

   ----------
   -- Open --
   ----------

   procedure Open
     (R          : in out Resources;
      DB_Path    : String;
      Model_Path : String;
      Result     : out Status)
   is
      Store_St : MS.Open_Status;
      --  Outcome of the store open; anything but Opened is Store_Failed.
   begin
      MS.Open (R.The_Store, DB_Path, Store_St);
      if Store_St /= MS.Opened then
         Result := Store_Failed;
         return;
      end if;

      if Model_Path'Length > 0 then
         declare
            Load_St : Candle_Spark.Status;
            --  Outcome of the model load; never reported to the caller.
         begin
            Candle_Spark.Load (R.The_Embedder, Model_Path, Load_St);
            --  The outcome lives in the handle, which Embedder_Loaded reads;
            --  the assertion is what consumes Load_St.
            pragma Assert
              (Embedder_Loaded (R) = (Load_St = Candle_Spark.Ok));
         end;
      end if;

      Result := Ready;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (R : in out Resources) is
   begin
      --  Both reclaimers are idempotent, which is what makes Close idempotent.
      Candle_Spark.Unload (R.The_Embedder);
      MS.Close (R.The_Store);
   end Close;

   -----------
   -- Embed --
   -----------

   function Embed
     (R : Resources; Text : String) return Candle_Spark.Embedding
   is
   begin
      if Text'Length = 0 or else not Candle_Spark.Is_Loaded (R.The_Embedder)
      then
         return [others => 0.0];
      end if;
      return Candle_Spark.Embed (R.The_Embedder, Text);
   end Embed;

   ------------------
   -- Recent_Diary --
   ------------------

   procedure Recent_Diary
     (R        : Resources;
      Projects : MS.Name_List;
      N        : Natural;
      Result   : out MS.Diary_Entry_List;
      Status   : out MS.Op_Status)
   is
   begin
      if not Is_Open (R) then
         Result := MS.Diary_Vectors.Empty_Vector;
         Status := MS.Db_Error;
         return;
      end if;
      MS.Recent_Diary (R.The_Store, Projects, N, Result, Status);
   end Recent_Diary;

   -------------------
   -- List_Projects --
   -------------------

   procedure List_Projects
     (R      : Resources;
      Result : out MS.Project_Info_List;
      Status : out MS.Op_Status)
   is
   begin
      if not Is_Open (R) then
         Result := MS.Project_Vectors.Empty_Vector;
         Status := MS.Db_Error;
         return;
      end if;
      MS.List_Projects (R.The_Store, Result, Status);
   end List_Projects;

   -----------------------
   -- Degraded_Surfaces --
   -----------------------

   procedure Degraded_Surfaces
     (R      : Resources;
      Result : out MS.Surface_Health_List;
      Status : out MS.Op_Status)
   is
   begin
      if not Is_Open (R) then
         Result := MS.Surface_Health_Vectors.Empty_Vector;
         Status := MS.Db_Error;
         return;
      end if;
      MS.Degraded_Surfaces
        (R.The_Store, MS.Health_Window, MS.Health_Threshold, Result, Status);
   end Degraded_Surfaces;

   ------------------
   -- Fleet_Health --
   ------------------

   procedure Fleet_Health
     (R      : Resources;
      Result : out MS.Surface_Health_List;
      Status : out MS.Op_Status)
   is
   begin
      if not Is_Open (R) then
         Result := MS.Surface_Health_Vectors.Empty_Vector;
         Status := MS.Db_Error;
         return;
      end if;
      MS.Fleet_Health (R.The_Store, MS.Health_Window, Result, Status);
   end Fleet_Health;

   -------------------
   -- Touch_Surface --
   -------------------

   procedure Touch_Surface
     (R            : Resources;
      Uuid         : String;
      Label        : String;
      Hook_Version : String;
      Host         : String;
      Install_Host : String;
      Status       : out MS.Op_Status)
   is
   begin
      if not Is_Open (R) then
         Status := MS.Db_Error;
         return;
      end if;
      MS.Touch_Surface
        (R.The_Store, Uuid, Label, Hook_Version, Host, Install_Host, Status);
   end Touch_Surface;

   -------------------
   -- Fetch_Summary --
   -------------------

   procedure Fetch_Summary
     (R      : Resources;
      Id     : MS.Row_Id;
      Result : out MS.Summary_Ptr;
      Status : out MS.Op_Status)
   is
   begin
      if not Is_Open (R) then
         Result := null;
         Status := MS.Db_Error;
         return;
      end if;
      MS.Fetch_Summary (R.The_Store, Id, Result, Status);
   end Fetch_Summary;

   ----------------------
   -- Search_Summaries --
   ----------------------

   procedure Search_Summaries
     (R         : Resources;
      Query_Emb : Candle_Spark.Embedding;
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
      if not Is_Open (R) then
         Result := MS.Summary_Hit_Vectors.Empty_Vector;
         Status := MS.Db_Error;
         return;
      end if;
      MS.Search_Summaries
        (R.The_Store, Query_Emb, Projects, Limit,
         Has_Since, Since, Has_Until, Until_At, Result, Status);
   end Search_Summaries;

   -------------------
   -- Search_Chunks --
   -------------------

   procedure Search_Chunks
     (R           : Resources;
      Query_Emb   : Candle_Spark.Embedding;
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
      if not Is_Open (R) then
         Result := MS.Chunk_Hit_Vectors.Empty_Vector;
         Status := MS.Db_Error;
         return;
      end if;
      MS.Search_Chunks
        (R.The_Store, Query_Emb, Projects, Session_Ids, Limit,
         Has_Since, Since, Has_Until, Until_At, Result, Status);
   end Search_Chunks;

   -----------------
   -- Fetch_Turns --
   -----------------

   procedure Fetch_Turns
     (R           : Resources;
      Session_Id  : String;
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
      if not Is_Open (R)
        or else (Has_Tail and then (Has_Start or else Has_End))
      then
         Result := MS.Chunk_Vectors.Empty_Vector;
         Status := MS.Db_Error;
         return;
      end if;
      MS.Fetch_Turns
        (R.The_Store, Session_Id, Has_Project, Project,
         Has_Start, Start_Ord, Has_End, End_Ord, Has_Tail, Tail,
         Result, Status);
   end Fetch_Turns;

   ----------
   -- Save --
   ----------

   procedure Save
     (R            : Resources;
      Project      : String;
      Diary_Body   : String;
      Summary_Body : String;
      Embedding    : Candle_Spark.Embedding;
      Has_Session  : Boolean;
      Session_Id   : String;
      Has_Created  : Boolean;
      Created_At   : String;
      Surface      : String;
      Surface_Label : String;
      Result       : out MS.Save_Result;
      Status       : out MS.Op_Status)
   is
   begin
      if not Is_Open (R)
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
        (R.The_Store, Project, Diary_Body, Summary_Body, Embedding,
         Has_Session, Session_Id, Has_Created, Created_At, Surface,
         Surface_Label, Result, Status);
   end Save;

   --------------------
   -- Forget_Summary --
   --------------------

   procedure Forget_Summary
     (R       : Resources;
      Id      : MS.Row_Id;
      Deleted : out Boolean;
      Status  : out MS.Op_Status)
   is
   begin
      if not Is_Open (R) then
         Deleted := False;
         Status  := MS.Db_Error;
         return;
      end if;
      MS.Forget_Summary (R.The_Store, Id, Deleted, Status);
   end Forget_Summary;

   ------------------
   -- Save_Session --
   ------------------

   procedure Save_Session
     (R           : Resources;
      Project     : String;
      Session_Id  : String;
      Transcript  : String;
      Chunks      : MS.Chunk_Input_List;
      Has_Created : Boolean;
      Created_At  : String;
      Surface       : String;
      Surface_Label : String;
      Result      : out MS.Session_Save_Result;
      Status      : out MS.Op_Status)
   is
   begin
      if not Is_Open (R)
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
        (R.The_Store, Project, Session_Id, Transcript, Chunks,
         Has_Created, Created_At, Surface, Surface_Label, Result, Status);
   end Save_Session;

   --------------------
   -- Save_Autorecap --
   --------------------

   procedure Save_Autorecap
     (R           : Resources;
      Project     : String;
      Session_Id  : String;
      Recap_Text  : String;
      Embedding   : Candle_Spark.Embedding;
      Has_Created : Boolean;
      Created_At  : String;
      Surface       : String;
      Surface_Label : String;
      Result      : out MS.Autorecap_Result;
      Status      : out MS.Op_Status)
   is
   begin
      if not Is_Open (R)
        or else Project'Length = 0
        or else Project'Last = Natural'Last
        or else Recap_Text'Last = Integer'Last
      then
         Result := (Summary_Id => 0, Diary_Id => 0, Written => False);
         Status := MS.Db_Error;
         return;
      end if;
      MS.Save_Autorecap
        (R.The_Store, Project, Session_Id, Recap_Text, Embedding,
         Has_Created, Created_At, Surface, Surface_Label, Result, Status);
   end Save_Autorecap;

end Memcp.Resources;

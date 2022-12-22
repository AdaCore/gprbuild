------------------------------------------------------------------------------
--                                                                          --
--                             GPR TECHNOLOGY                               --
--                                                                          --
--                    Copyright (C) 2015-2021, AdaCore                      --
--                                                                          --
-- This is  free  software;  you can redistribute it and/or modify it under --
-- terms of the  GNU  General Public License as published by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for more details.  You should have received  a copy of the  GNU  --
-- General Public License distributed with GNAT; see file  COPYING. If not, --
-- see <http://www.gnu.org/licenses/>.                                      --
--                                                                          --
------------------------------------------------------------------------------

with Ada.Text_IO; use Ada.Text_IO;

with GPR.Names;  use GPR.Names;
with GPR.Output; use GPR.Output;
with GPR.Util;

package body Gprls is

   No_Obj : constant String := "<no_obj>";

   use GPR.Stamps;

   procedure Find_Status
     (Source   : GPR.Source_Id;
      Stamp    : Time_Stamp_Type;
      Checksum : Word;
      Status   : out File_Status);
   --  Determine the file status (Status) of the file represented by FS with
   --  the expected Stamp and checksum given as argument. FS will be updated
   --  to the full file name if available.

   ---------
   -- Add --
   ---------

   procedure Add (Path : String; To : in out Paths) is
      Cur : Path_Access := To.First;
   begin
      while Cur /= null loop
         if Cur.Path.all = Path then
            return;
         end if;

         Cur := Cur.Next;
      end loop;

      declare
         New_Path : constant Path_Access :=
           new Path_Record'(Path => new String'(Path), Next => null);
      begin
         if To = No_Paths then
            To := (New_Path, New_Path);

         else
            To.Last.Next := New_Path;
            To.Last := New_Path;
         end if;
      end;
   end Add;

   -------------
   -- Add_ALI --
   -------------

   procedure Add_ALI
     (ALI_Name : File_Name_Type;
      Spec     : Boolean;
      Source   : GPR.Source_Id)
   is
      A : constant ALI_Kind := (File => ALI_Name, Spec => Spec);
   begin
      ALI_Names.Set (A, Source);
   end Add_ALI;

   --------------
   -- Add_File --
   --------------

   procedure Add_File
     (File_Name : String;
      Tree      : Project_Tree_Ref;
      Source    : GPR.Source_Id := No_Source) is
   begin
      if Current_Verbosity = High then
         Put_Line ("adding file """ & File_Name & '"');
      end if;

      File_Names.Append
        (File_Name_Source'
           (Name_Len  => File_Name'Length,
            File_Name => File_Name,
            Tree      => Tree,
            Source    => Source,
            The_ALI   => No_ALI_Id));
   end Add_File;

   ------------------------------
   -- Corresponding_Sdep_Entry --
   ------------------------------

   function Corresponding_Sdep_Entry
     (A : ALI_Id;
      U : Unit_Id) return Sdep_Id
   is
   begin
      for D in ALIs.Table (A).First_Sdep .. ALIs.Table (A).Last_Sdep loop
         if Sdep.Table (D).Sfile = Units.Table (U).Sfile then
            return D;
         end if;
      end loop;

      return No_Sdep_Id;
   end Corresponding_Sdep_Entry;

   --------------
   -- Find_ALI --
   --------------

   function Find_ALI (Source : GPR.Source_Id) return ALI_Id is
      Text    : Text_Buffer_Ptr;
      Result  : ALI_Id;
   begin
      Text := Osint.Read_Library_Info (File_Name_Type (Source.Dep_Path));

      if Text /= null then
         Result := Scan_ALI
           (F          => File_Name_Type (Source.Dep_Path),
            T          => Text,
            Ignore_ED  => False,
            Err        => True,
            Read_Lines => "WD");
         Free (Text);
         return Result;

      else
         return No_ALI_Id;
      end if;
   end Find_ALI;

   -----------------
   -- Find_Source --
   -----------------

   function Find_Source
     (ALI_Name : File_Name_Type;
      Spec     : Boolean)
      return GPR.Source_Id
   is
      A : constant ALI_Kind := (File => ALI_Name, Spec => Spec);
   begin
      return ALI_Names.Get (A);
   end Find_Source;

   -----------------
   -- Find_Status --
   -----------------

   procedure Find_Status
     (Source : GPR.Source_Id;
      ALI    : ALI_Id;
      Status : out File_Status)
   is
      U : Unit_Id;
   begin
      if ALI = No_ALI_Id then
         Status := Not_Found;
      else
         U :=
           (if Source.Kind = Spec then ALIs.Table (ALI).Last_Unit
            else ALIs.Table (ALI).First_Unit);

         Find_Status (Source, ALI, U, Status);
      end if;
   end Find_Status;

   procedure Find_Status
     (Source : GPR.Source_Id;
      ALI    : ALI_Id;
      U      : Unit_Id;
      Status : out File_Status)
   is
      SD : constant Sdep_Id := Corresponding_Sdep_Entry (ALI, U);
   begin
      if File_Stamp (Source.Path.Name) = Sdep.Table (SD).Stamp then
         Status := OK;

      elsif Util.Calculate_Checksum (Source)
        and then Source.Checksum = Sdep.Table (SD).Checksum
      then
         Status := Checksum_OK;

      else
         Status := Not_Same;
      end if;
   end Find_Status;

   procedure Find_Status
     (Source   : GPR.Source_Id;
      Stamp    : Time_Stamp_Type;
      Checksum : Word;
      Status   : out File_Status) is
   begin
      if Source = No_Source then
         Status := Not_Found;

      elsif File_Stamp (Source.Path.Name) = Stamp then
         Status := OK;

      elsif Util.Calculate_Checksum (Source)
        and then Source.Checksum = Checksum
      then
         Status := Checksum_OK;

      else
         Status := Not_Same;
      end if;
   end Find_Status;

   -----------------------------
   -- Get_Runtime_Source_Dirs --
   -----------------------------

   procedure Get_Runtime_Source_Dirs
     (Project    : Project_Id;
      Tree       : Project_Tree_Ref;
      With_State : in out Paths)
   is
      List    : Language_Ptr := Project.Languages;
      Dirs    : Name_List_Index;
      Nam_Nod : Name_Node;
   begin
      while List /= No_Language_Index loop
         Dirs := List.Config.Runtime_Source_Dirs;
         while Dirs /= No_Name_List loop
            Nam_Nod := Tree.Shared.Name_Lists.Table (Dirs);
            Add (Get_Name_String (Nam_Nod.Name), With_State);
            Dirs := Nam_Nod.Next;
         end loop;

         List := List.Next;
      end loop;
   end Get_Runtime_Source_Dirs;

   ----------
   -- Hash --
   ----------

   function Hash (A : ALI_Kind) return GPR.Header_Num is
   begin
      return GPR.Hash (A.File);
   end Hash;

   -------------------
   -- Output_Object --
   -------------------

   procedure Output_Object (O : File_Name_Type) is
   begin
      if Print_Object then
         Put_Line ((if O /= No_File then Get_Name_String (O) else No_Obj));
      end if;
   end Output_Object;

   -------------------
   -- Output_Source --
   -------------------

   procedure Output_Source
     (Source : GPR.Source_Id; Sdep_I : Sdep_Id)
   is
      Stamp    : GPR.Stamps.Time_Stamp_Type;
      Checksum : Word;
      Status   : File_Status;
      Sfile    : File_Name_Type;
      Src      : GPR.Source_Id;

   begin
      if Sdep_I = No_Sdep_Id or else Source = No_Source then
         return;
      end if;

      Stamp    := Sdep.Table (Sdep_I).Stamp;
      Checksum := Sdep.Table (Sdep_I).Checksum;
      Sfile    := Sdep.Table (Sdep_I).Sfile;

      --  Find the real source

      if Sfile = Source.File then
         Src := Source;

      else
         --  Check if it may be a spec

         Src := ALI_Names.Get ((Sfile, True));

         if Src = No_Source then
            Src := ALI_Names.Get ((Sfile, False));

            if Src = No_Source then
               Src := Source;
            end if;
         end if;
      end if;

      if Print_Source then
         Find_Status (Src, Stamp, Checksum, Status);

         if Verbose_Mode then
            Put ("     Source => ");
            Put (Get_Name_String (Src.Path.Display_Name));
            Output_Status (Status, True);
            New_Line;

         else
            if not Selective_Output then
               Put ("    ");
               Output_Status (Status, Verbose => False);
            end if;

            Put_Line (Get_Name_String (Source.Path.Display_Name));
         end if;
      end if;
   end Output_Source;

   procedure Output_Source (Tree : Project_Tree_Ref; Sdep_I : Sdep_Id) is

      function Get_Source
        (Tree    : Project_Tree_Ref;
         Project : Project_Id;
         FS      : File_Name_Type) return GPR.Source_Id;

      ----------------
      -- Get_Source --
      ----------------

      function Get_Source
        (Tree    : Project_Tree_Ref;
         Project : Project_Id;
         FS      : File_Name_Type) return GPR.Source_Id
      is
         Aggr : Aggregated_Project_List;
         Got  : GPR.Source_Id;
      begin
         if Project.Qualifier = Aggregate then
            Aggr := Project.Aggregated_Projects;

            while Aggr /= null loop
               Got := Get_Source (Aggr.Tree, Aggr.Project, FS);

               if Got /= No_Source then
                  return Got;
               end if;

               Aggr := Aggr.Next;
            end loop;

            return No_Source;

         else
            return Source_Files_Htable.Get (Tree.Source_Files_HT, FS);
         end if;
      end Get_Source;

   begin
      if Sdep_I /= No_Sdep_Id then
         if Tree /= No_Project_Tree then
            Output_Source
              (Source_Files_Htable.Get
                 (Tree.Source_Files_HT, Sdep.Table (Sdep_I).Sfile),
               Sdep_I);
         else
            Output_Source
              (Get_Source
                 (Project_Tree, Util.Main_Project, Sdep.Table (Sdep_I).Sfile),
               Sdep_I);
         end if;
      end if;
   end Output_Source;

   -------------------
   -- Output_Status --
   -------------------

   procedure Output_Status (FS : File_Status; Verbose : Boolean) is
   begin
      if Verbose then
         case FS is
            when OK =>
               Put (" unchanged");

            when Checksum_OK =>
               Put (" slightly modified");

            when Not_Found =>
               Put (" dependency file not found");

            when Not_Same =>
               Put (" modified");
         end case;

      else
         case FS is
            when OK =>
               Put ("  OK ");

            when Checksum_OK =>
               Put (" MOK ");

            when Not_Found =>
               Put (" ??? ");

            when Not_Same =>
               Put (" DIF ");
         end case;
      end if;
   end Output_Status;

   -----------------
   -- Output_Unit --
   -----------------

   procedure Output_Unit (U_Id : Unit_Id) is
      Kind : Character;
      U    : Unit_Record renames Units.Table (U_Id);

   begin
      Get_Name_String (U.Uname);
      Kind := Name_Buffer (Name_Len);
      Name_Len := Name_Len - 2;

      Set_Casing (Mixed_Case);

      if not Verbose_Mode then
         Put_Line ("   " & Name_Buffer (1 .. Name_Len));

      else
         Put ("   Unit => ");
         New_Line;
         Put ("     Name   => ");
         Put (Name_Buffer (1 .. Name_Len));
         New_Line;
         Put ("     Kind   => ");

         Put
           ((if Units.Table (U_Id).Unit_Kind = 'p' then "package "
             else "subprogram "));

         Put_Line ((if Kind = 's' then "spec" else "body"));
      end if;

      if Verbose_Mode then
         if U.Preelab            or else
           U.No_Elab             or else
           U.Pure                or else
           U.Dynamic_Elab        or else
           U.Has_RACW            or else
           U.Remote_Types        or else
           U.Shared_Passive      or else
           U.RCI                 or else
           U.Predefined          or else
           U.Is_Generic          or else
           U.Init_Scalars        or else
           U.SAL_Interface       or else
           U.Body_Needed_For_SAL or else
           U.Elaborate_Body
         then
            Put ("     Flags  =>");

            if U.Preelab then
               Put (" Preelaborable");
            end if;

            if U.No_Elab then
               Put (" No_Elab_Code");
            end if;

            if U.Pure then
               Put (" Pure");
            end if;

            if U.Dynamic_Elab then
               Put (" Dynamic_Elab");
            end if;

            if U.Has_RACW then
               Put (" Has_RACW");
            end if;

            if U.Remote_Types then
               Put (" Remote_Types");
            end if;

            if U.Shared_Passive then
               Put (" Shared_Passive");
            end if;

            if U.RCI then
               Put (" RCI");
            end if;

            if U.Predefined then
               Put (" Predefined");
            end if;

            if U.Is_Generic then
               Put (" Is_Generic");
            end if;

            if U.Init_Scalars then
               Put (" Init_Scalars");
            end if;

            if U.SAL_Interface then
               Put (" SAL_Interface");
            end if;

            if U.Body_Needed_For_SAL then
               Put (" Body_Needed_For_SAL");
            end if;

            if U.Elaborate_Body then
               Put (" Elaborate Body");
            end if;

            if U.Remote_Types then
               Put (" Remote_Types");
            end if;

            if U.Shared_Passive then
               Put (" Shared_Passive");
            end if;

            if U.Predefined then
               Put (" Predefined");
            end if;

            New_Line;
         end if;
      end if;
   end Output_Unit;

   -----------------
   -- Reset_Print --
   -----------------

   procedure Reset_Print is
   begin
      if not Selective_Output then
         Selective_Output := True;
         Print_Source := False;
         Print_Object := False;
         Print_Unit   := False;
      end if;
   end Reset_Print;

   --------------
   -- GNATDIST --
   --------------

   package body GNATDIST is

      Runtime_Source_Dirs : Paths := No_Paths;

      N_Flags   : Natural;
      N_Indents : Natural := 0;

      type Token_Type is
        (T_No_ALI,
         T_ALI,
         T_Unit,
         T_With,
         T_Source,
         T_Afile,
         T_Ofile,
         T_Sfile,
         T_Name,
         T_Main,
         T_Kind,
         T_Flags,
         T_Preelaborated,
         T_Pure,
         T_Has_RACW,
         T_Remote_Types,
         T_Shared_Passive,
         T_RCI,
         T_Predefined,
         T_Internal,
         T_Is_Generic,
         T_Procedure,
         T_Function,
         T_Package,
         T_Subprogram,
         T_Spec,
         T_Body);

      Image : constant array (Token_Type) of String_Access :=
                (T_No_ALI         => new String'("No_ALI"),
                 T_ALI            => new String'("ALI"),
                 T_Unit           => new String'("Unit"),
                 T_With           => new String'("With"),
                 T_Source         => new String'("Source"),
                 T_Afile          => new String'("Afile"),
                 T_Ofile          => new String'("Ofile"),
                 T_Sfile          => new String'("Sfile"),
                 T_Name           => new String'("Name"),
                 T_Main           => new String'("Main"),
                 T_Kind           => new String'("Kind"),
                 T_Flags          => new String'("Flags"),
                 T_Preelaborated  => new String'("Preelaborated"),
                 T_Pure           => new String'("Pure"),
                 T_Has_RACW       => new String'("Has_RACW"),
                 T_Remote_Types   => new String'("Remote_Types"),
                 T_Shared_Passive => new String'("Shared_Passive"),
                 T_RCI            => new String'("RCI"),
                 T_Predefined     => new String'("Predefined"),
                 T_Internal       => new String'("Internal"),
                 T_Is_Generic     => new String'("Is_Generic"),
                 T_Procedure      => new String'("procedure"),
                 T_Function       => new String'("function"),
                 T_Package        => new String'("package"),
                 T_Subprogram     => new String'("subprogram"),
                 T_Spec           => new String'("spec"),
                 T_Body           => new String'("body"));

      procedure Output_Name  (N : Name_Id);
      --  Remove any encoding info (%b and %s) and output N

      procedure Output_Afile (A   : File_Name_Type);
      procedure Output_Ofile (FNS : File_Name_Source);
      procedure Output_Sfile (Src : GPR.Source_Id);
      procedure Output_Sfile (S   : File_Name_Type);
      --  Output various names. Check that the name is different from no name.
      --  Otherwise, skip the output.

      procedure Output_Token (T : Token_Type);
      --  Output token using specific format. That is several indentations and:
      --
      --  T_No_ALI  .. T_With : <token> & " =>" & NL
      --  T_Source  .. T_Kind : <token> & " => "
      --  T_Flags             : <token> & " =>"
      --  T_Preelab .. T_Body : " " & <token>

      procedure Output_Sdep  (S : Sdep_Id);
      procedure Output_Unit  (Unit : GPR.Unit_Index; U : Unit_Id);
      procedure Output_With  (W : With_Id);
      --  Output this entry as a global section (like ALIs)

      ------------------
      -- Output_Afile --
      ------------------

      procedure Output_Afile (A : File_Name_Type) is
      begin
         Output_Token (T_Afile);
         Write_Name (Name_Id (A));
         Write_Eol;
      end Output_Afile;

      ----------------
      -- Output_ALI --
      ----------------

      procedure Output_ALI (FNS : File_Name_Source) is
         Src : constant GPR.Source_Id := FNS.Source;
         A : constant ALI_Id := FNS.The_ALI;

      begin
         Output_Token (T_ALI);
         N_Indents := N_Indents + 1;

         Output_Afile (FNS.Source.Dep_Name);
         Output_Ofile (FNS);
         Output_Sfile (FNS.Source);

         --  Output Main

         if ALIs.Table (A).Main_Program /= None then
            Output_Token (T_Main);

            Output_Token
              ((if ALIs.Table (A).Main_Program = Proc then T_Procedure
                else T_Function));

            Write_Eol;
         end if;

         --  Output Units

         for U in ALIs.Table (A).First_Unit .. ALIs.Table (A).Last_Unit loop
            Output_Unit (Src.Unit, U);
         end loop;

         --  Output Sdeps

         for S in ALIs.Table (A).First_Sdep .. ALIs.Table (A).Last_Sdep loop
            Output_Sdep (S);
         end loop;

         N_Indents := N_Indents - 1;
      end Output_ALI;

      -----------------
      -- Output_Name --
      -----------------

      procedure Output_Name (N : Name_Id) is
      begin
         --  Remove any encoding info (%s or %b)

         Get_Name_String (N);

         if Name_Len > 2
           and then Name_Buffer (Name_Len - 1) = '%'
         then
            Name_Len := Name_Len - 2;
         end if;

         Output_Token (T_Name);
         Write_Str (Name_Buffer (1 .. Name_Len));
         Write_Eol;
      end Output_Name;

      -------------------
      -- Output_No_ALI --
      -------------------

      procedure Output_No_ALI (FNS : File_Name_Source) is
      begin
         Output_Token (T_No_ALI);
         N_Indents := N_Indents + 1;
         Output_Afile (FNS.Source.Dep_Name);
         N_Indents := N_Indents - 1;
      end Output_No_ALI;

      ------------------
      -- Output_Ofile --
      ------------------

      procedure Output_Ofile (FNS : File_Name_Source) is
         Src : constant GPR.Source_Id := FNS.Source;
      begin
         if Src.Object_Path /= No_Path then
            Output_Token (T_Ofile);
            Write_Name (Name_Id (Src.Object_Path));
            Write_Eol;

         elsif Src.Object /= No_File then
            Output_Token (T_Ofile);
            Write_Name (Name_Id (Src.Object_Path));
            Write_Eol;
         end if;
      end Output_Ofile;

      -----------------
      -- Output_Sdep --
      -----------------

      procedure Output_Sdep (S : Sdep_Id) is
      begin
         Output_Token (T_Source);
         Write_Name (Sdep.Table (S).Sfile);
         Write_Eol;
      end Output_Sdep;

      ------------------
      -- Output_Sfile --
      ------------------

      procedure Output_Sfile (Src : GPR.Source_Id) is
      begin
         Output_Token (T_Sfile);
         Write_Name (Name_Id (Src.Path.Display_Name));
         Write_Eol;
      end Output_Sfile;

      procedure Output_Sfile (S : File_Name_Type) is
      begin
         Output_Token (T_Sfile);
         Write_Name (Name_Id (S));
         Write_Eol;
      end Output_Sfile;

      ------------------
      -- Output_Token --
      ------------------

      procedure Output_Token (T : Token_Type) is
      begin
         if T in T_No_ALI .. T_Flags then
            for J in 1 .. N_Indents loop
               Write_Str ("   ");
            end loop;

            Write_Str (Image (T).all);

            for J in Image (T)'Length .. 12 loop
               Write_Char (' ');
            end loop;

            Write_Str ("=>");

            if T in T_No_ALI .. T_With then
               Write_Eol;
            elsif T in T_Source .. T_Name then
               Write_Char (' ');
            end if;

         elsif T in T_Preelaborated .. T_Body then
            if T in T_Preelaborated .. T_Is_Generic then
               if N_Flags = 0 then
                  Output_Token (T_Flags);
               end if;

               N_Flags := N_Flags + 1;
            end if;

            Write_Char (' ');
            Write_Str  (Image (T).all);

         else
            Write_Str  (Image (T).all);
         end if;
      end Output_Token;

      -----------------
      -- Output_Unit --
      -----------------

      procedure Output_Unit (Unit : GPR.Unit_Index; U : Unit_Id) is
         UR : constant Unit_Record := Units.Table (U);

      begin
         Output_Token (T_Unit);
         N_Indents := N_Indents + 1;

         --  Output Name

         Output_Name (Unit.Name);

         --  Output Kind

         Output_Token (T_Kind);

         Output_Token
           ((if Units.Table (U).Unit_Kind = 'p' then T_Package
             else T_Subprogram));

         Get_Name_String (UR.Uname);

         if Name_Buffer (Name_Len) = 's' then
            Output_Token (T_Spec);
            Write_Eol;
            Output_Sfile (Unit.File_Names (Spec));

         elsif Unit.File_Names (Impl) /= No_Source then
            Output_Token (T_Body);
            Write_Eol;
            Output_Sfile (Unit.File_Names (Impl));

         elsif Unit.File_Names (Spec) /= No_Source then
            Output_Token (T_Body);
            Write_Eol;
            Output_Sfile (Unit.File_Names (Spec));
         end if;

         --  Output Flags

         N_Flags := 0;

         if Units.Table (U).Preelab then
            Output_Token (T_Preelaborated);
         end if;

         if Units.Table (U).Pure then
            Output_Token (T_Pure);
         end if;

         if Units.Table (U).Has_RACW then
            Output_Token (T_Has_RACW);
         end if;

         if Units.Table (U).Remote_Types then
            Output_Token (T_Remote_Types);
         end if;

         if Units.Table (U).Shared_Passive then
            Output_Token (T_Shared_Passive);
         end if;

         if Units.Table (U).RCI then
            Output_Token (T_RCI);
         end if;

         if Units.Table (U).Predefined then
            Output_Token (T_Predefined);
         end if;

         if Units.Table (U).Is_Generic then
            Output_Token (T_Is_Generic);
         end if;

         if N_Flags > 0 then
            Write_Eol;
         end if;

         --  Output Withs

         for W in Units.Table (U).First_With .. Units.Table (U).Last_With loop
            Output_With (W);
         end loop;

         N_Indents := N_Indents - 1;
      end Output_Unit;

      -----------------
      -- Output_With --
      -----------------

      procedure Output_With (W : With_Id) is
         Afile    : constant File_Name_Type := Withs.Table (W).Afile;
         Sfile    : File_Name_Type := Withs.Table (W).Sfile;
         Source_2 : GPR.Source_Id;

         Path : Path_Access := null;

      begin
         Output_Token (T_With);
         N_Indents := N_Indents + 1;

         Output_Name (Name_Id (Withs.Table (W).Uname));

         --  Output Kind

         Output_Token (T_Kind);

         Get_Name_String (Withs.Table (W).Uname);

         Output_Token
           ((if Name_Buffer (Name_Len) = 's' then T_Spec else T_Body));

         Write_Eol;

         if Afile /= No_File then
            Output_Afile (Afile);
         end if;

         if Sfile /= No_File then
            Source_2 := Source_Files_Htable.Get
              (Project_Tree.Source_Files_HT, Sfile);

            if Source_2 /= No_Source then
               Output_Sfile (Sfile);

            else
               if Runtime_Source_Dirs = No_Paths then
                  Get_All_Runtime_Source_Dirs
                    (GPR.Util.Main_Project, Project_Tree, Runtime_Source_Dirs);
               end if;

               Path := Runtime_Source_Dirs.First;

               declare
                  Fname : constant String := Get_Name_String (Sfile);

               begin
                  while Path /= null loop
                     Set_Name_Buffer (Path.Path.all);
                     Add_Char_To_Name_Buffer (Directory_Separator);
                     Add_Str_To_Name_Buffer (Fname);

                     if Is_Regular_File (Name_Buffer (1 .. Name_Len)) then
                        Sfile := Name_Find;
                        exit;
                     end if;

                     Path := Path.Next;
                  end loop;
               end;

               Output_Sfile (Sfile);
            end if;
         end if;

         N_Indents := N_Indents - 1;
      end Output_With;

   end GNATDIST;

end Gprls;

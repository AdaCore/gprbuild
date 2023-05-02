------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--          Copyright (C) 2012-2021, Free Software Foundation, Inc.         --
--                                                                          --
-- This library is free software;  you can redistribute it and/or modify it --
-- under terms of the  GNU General Public License  as published by the Free --
-- Software  Foundation;  either version 3,  or (at your  option) any later --
-- version. This library is distributed in the hope that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE.                            --
--                                                                          --
-- As a special exception under Section 7 of GPL version 3, you are granted --
-- additional permissions described in the GCC Runtime Library Exception,   --
-- version 3.1, as published by the Free Software Foundation.               --
--                                                                          --
-- You should have received a copy of the GNU General Public License and    --
-- a copy of the GCC Runtime Library Exception along with this program;     --
-- see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see    --
-- <http://www.gnu.org/licenses/>.                                          --
--                                                                          --
------------------------------------------------------------------------------

with Ada.Calendar;                use Ada.Calendar;
with Ada.Directories;             use Ada.Directories;
with Ada.Exceptions;              use Ada.Exceptions;
with Ada.Numerics.Float_Random;   use Ada.Numerics.Float_Random;
with Ada.Strings.Fixed;           use Ada.Strings.Fixed;
with Ada.Strings.Maps.Constants;  use Ada.Strings;
with Ada.Text_IO;                 use Ada.Text_IO;

with GNAT.Directory_Operations; use GNAT.Directory_Operations;
with GNAT.Sockets;              use GNAT; use GNAT.Sockets;
with GNAT.String_Split;         use GNAT.String_Split;

with GPR.Compilation.Process;
with GPR.Conf;
with GPR.Names;                     use GPR.Names;
with GPR.Opt;                       use GPR.Opt;
with GPR.Snames;                    use GPR.Snames;

package body GPR.Compilation.Slave is

   type Slave is record
      Sock          : Integer;
      Data          : Slave_Data;
      Channel       : Communication_Channel;
      Current       : Natural := 0;
      Max_Processes : Positive := 1;
      Root_Dir      : Unbounded_String;
      Rsync_Pid     : Process_Id;
   end record;

   function "<" (K1, K2 : Slave) return Boolean is (K1.Sock < K2.Sock);
   function "=" (K1, K2 : Slave) return Boolean is (K1.Sock = K2.Sock);

   No_Slave : constant Slave :=
                (-1, No_Slave_Data, Current => Natural'Last, others => <>);

   package Slave_S is new Containers.Ordered_Sets (Slave);
   --  The key is the C socket number

   function Connect_Slave
     (S_Data                     : Slave_Data;
      Project_Name               : String;
      Sync                       : Boolean;
      Included_Artifact_Patterns : String := "") return Slave;
   --  Connect to the slave and return the corresponding object

   function Parse (Host_Name : String) return Slave_Data;
   --  Parse a host[:port] string and returns corresponding Slave_Data record

   --  Ack transient signal stored into this variable

   protected Wait_Ack is
      procedure Set (Pid : Remote_Id);
      entry Get (Pid : out Remote_Id);
   private
      Is_Set : Boolean := False;
      Id     : Remote_Id;
   end Wait_Ack;

   task type Wait_Remote;
   --  Wait for incoming data from all registered slaves

   type Wait_Remote_Ref is access Wait_Remote;
   WR : Wait_Remote_Ref;
   --  Will be initialized only if the distributed mode is activated

   Compiler_Path : constant OS_Lib.String_Access :=
                     Locate_Exec_On_Path ("gnatls");

   Remote_Process : Shared_Counter;
   Slaves_Sockets : Socket_Set_Type;
   Max_Processes  : Natural := 0;

   R_Gen          : Generator;

   protected Slaves is

      procedure Insert (S : Slave);
      --  Add a slave into the pool

      function Find (Socket : Integer) return Slave;
      --  Find a slave given the socket number

      function Find (Host : String) return Slave;
      --  Find a slave give a host[:port] name

      function Get_Free return Slave;
      --  Returns a slave with free compilation slot

      function Count return Natural;
      --  Returns the number of registered slaves

      procedure Increment_Current (S : in out Slave);
      --  Increment the number of processes handled by slave

      procedure Decrement_Current (S : in out Slave);
      --  Decrement the number of processes handled by slave

      procedure Set_Rewrite_CD (S : in out Slave; Path : String);
      --  Record rewriting of the compiler directory

      procedure Set_Rewrite_WD (S : in out Slave; Path : String);
      --  Record rewriting of the wording directory

      procedure Iterate (Proc : access procedure (S : in out Slave));
      --  Iterate over all slaves in the pool and call proc

      procedure Clear;
      --  Clear the pool

   private
      Pool : Slave_S.Set;
   end Slaves;

   -------------
   -- Channel --
   -------------

   function Channel (Host : String) return Protocol.Communication_Channel is
      S : constant Slave := Slaves.Find (Host);
   begin
      return (if S = No_Slave then No_Channel else S.Channel);
   end Channel;

   ----------------------------
   -- Clean_Up_Remote_Slaves --
   ----------------------------

   procedure Clean_Up_Remote_Slaves
     (Tree    : Project_Tree_Ref;
      Project : Project_Id)
   is
      pragma Unreferenced (Tree);

      procedure Clean_Up_Remote_Slave
        (S_Data       : Slave_Data;
         Project_Name : String);
      --  Clean-up slave

      ---------------------------
      -- Clean_Up_Remote_Slave --
      ---------------------------

      procedure Clean_Up_Remote_Slave
        (S_Data       : Slave_Data;
         Project_Name : String)
      is
         S : Slave;

      begin
         S := Connect_Slave (S_Data, Project_Name, Sync => False);

         --  Send the clean-up request

         Protocol.Send_Clean_Up (S.Channel, Project_Name);

         declare
            Cmd : constant Command := Get_Command (S.Channel);
         begin
            if Kind (Cmd) = OK then
               if Opt.Verbosity_Level > Opt.Low then
                  Put_Line
                    ("Clean-up done on " & To_String (S_Data.Host));
               end if;

            elsif Kind (Cmd) = KO then
               Put_Line ("Slave cannot clean-up " & To_String (S_Data.Host));
               OS_Exit (1);

            else
               Put_Line
                 ("protocol error: " & Command_Kind'Image (Kind (Cmd)));
               OS_Exit (1);
            end if;
         end;

         Protocol.Send_End_Of_Compilation (S.Channel);

         --  Wait for acknowledge to ensure the clean-up is terminated on the
         --  slave.

         declare
            Cmd : constant Command :=
                    Get_Command (S.Channel) with Unreferenced;
         begin
            null;
         end;

         Close (S.Channel);

      exception
         when others =>
            Close (S.Channel);
      end Clean_Up_Remote_Slave;

   begin
      for S of Slaves_Data loop
         Clean_Up_Remote_Slave (S, Get_Name_String (Project.Name));
      end loop;
   end Clean_Up_Remote_Slaves;

   -------------------
   -- Connect_Slave --
   -------------------

   function Connect_Slave
     (S_Data                     : Slave_Data;
      Project_Name               : String;
      Sync                       : Boolean;
      Included_Artifact_Patterns : String := "") return Slave
   is
      Address : Sock_Addr_Type;
      Sock    : Socket_Type;
      S       : Slave;
      Status  : Selector_Status;

   begin
      S.Data := S_Data;

      if S.Data.Host = Null_Unbounded_String then
         Put_Line ("A slave must have a name, aborting");
         OS_Exit (1);
      end if;

      Address.Addr := Addresses
        (Get_Host_By_Name (To_String (S.Data.Host)), 1);
      Address.Port := S_Data.Port;

      Create_Socket (Sock);
      Set_Socket_Option (Sock, Socket_Level, (Reuse_Address, True));

      begin
         Connect_Socket (Sock, Address, Timeout => 2.0, Status => Status);
      exception
         when Socket_Error =>
            Put_Line
              ("Cannot connect to slave "
               & To_String (S.Data.Host) & ", aborting");
            raise;
      end;

      if Status in Expired .. Aborted then
         Put_Line
           ("Cannot connect to slave "
            & To_String (S.Data.Host) & ", aborting");
         OS_Exit (1);
      end if;

      S.Channel := Create (Sock);

      --  Do initial handshake

      Protocol.Send_Context
        (S.Channel, Get_Target, Project_Name, Slave_Env.all, Sync,
         (if Hash_Value = null then "" else Hash_Value.all),
         Included_Artifact_Patterns);

      declare
         Cmd        : constant Command := Get_Command (S.Channel);
         Parameters : constant Argument_List_Access := Args (Cmd);
      begin
         if Kind (Cmd) = OK and then Parameters'Length = 3 then
            S.Max_Processes := Natural'Value (Parameters (1).all);
            S.Root_Dir := To_Unbounded_String (Parameters (2).all);

            if not Boolean'Value (Parameters (3).all) then
               Put_Line
                 ("warning: non synchronized clock detected for "
                  & To_String (S.Data.Host));
            end if;

         elsif Kind (Cmd) = KO then
            Put_Line
              ((if Parameters'Length = 1 and then Parameters (1).all /= ""
               then Parameters (1).all
               else "build slave is not compatible")
               & " : " & To_String (S.Data.Host));

            OS_Exit (1);

         else
            Put_Line ("protocol error: " & Command_Kind'Image (Kind (Cmd)));
            OS_Exit (1);
         end if;
      end;

      return S;
   end Connect_Slave;

   -----------------------
   -- Get_Max_Processes --
   -----------------------

   function Get_Max_Processes return Natural is
   begin
      return Max_Processes;
   end Get_Max_Processes;

   -----------
   -- Parse --
   -----------

   function Parse (Host_Name : String) return Slave_Data is
      V    : String renames Host_Name;
      I    : constant Natural := Index (V, ":");
      Host : Unbounded_String;
      Port : Port_Type := Default_Port;
   begin
      --  Get for port

      if I = 0 then
         Host := To_Unbounded_String (V (V'First .. V'Last));

      else
         Host := To_Unbounded_String (V (V'First .. I - 1));

         declare
            Port_Str : constant String := V (I + 1 .. V'Last);
         begin
            if Strings.Maps.Is_Subset
              (Maps.To_Set (Port_Str),
               Maps.Constants.Decimal_Digit_Set)
            then
               Port := Port_Type'Value (V (I + 1 .. V'Last));
            else
               return No_Slave_Data;
            end if;
         end;
      end if;

      return Slave_Data'(Host, Port);
   end Parse;

   -------------------
   -- Record_Slaves --
   -------------------

   procedure Record_Slaves (Option : String) is

      S : Slice_Set;

      procedure Parse_Build_Slave (V : String);
      --  Parse the build slave V

      -----------------------
      -- Parse_Build_Slave --
      -----------------------

      procedure Parse_Build_Slave (V : String) is
         S_Data : constant Slave_Data := Parse (V);
      begin
         if S_Data = No_Slave_Data then
            Put_Line ("error: invalid port value in " & V);
            OS_Exit (1);
         else
            Slaves_Data.Append (S_Data);
         end if;
      end Parse_Build_Slave;

   begin
      Create (S, Option, ",");

      for K in 1 .. Slice_Count (S) loop
         Parse_Build_Slave (Slice (S, K));
      end loop;
   end Record_Slaves;

   ---------------------------
   -- Register_Remote_Slave --
   ---------------------------

   procedure Register_Remote_Slave
     (S_Data                     : Slave_Data;
      Project_Name               : String;
      Excluded_Patterns          : Sync.Str_Vect.Vector;
      Included_Patterns          : Sync.Str_Vect.Vector;
      Included_Artifact_Patterns : Sync.Str_Vect.Vector;
      Synchronize                : Boolean)
   is
      S   : Slave;
      IAP : Unbounded_String;

   begin
      for P of Included_Artifact_Patterns loop
         if IAP /= Null_Unbounded_String then
            Append (IAP, ";");
         end if;
         Append (IAP, P);
      end loop;

      S := Connect_Slave
        (S_Data, Project_Name,
         Sync                       => Synchronize,
         Included_Artifact_Patterns => To_String (IAP));

      Set (Slaves_Sockets, Sock (S.Channel));

      --  Sum the Max_Process values

      Max_Processes := Max_Processes + S.Max_Processes;

      if Opt.Verbosity_Level > Opt.Low then
         Put ("Register slave " & To_String (S_Data.Host) & ",");
         Put (Integer'Image (S.Max_Processes));
         Put_Line (" process(es)");
         Put_Line ("  location: " & To_String (S.Root_Dir));
      end if;

      --  Let's double check that Root_Dir and Projet_Name are not empty,
      --  this is a safety check to avoid rsync destroying remote environment
      --  as rsync is using the --delete options.

      if Length (S.Root_Dir) = 0 then
         Put_Line ("error: Root_Dir cannot be empty");
         OS_Exit (1);
      end if;

      if Project_Name = "" then
         Put_Line ("error: Project_Name cannot be empty");
         OS_Exit (1);
      end if;

      if Synchronize then
         Compilation.Sync.Send_Files
           (Channel           => S.Channel,
            Root_Dir          => To_String (Root_Dir),
            Included_Patterns => Included_Patterns,
            Excluded_Patterns => Excluded_Patterns,
            Mode              => Sync.To_Slave);
      end if;

      --  Now that all slave's data is known and set, record it

      S.Sock := To_C (Sock (S.Channel));

      Slaves.Insert (S);

   exception
      when Host_Error =>
         raise Constraint_Error
           with "cannot connect to " & To_String (S_Data.Host);
   end Register_Remote_Slave;

   ----------------------------
   -- Register_Remote_Slaves --
   ----------------------------

   procedure Register_Remote_Slaves
     (Tree    : Project_Tree_Ref;
      Project : Project_Id)
   is
      use type Containers.Count_Type;

      Start, Stop : Calendar.Time;

      procedure Insert
        (V      : out Sync.Str_Vect.Vector;
         Values : String_List_Id);
      --  Inserts all values into the vector

      Excluded_Patterns          : Sync.Str_Vect.Vector;
      Included_Patterns          : Sync.Str_Vect.Vector;
      Included_Artifact_Patterns : Sync.Str_Vect.Vector;

      ------------
      -- Insert --
      ------------

      procedure Insert
        (V      : out Sync.Str_Vect.Vector;
         Values : String_List_Id)
      is
         Idx : String_List_Id := Values;
      begin
         while Idx /= Nil_String loop
            declare
               Item : constant String_Element :=
                        Tree.Shared.String_Elements.Table (Idx);
            begin
               V.Append (Get_Name_String (Item.Value));
               Idx := Item.Next;
            end;
         end loop;
      end Insert;

      Pcks : Package_Table.Table_Ptr renames Tree.Shared.Packages.Table;
      Pck  : Package_Id := Project.Decl.Packages;

   begin
      Root_Dir := To_Unbounded_String
        (Containing_Directory (Get_Name_String (Project.Path.Display_Name)));

      --  Check for Root_Dir attribute and Excluded_Patterns

      Look_Remote_Package : while Pck /= No_Package loop
         if Pcks (Pck).Decl /= No_Declarations
           and then Pcks (Pck).Name = Name_Remote
         then
            declare
               Id : Variable_Id := Pcks (Pck).Decl.Attributes;
            begin
               while Id /= No_Variable loop
                  declare
                     V : constant Variable :=
                           Tree.Shared.Variable_Elements.Table (Id);
                  begin
                     if not V.Value.Default then
                        if V.Name = Name_Root_Dir then
                           declare
                              RD : constant String :=
                                     Get_Name_String (V.Value.Value);
                           begin
                              Root_Dir :=
                                (if Is_Absolute_Path (RD) then
                                   To_Unbounded_String (RD)
                                 else To_Unbounded_String
                                     (Normalize_Pathname
                                        (To_String (Root_Dir) &
                                         Directory_Separator & RD)));

                              if not Exists (To_String (Root_Dir))
                                or else not Is_Directory (To_String (Root_Dir))
                              then
                                 Put_Line
                                   ("error: " & To_String (Root_Dir)
                                    & " is not a directory"
                                    & " or does not exist");
                                 OS_Exit (1);

                              else
                                 Put_Line
                                   ("root dir : " & To_String (Root_Dir));
                              end if;
                           end;

                        elsif V.Name = Name_Excluded_Patterns then
                           Insert (Excluded_Patterns, V.Value.Values);

                        elsif V.Name = Name_Included_Patterns then
                           Insert (Included_Patterns, V.Value.Values);

                        elsif V.Name = Name_Included_Artifact_Patterns then
                           Insert (Included_Artifact_Patterns, V.Value.Values);
                        end if;
                     end if;
                  end;

                  Id := Tree.Shared.Variable_Elements.Table (Id).Next;
               end loop;
            end;
         end if;

         Pck := Pcks (Pck).Next;
      end loop Look_Remote_Package;

      --  Check if Excluded_Patterns and Included_Patterns are set

      if Included_Patterns.Length /= 0
        and then Excluded_Patterns.Length /= 0
      then
         Put_Line
           ("error: Excluded_Patterns and Included_Patterns are exclusive");
         OS_Exit (1);
      end if;

      --  Then registers the build slaves

      Start := Calendar.Clock;

      for S of Slaves_Data loop
         Register_Remote_Slave
           (S,
            Get_Name_String (Project.Name),
            Excluded_Patterns,
            Included_Patterns,
            Included_Artifact_Patterns,
            True);
      end loop;

      Sync.Wait;

      Stop := Calendar.Clock;

      if Opt.Verbosity_Level > Opt.Low then
         Put ("  All data synchronized in ");
         Put (Duration'Image (Stop - Start));
         Put_Line (" seconds");
      end if;

      --  We are in remote mode, the initialization was successful, start tasks
      --  now.

      Start_Waiting_Task;
   end Register_Remote_Slaves;

   ---------
   -- Run --
   ---------

   function Run
     (Project  : Project_Id;
      Language : String;
      Options  : String_Vectors.Vector;
      Obj_Name : String;
      Dep_Name : String := "";
      Env      : String := "") return GPR.Compilation.Id
   is
      RD  : constant String := To_String (Root_Dir);

      S   : Slave := Slaves.Get_Free;
      --  Get a free slave for conducting the compilation

      function Filter_String
        (O : String; Sep : String := WD_Path_Tag) return String;
      --  Make O PATH relative to RD. For option -gnatec and -gnatem makes
      --  the specified filename absolute in the slave environment and send
      --  the file to the slave.

      -------------------
      -- Filter_String --
      -------------------

      function Filter_String
        (O   : String;
         Sep : String := WD_Path_Tag) return String
      is
         Pos : constant Natural := Index (O, RD);
      begin
         if Pos = 0 then
            return O;

         else
            --  Note that we transfer files only when they are under the
            --  project root.

            if O'Length > 8
              and then O (O'First .. O'First + 7) in "-gnatem=" | "-gnatec="
            then
               --  Send the corresponding file to the slave
               declare
                  File_Name : constant String := O (O'First + 8 .. O'Last);
               begin
                  if Exists (File_Name) then
                     Send_File
                       (S.Channel, File_Name,
                        Rewrite         => True,
                        Keep_Time_Stamp => True);

                  else
                     Put_Line
                       ("File not found " & File_Name);
                     Put_Line
                       ("Please check that Built_Root is properly set");
                  end if;

                  return O (O'First .. O'First + 7)
                    & Translate_Send (S.Channel, File_Name);
               end;

            elsif O'Length > 7
              and then O (O'First .. O'First + 6) = "-specs="
            then
               --  Send the corresponding file to the slave
               declare
                  File_Name : constant String := O (O'First + 7 .. O'Last);
                  File      : Text_IO.File_Type;
                  Line      : String (1 .. 2_048);
                  Last      : Natural;
               begin
                  if Exists (File_Name) then
                     Send_File
                       (S.Channel, File_Name,
                        Rewrite         => True,
                        Keep_Time_Stamp => True);

                     --  And now send the spec filename in the second line

                     Text_IO.Open (File, Text_IO.In_File, File_Name);
                     Text_IO.Skip_Line (File);
                     Text_IO.Get_Line (File, Line, Last);
                     Text_IO.Close (File);

                     --  A spec filename starts with '+ @', so 3 characters

                     declare
                        Filename_Offset : constant := 3;
                        Spec_Filename   : constant String :=
                                            Line (1 + Filename_Offset .. Last);
                     begin
                        if Exists (Spec_Filename) then
                           Send_File
                             (S.Channel, Spec_Filename,
                              Rewrite         => True,
                              Keep_Time_Stamp => True);
                        else
                           Put_Line
                             ("Spec file not found " & Spec_Filename);
                           Put_Line
                             ("Please check that Built_Root is properly set");
                        end if;
                     end;

                  else
                     Put_Line
                       ("File not found " & File_Name);
                     Put_Line
                       ("Please check that Built_Root is properly set");
                  end if;

                  return O (O'First .. O'First + 6)
                    & Translate_Send (S.Channel, File_Name);
               end;
            end if;

            return O (O'First .. Pos - 1)
              & Sep & Filter_String (O (Pos + RD'Length + 1 .. O'Last));
         end if;
      end Filter_String;

      Lang_Id : constant Name_Id := Get_Name_Id (Language);
      Pid     : Remote_Id;

   begin
      --  Record the rewrite information for this channel

      Slaves.Set_Rewrite_WD (S, Path => RD);

      if Compiler_Path /= null then
         Slaves.Set_Rewrite_CD
           (S,
            Path => Containing_Directory
              (Containing_Directory (Compiler_Path.all)));
      end if;

      Send_Exec
        (S.Channel,
         Get_Name_String (Project.Path.Display_Name),
         Filter_String (Get_Current_Dir, Sep => ""),
         Language, Opt.Target_Value.all, Conf.Runtime_Name_For (Lang_Id),
         Options, Obj_Name, Dep_Name, Env,
         Filter_String'Access);

      Remote_Process.Increment;

      --  Wait for the Ack from the remote host, this is set by the Wait_Remote
      --  task.

      Wait_Ack.Get (Pid);

      return Process.Create_Remote (Pid);

   exception
      when E : others =>
         Put_Line ("Unexpected exception: " & Exception_Information (E));
         OS_Exit (1);
   end Run;

   ------------
   -- Slaves --
   ------------

   protected body Slaves is

      --------------------
      -- Change_Current --
      --------------------

      procedure Change_Current (S : in out Slave; Value : Integer) is
         Position : constant Slave_S.Cursor := Pool.Find (S);
      begin
         Pool (Position).Current := Pool (Position).Current + Value;
      end Change_Current;

      -----------
      -- Clear --
      -----------

      procedure Clear is
      begin
         Pool.Clear;
      end Clear;

      -----------
      -- Count --
      -----------

      function Count return Natural is
      begin
         return Natural (Pool.Length);
      end Count;

      -----------------------
      -- Decrement_Current --
      -----------------------

      procedure Decrement_Current (S : in out Slave) is
      begin
         Change_Current (S, -1);
      end Decrement_Current;

      ----------
      -- Find --
      ----------

      function Find (Socket : Integer) return Slave is
         S        : constant Slave := (Sock => Socket, others => <>);
         Position : constant Slave_S.Cursor := Pool.Find (S);
      begin
         return
           (if Slave_S.Has_Element (Position) then Slave_S.Element (Position)
            else No_Slave);
      end Find;

      function Find (Host : String) return Slave is
         S_Data : constant Slave_Data := Parse (Host);
      begin
         for S of Pool loop
            if S.Data = S_Data then
               return S;
            end if;
         end loop;

         return No_Slave;
      end Find;

      --------------
      -- Get_Free --
      --------------

      function Get_Free return Slave is
         use type Containers.Count_Type;
         S_Count : constant Containers.Count_Type := Pool.Length;
         Index   : constant Positive :=
                     Natural (Float (S_Count - 1) * Random (R_Gen)) + 1;
         --  Index of the slave to return if available
         Result  : Slave := No_Slave;
         K       : Positive := 1;
      begin
         --  We want to have a random pick of one slave

         Search_Slaves : for S of Pool loop
            if S.Current < S.Max_Processes then
               Result := S;

               --  Slave is ready and this is the one picked-up randomly, stop
               --  searching now.

               exit Search_Slaves when K = Index;
            end if;
            K := K + 1;

            --  We are past the random slave and we have found one slave ready,
            --  stop search here.

            exit Search_Slaves when K > Index and Result /= No_Slave;
         end loop Search_Slaves;

         return Result;
      end Get_Free;

      -----------------------
      -- Increment_Current --
      -----------------------

      procedure Increment_Current (S : in out Slave) is
      begin
         Change_Current (S, 1);
      end Increment_Current;

      ------------
      -- Insert --
      ------------

      procedure Insert (S : Slave) is
      begin
         Pool.Insert (S);
      end Insert;

      -------------
      -- Iterate --
      -------------

      procedure Iterate (Proc : access procedure (S : in out Slave)) is
      begin
         for C in Pool.Iterate loop
            declare
               S : Slave := Slave_S.Element (C);
            begin
               Proc (S);
               Pool.Replace_Element (C, S);
            end;
         end loop;
      end Iterate;

      --------------------
      -- Set_Rewrite_CD --
      --------------------

      procedure Set_Rewrite_CD (S : in out Slave; Path : String) is
         Position : constant Slave_S.Cursor := Pool.Find (S);
      begin
         Set_Rewrite_CD (Pool (Position).Channel, Path => Path);
         S := Pool (Position);
      end Set_Rewrite_CD;

      --------------------
      -- Set_Rewrite_WD --
      --------------------

      procedure Set_Rewrite_WD (S : in out Slave; Path : String) is
         Position : constant Slave_S.Cursor := Pool.Find (S);
      begin
         Set_Rewrite_WD (Pool (Position).Channel, Path => Path);
         S := Pool (Position);
      end Set_Rewrite_WD;

   end Slaves;

   ------------------------
   -- Start_Waiting_Task --
   ------------------------

   procedure Start_Waiting_Task is
   begin
      if WR = null then
         WR := new Wait_Remote;
      end if;
   end Start_Waiting_Task;

   ------------------------------
   -- Unregister_Remote_Slaves --
   ------------------------------

   procedure Unregister_Remote_Slaves (From_Signal : Boolean := False) is

      procedure Unregister (S : in out Slave);
      --  Unregister given slave

      Start, Stop : Time;

      ----------------
      -- Unregister --
      ----------------

      procedure Unregister (S : in out Slave) is
      begin
         if not From_Signal then
            Send_End_Of_Compilation (S.Channel);

            --  Wait for acknowledge to ensure the clean-up is terminated on
            --  on the slave.

            declare
               Cmd : constant Command :=
                       Get_Command (S.Channel) with Unreferenced;
            begin
               null;
            end;
         end if;

         Close (S.Channel);
      exception
         when others =>
            Close (S.Channel);
      end Unregister;

   begin
      Start := Clock;

      Slaves.Iterate (Unregister'Access);

      if not From_Signal then
         Sync.Wait;
      end if;

      Stop := Clock;

      if not From_Signal
        and then Opt.Verbosity_Level > Opt.Low
        and then Slaves.Count > 0
      then
         Put ("  All data synchronized in ");
         Put (Duration'Image (Stop - Start));
         Put_Line (" seconds");
      end if;

      Slaves.Clear;
   end Unregister_Remote_Slaves;

   --------------
   -- Wait_Ack --
   --------------

   protected body Wait_Ack is

      ---------
      -- Set --
      ---------

      procedure Set (Pid : Remote_Id) is
      begin
         Id := Pid;
         Is_Set := True;
      end Set;

      ---------
      -- Get --
      ---------

      entry Get (Pid : out Remote_Id) when Is_Set is
      begin
         Pid := Id;
         Is_Set := False;
      end Get;

   end Wait_Ack;

   -----------------
   -- Wait_Remote --
   -----------------

   task body Wait_Remote is
      Proc         : Id;
      Pid          : Remote_Id;
      Selector     : Selector_Type;
      Status       : Selector_Status;
      R_Set, W_Set : Socket_Set_Type;
      Sock         : Socket_Type;
      S            : Slave;
   begin
      --  In this task we are only interested by the incoming data, so we do
      --  not wait on socket ready for writing.

      Sockets.Empty (W_Set);

      Create_Selector (Selector);

      loop
         --  Let's wait for at least some process to monitor

         Remote_Process.Wait_Non_Zero;

         --  Wait for response from all registered slaves

         Copy (Slaves_Sockets, R_Set);

         Check_Selector (Selector, R_Set, W_Set, Status);

         if Status = Completed then
            Get (R_Set, Sock);

            pragma Assert
              (Sock /= No_Socket, "no socket returned by selector");

            S := Slaves.Find (To_C (Sock));

            if S /= No_Slave then
               declare
                  Cmd     : constant Command := Get_Command (S.Channel);
                  Success : Boolean;
               begin
                  --  A display output

                  if Kind (Cmd) = DP then
                     --  Write output to the console

                     Put (To_String (Protocol.Output (Cmd)));

                     Get_Pid (S.Channel, Pid, Success);

                     Proc := Process.Create_Remote (Pid);

                     Remote_Process.Decrement;
                     Slaves.Decrement_Current (S);

                     Process.Add_Result
                       (Proc, Success, To_String (S.Data.Host));

                  --  An acknowledgment of an compilation job

                  elsif Kind (Cmd) = AK then
                     declare
                        Pid : constant Remote_Id :=
                                Remote_Id'Value (Args (Cmd)(1).all);
                     begin
                        Slaves.Increment_Current (S);
                        Wait_Ack.Set (Pid);
                     end;

                  elsif Kind (Cmd) in EC | SI then
                     null;

                  else
                     raise Constraint_Error with "Unexpected command: "
                       & Command_Kind'Image (Kind (Cmd));
                  end if;
               end;
            end if;

         else
            if Opt.Verbosity_Level = Opt.High then
               Put_Line
                 ("warning: selector in " & Selector_Status'Image (Status)
                  & " state");
            end if;
         end if;

         Sockets.Empty (R_Set);
      end loop;
   exception
      when E : others =>
         Put_Line (Exception_Information (E));
         OS_Exit (1);
   end Wait_Remote;

end GPR.Compilation.Slave;

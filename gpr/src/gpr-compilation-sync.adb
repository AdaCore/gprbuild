------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--          Copyright (C) 2014-2020, Free Software Foundation, Inc.         --
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

with Ada.Containers.Vectors;
with Ada.Directories;         use Ada.Directories;
with Ada.Exceptions;          use Ada.Exceptions;
with Ada.Strings.Unbounded;   use Ada.Strings.Unbounded;
with Ada.Text_IO;             use Ada.Text_IO;

with GNAT.Regexp;  use GNAT.Regexp;
with GNAT.Sockets; use GNAT.Sockets;

with GPR.Util; use GPR.Util;

package body GPR.Compilation.Sync is

   use Ada;
   use type Containers.Count_Type;

   Common_Excluded_Patterns : Str_Vect.Vector;
   --  Default excluded patterns to use when in excluded mode as opposed to
   --  include mode where we describe the patterns to include specifically.

   Artifact_Excluded_Patterns : Str_Vect.Vector;
   --  Artifacts patterns to exclude

   Max_Gpr_Sync : constant := 10;
   --  The number of parallele synchronization done for the gpr protocol. This
   --  is currenlty fixed to 6 but could probable be a parameter. The number is
   --  high, as these tasks are mostly doing IO and so are not CPU demanding,
   --  the goal is to saturate the network bandwidth.

   --  Data for each synchronization job for the Gpr protocol

   type Gpr_Data is record
      Channel           : Protocol.Communication_Channel;
      Root_Dir          : Unbounded_String;
      Excluded_Patterns : Str_Vect.Vector;
      Included_Patterns : Str_Vect.Vector;
   end record;

   package Gpr_Data_Set is new Containers.Vectors (Positive, Gpr_Data);

   --  Queue of job to be done for the gpr protocol

   protected Gpr_Queue is

      procedure Add (Job : Gpr_Data);
      --  Add a new synchronization job

      entry Get
        (Job   : out Gpr_Data;
         Files : out File_Data_Set.Vector;
         Stop  : out Boolean);
      --  Get a synchronization job with the corresponding files, Stop is set
      --  to True if there is no more job to handle and False otherwise.

      procedure No_More_Job;

   private
      procedure Set_Project_Files (Job : Gpr_Data);
      --  Set the project files to be synchronized

      Jobs           : Gpr_Data_Set.Vector;
      Project_Files  : File_Data_Set.Vector;
      PF_Initialized : Boolean := False;
      No_More        : Boolean := False;
   end Gpr_Queue;

   --  Synchronization job are handled by the Gpr_Sync tasks

   task type Gpr_Sync is
      entry Stop;
   end Gpr_Sync;

   type Gpr_Sync_Tasks is array (1 .. Max_Gpr_Sync) of Gpr_Sync;
   type Sync_Tasks_Ref is access all Gpr_Sync_Tasks;

   Sync_Tasks : Sync_Tasks_Ref;
   --  Only allocated (and so started) if a some slaves are using the gpr
   --  protocol. Otherwise this variable will stay null.

   ---------------
   -- Gpr_Queue --
   ---------------

   protected body Gpr_Queue is

      ---------
      -- Add --
      ---------

      procedure Add (Job : Gpr_Data) is
      begin
         Jobs.Append (Job);
      end Add;

      ---------
      -- Get --
      ---------

      entry Get
        (Job   : out Gpr_Data;
         Files : out File_Data_Set.Vector;
         Stop  : out Boolean) when Jobs.Length > 0 or No_More is
      begin
         if Jobs.Length = 0 and then No_More then
            Stop := True;

         else
            Stop := False;
            Job := Jobs.First_Element;
            Jobs.Delete_First;

            if not PF_Initialized then
               Set_Project_Files (Job);
            end if;

            Files := Project_Files;
         end if;
      end Get;

      -----------------
      -- No_More_Job --
      -----------------

      procedure No_More_Job is
      begin
         No_More := True;
      end No_More_Job;

      -----------------------
      -- Set_Project_Files --
      -----------------------

      procedure Set_Project_Files (Job : Gpr_Data) is

         Root_Dir : constant String :=
                      (if Job.Root_Dir = Null_Unbounded_String
                       then "." else To_String (Job.Root_Dir));

         type Regexp_Set is array (Containers.Count_Type range <>) of Regexp;

         I_Regexp : Regexp_Set (1 .. Job.Included_Patterns.Length);
         E_Regexp : Regexp_Set (1 .. Job.Excluded_Patterns.Length);

         procedure Process (Prefix : String);

         -------------
         -- Process --
         -------------

         procedure Process (Prefix : String) is

            procedure Check (File : Directory_Entry_Type);
            --  Check and add this file if it passes the filters

            -----------
            -- Check --
            -----------

            procedure Check (File : Directory_Entry_Type) is
               use GNAT;

               function Match
                 (Name : String; R_Set : Regexp_Set)
                  return Boolean with Inline;
               --  Returns true if Name is matched by one of the regexp in
               --  R_Set.

               -----------
               -- Match --
               -----------

               function Match
                 (Name : String; R_Set : Regexp_Set) return Boolean is
               begin
                  return (for some Regexp of R_Set => Match (Name, Regexp));
               end Match;

               S_Name     : constant String := Simple_Name (File);
               Entry_Name : constant String := Prefix & S_Name;
               Is_File    : Boolean;

            begin
               if Kind (File) = Directory then
                  if S_Name not in "." | ".."
                    and then (I_Regexp'Length /= 0
                              or else not Match (S_Name, E_Regexp))
                    and then not Is_Symbolic_Link
                      (Root_Dir & Directory_Separator & Entry_Name)
                  then
                     Process (Entry_Name & Directory_Separator);
                  end if;

               else
                  if I_Regexp'Length = 0 then
                     if Match (S_Name, E_Regexp) then
                        Is_File := False;
                     else
                        Is_File := True;
                     end if;

                  else
                     if Match (S_Name, I_Regexp) then
                        Is_File := True;
                     else
                        Is_File := False;
                     end if;
                  end if;

                  if Is_File then
                     Project_Files.Append
                       (File_Data'
                          (To_Unbounded_String (Entry_Name),
                           To_UTC_Time_Stamp (Modification_Time (File)),
                           OS_Lib.Is_Executable_File
                             (Root_Dir & Directory_Separator & Entry_Name)));
                  end if;
               end if;
            end Check;

         begin
            Search
              (Directory =>
                 Root_Dir
                 & (if Prefix = "" then "" else Directory_Separator & Prefix),
               Pattern   => "*",
               Filter    => (Special_File => False, others => True),
               Process   => Check'Access);
         end Process;

      begin
         --  Compile the patterns

         declare
            K : Containers.Count_Type := 1;
         begin
            for P of Job.Included_Patterns loop
               I_Regexp (K) := Compile (P, Glob => True);
               K := K + 1;
            end loop;

            K := 1;

            for P of Job.Excluded_Patterns loop
               E_Regexp (K) := Compile (P, Glob => True);
               K := K + 1;
            end loop;
         end;

         --  Check the files under the project root

         Process (Prefix => "");

         PF_Initialized := True;
      end Set_Project_Files;

   end Gpr_Queue;

   --------------
   -- Gpr_Sync --
   --------------

   task body Gpr_Sync is
      Job         : Gpr_Data;
      Files       : File_Data_Set.Vector;
      No_More_Job : Boolean;
   begin
      For_Slave : loop
         --  Get a new job and the associated files if any

         Gpr_Queue.Get (Job, Files, No_More_Job);

         exit For_Slave when No_More_Job;

         declare
            Chunk_Size : constant := 250;
            --  This constant controls the number of files sent with the sync
            --  command. Doing one at a time is really time consumming as
            --  we have for every file and send and a receive command on
            --  the socket.

            F_List     : File_Data_Set.Vector;
            Count      : Natural := 0;

         begin
            --  Synchronize each file in the list we got

            for F of Files loop
               if Count = Chunk_Size then
                  Protocol.Sync_Files
                    (Job.Channel, To_String (Job.Root_Dir), F_List);

                  F_List.Clear;
                  Count := 0;
               end if;

               F_List.Append (F);
               Count := Count + 1;
            end loop;

            --  Then send the last chunk if any

            if Count /= 0 then
               Protocol.Sync_Files
                 (Job.Channel, To_String (Job.Root_Dir), F_List);
            end if;

            Protocol.Send_End_Of_File_List (Job.Channel);
         end;
      end loop For_Slave;

      accept Stop;

   exception
      when Socket_Error =>
         accept Stop;
      when E : others =>
         Put_Line (Exception_Information (E));
         OS_Exit (1);
   end Gpr_Sync;

   -------------------
   -- Receive_Files --
   -------------------

   function Receive_Files
     (Channel           : Protocol.Communication_Channel;
      Root_Dir          : String;
      Total_File        : out Natural;
      Total_Transferred : out Natural;
      Remote_Files      : out Files.Set;
      Is_Debug          : Boolean;
      Display           : access procedure (Message : String))
      return Protocol.Command_Kind
   is
      use GPR.Compilation.Protocol;
   begin
      Total_File := 0;
      Total_Transferred := 0;

      loop
         declare
            Cmd     : constant Command := Get_Command (Channel);
            To_Sync : File_Data_Set.Vector;
            K       : Positive := 1;
            Message : Unbounded_String;
         begin
            if Is_Debug then
               Message := To_Unbounded_String
                 ("command: " & Command_Kind'Image (Kind (Cmd)));

               if Args (Cmd) /= null then
                  for K in Args (Cmd)'Range loop
                     Append (Message, ", " & Args (Cmd) (K).all);
                  end loop;
               end if;

               Display (To_String (Message));
            end if;

            if Kind (Cmd) = TS then
               --  Check all files in the argument of the command. This is a
               --  list of couple (filename and time stamp).

               Check_All_Files : loop
                  Total_File := Total_File + 1;

                  declare
                     Path_Name     : constant String :=
                                       To_Native_Directory_Separator
                                         (Args (Cmd) (K).all);
                     Full_Path     : constant String :=
                                       Root_Dir & Directory_Separator
                                       & Path_Name;
                     TS            : constant Time_Stamp_Type :=
                                       Time_Stamp_Type
                                         (Args (Cmd) (K + 1).all);
                     Is_Executable : constant Boolean :=
                                       Boolean'Value (Args (Cmd) (K + 2).all);
                     File_Stamp    : Time_Stamp_Type;
                     Exists        : Boolean;
                  begin
                     if Ada.Directories.Exists (Full_Path) then
                        File_Stamp :=
                          To_UTC_Time_Stamp (Modification_Time (Full_Path));
                        Exists := True;
                     else
                        Exists := False;
                     end if;

                     Remote_Files.Insert (Full_Path);

                     if not Exists or else File_Stamp /= TS then
                        To_Sync.Append
                          (File_Data'
                             (To_Unbounded_String (Path_Name),
                              TS, Is_Executable));
                     end if;
                  end;

                  K := K + 3;
                  exit Check_All_Files when K > Args (Cmd)'Length;
               end loop Check_All_Files;

               --  If all files are up-to-data

               if To_Sync.Length = 0 then
                  Send_Ok (Channel);

               else
                  --  Some files are to be synchronized, send the list of
                  --  names back to the master.

                  Send_Ko (Channel, To_Sync);

                  --  We then receive the files contents in the same order

                  Get_RAW_Data : declare
                     Max : constant String :=
                             Containers.Count_Type'Image (To_Sync.Length);
                     N   : Natural := 0;
                  begin
                     for W of To_Sync loop
                        declare
                           Full_Path : constant String :=
                                         Root_Dir & Directory_Separator
                                         & To_String (W.Path_Name);
                        begin
                           Create_Path (Containing_Directory (Full_Path));

                           Get_RAW_File_Content
                             (Channel, Full_Path, W.Timestamp);

                           --  And mark file executable if needed

                           if W.Is_Executable then
                              GNAT.OS_Lib.Set_Executable (Full_Path);
                           end if;

                        exception
                           when others =>
                              Display
                                ("failed to create file: " & Full_Path);
                              return Protocol.SI;
                        end;

                        N := N + 1;

                        if N mod 100 = 0 then
                           Display
                             ("File transfered"
                              & Natural'Image (N) & "/" & Max);
                        end if;
                     end loop;
                  end Get_RAW_Data;

                  Total_Transferred :=
                    Total_Transferred + Natural (To_Sync.Length);
               end if;

            else
               return Kind (Cmd);
            end if;
         end;
      end loop;
   end Receive_Files;

   ----------------
   -- Send_Files --
   ----------------

   procedure Send_Files
     (Channel           : Protocol.Communication_Channel;
      Root_Dir          : String;
      Excluded_Patterns : Str_Vect.Vector;
      Included_Patterns : Str_Vect.Vector;
      Mode              : Direction)
   is
      use type Str_Vect.Vector;
   begin
      --  Starts the tasks if not already done

      if Sync_Tasks = null then
         Sync_Tasks := new Gpr_Sync_Tasks;
      end if;

      Gpr_Queue.Add
        (Gpr_Data'
           (Channel,
            To_Unbounded_String (Root_Dir),
            Excluded_Patterns & Common_Excluded_Patterns
            & (if Mode = To_Slave
               then Artifact_Excluded_Patterns
               else Str_Vect.Empty_Vector),
            Included_Patterns));
   end Send_Files;

   ----------
   -- Wait --
   ----------

   procedure Wait is
   begin
      Gpr_Queue.No_More_Job;

      if Sync_Tasks /= null then
         for T of Sync_Tasks.all loop
            if not T'Terminated then
               T.Stop;
            end if;
         end loop;
      end if;
   end Wait;

begin
   Common_Excluded_Patterns.Append (".git");
   Common_Excluded_Patterns.Append (".svn");
   Common_Excluded_Patterns.Append (".hg");
   Common_Excluded_Patterns.Append ("CVS");
   Common_Excluded_Patterns.Append ("gnatinspect.db*");
   Common_Excluded_Patterns.Append ("GNAT-TEMP*.TMP");
   Common_Excluded_Patterns.Append ("*.lexch");

   Artifact_Excluded_Patterns.Append ("*.o");
   Artifact_Excluded_Patterns.Append ("*.obj");
   Artifact_Excluded_Patterns.Append ("*.ali");
   Artifact_Excluded_Patterns.Append ("*.dll");
   Artifact_Excluded_Patterns.Append ("*.so");
   Artifact_Excluded_Patterns.Append ("*.so.*");
   Artifact_Excluded_Patterns.Append ("*.exe");
end GPR.Compilation.Sync;

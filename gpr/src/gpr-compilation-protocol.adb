------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--          Copyright (C) 2012-2022, Free Software Foundation, Inc.         --
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

with Ada.Calendar.Conversions;   use Ada.Calendar;
with Ada.Calendar.Formatting;    use Ada.Calendar.Formatting;
with Ada.Characters.Handling;
with Ada.Directories;            use Ada.Directories;
with Ada.Streams.Stream_IO;      use Ada.Streams;
with Ada.Strings.Fixed;          use Ada.Strings.Fixed;
with Ada.Strings.Maps.Constants; use Ada.Strings.Maps;
with Ada.Unchecked_Deallocation;

with GNAT.Rewrite_Data;
with GNAT.String_Split; use GNAT.String_Split;

with GPR.Version;       use GPR.Version;

package body GPR.Compilation.Protocol is

   Args_Sep : constant Character := '|';
   --  Channel's argument separator

   function Image (N : Natural) return String;
   --  Returns string representation of N without leading space

   procedure Send_File_Internal
     (Channel    : Communication_Channel;
      Path_Name  : String;
      Cmd        : Command_Kind;
      Time_Stamp : Time_Stamp_Type);
   --  Send file Path_Name over the channel with rewritting if needed

   procedure Send_RAW_File_Content
     (Channel   : Communication_Channel;
      Path_Name : String);
   --  Send the file content untranslated

   procedure Set_File_Stamp
     (Path_Name : String; Time_Stamp : Time_Stamp_Type) with Inline;
   --  Set modification time stamp to the given file

   Buffer_Size : constant := 256 * 1_024; --  256Kb

   type Buffer_Access is access Stream_Element_Array;
   --  Used for RAW data

   procedure Unchecked_Free is
     new Ada.Unchecked_Deallocation (Stream_Element_Array, Buffer_Access);

   ----------
   -- Args --
   ----------

   function Args (Cmd : Command) return Argument_List_Access is
   begin
      return Cmd.Args;
   end Args;

   ------------
   -- Adjust --
   ------------

   overriding procedure Adjust (Channel : in out Communication_Channel) is
   begin
      Channel.Refs.Increment;
   end Adjust;

   overriding procedure Adjust (Cmd : in out Command) is
   begin
      Cmd.Refs.Increment;
   end Adjust;

   -------------------
   -- Clear_Rewrite --
   -------------------

   procedure Clear_Rewrite (Channel : in out Communication_Channel) is
   begin
      Channel.WD_From := Null_Unbounded_String;
      Channel.WD_To := Null_Unbounded_String;
      Channel.CD_From := Null_Unbounded_String;
      Channel.CD_To := Null_Unbounded_String;
   end Clear_Rewrite;

   -----------
   -- Close --
   -----------

   procedure Close (Channel : in out Communication_Channel) is
   begin
      begin
         --  Make sure we never fail, the other end-point could have already
         --  closed the channel (hard ctrl-c).
         Shutdown_Socket (Channel.Sock);
      exception
         when others =>
            null;
      end;

      --  Now close associated socket

      begin
         Close_Socket (Channel.Sock);
      exception
         when others =>
            null;
      end;

      Channel.Sock := No_Socket;
      Clear_Rewrite (Channel);
   end Close;

   ------------
   -- Create --
   ------------

   function Create
     (Sock    : Socket_Type;
      Virtual : Boolean := False) return Communication_Channel is
   begin
      return Communication_Channel'
        (Finalization.Controlled
         with Sock, (if Virtual then null else Stream (Sock)),
              Null_Unbounded_String, Null_Unbounded_String,
              Null_Unbounded_String, Null_Unbounded_String,
              new Shared_Counter (1));
   end Create;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Channel : in out Communication_Channel) is
      procedure Unchecked_Free is
        new Unchecked_Deallocation (Shared_Counter, Shared_Counter_Access);

      C : Shared_Counter_Access := Channel.Refs;
   begin
      Channel.Refs := null;

      C.Decrement;

      if C.Count = 0 then
         Free (Channel.Channel);
         Unchecked_Free (C);
      end if;
   end Finalize;

   overriding procedure Finalize (Cmd : in out Command) is
      procedure Unchecked_Free is
        new Unchecked_Deallocation (Shared_Counter, Shared_Counter_Access);

      C : Shared_Counter_Access := Cmd.Refs;
   begin
      Cmd.Refs := null;

      C.Decrement;

      if C.Count = 0 then
         Free (Cmd.Args);
         Unchecked_Free (C);
      end if;
   end Finalize;

   -----------------
   -- Get_Command --
   -----------------

   function Get_Command
     (Channel : Communication_Channel'Class) return Command
   is
      use Ada.Streams.Stream_IO;

      function Handle_File (Cmd : Command) return Command;
      --  A file has been recieved, write it to disk

      function Handle_RAW_File (Cmd : Command) return Command;
      --  A file has been recieved, write it to disk, no rewritte taking place

      procedure Handle_Output (Cmd : in out Command);
      --  A display output is received, read it and store it into the command

      -----------------
      -- Handle_File --
      -----------------

      function Handle_File (Cmd : Command) return Command is

         procedure Input
           (Item : out Stream_Element_Array;
            Last : out Stream_Element_Offset);
         --  Read and return some data from channel

         procedure Output (Item : Stream_Element_Array);
         --  Write data to file

         File_Name : constant String :=
                       Translate_Receive (Channel, Cmd.Args (2).all);
         Dir       : constant String := Containing_Directory (File_Name);

         Size      : Stream_Element_Count :=
                       Stream_Element_Count'Value (Cmd.Args (1).all);
         --  Number of bytes remaining to be read from channel

         Rewriter    : Rewrite_Data.Buffer :=
                         Rewrite_Data.Create
                           (To_String (Channel.WD_To),
                            To_String (Channel.WD_From));

         Rewriter_CD : aliased Rewrite_Data.Buffer :=
                         Rewrite_Data.Create
                           (To_String (Channel.CD_To),
                            To_String (Channel.CD_From));

         File : File_Type;

         -----------
         -- Input --
         -----------

         procedure Input
           (Item : out Stream_Element_Array;
            Last : out Stream_Element_Offset) is
         begin
            if Size = 0 then
               Last := 0;

            else
               Last := Stream_Element_Count'Min (Item'Length, Size);

               Stream_Element_Array'Read
                 (Channel.Channel, Item (Item'First .. Last));

               Size := Size - Last;
            end if;
         end Input;

         ------------
         -- Output --
         ------------

         procedure Output (Item : Stream_Element_Array) is
         begin
            Write (File, Item);
         end Output;

      begin
         Rewrite_Data.Link (Rewriter, Rewriter_CD'Unchecked_Access);

         if Dir /= "" and then not Exists (Dir) then
            Create_Directory (Dir);
         end if;

         begin
            Create (File, Out_File, File_Name);

            Rewrite_Data.Rewrite (Rewriter, Input'Access, Output'Access);

            Close (File);

            --  Set time stamp if any

            if Cmd.Args'Length = 3 then
               Set_File_Stamp
                 (File_Name, Time_Stamp_Type (Args (Cmd) (3).all));
            end if;

         exception
            when others =>
               if Is_Open (File) then
                  Close (File);
               end if;
         end;

         return Get_Command (Channel);
      end Handle_File;

      ---------------------
      -- Handle_RAW_File --
      ---------------------

      function Handle_RAW_File (Cmd : Command) return Command is
         File_Name  : constant String :=
                       Translate_Receive (Channel, Cmd.Args (1).all);
         Dir        : constant String := Containing_Directory (File_Name);
         Time_Stamp : Time_Stamp_Type := Empty_Time_Stamp;
      begin
         if Dir /= "" and then not Exists (Dir) then
            Create_Directory (Dir);
         end if;

         if Cmd.Args'Length = 2 then
            --  We have a time-stamp, use it
            Time_Stamp := Time_Stamp_Type (Args (Cmd) (2).all);
         end if;

         Get_RAW_File_Content (Channel, File_Name, Time_Stamp);

         return Get_Command (Channel);
      end Handle_RAW_File;

      -------------------
      -- Handle_Output --
      -------------------

      procedure Handle_Output (Cmd : in out Command) is
         function Is_Number (Cmd : Command) return Boolean is
           (Is_Subset
              (To_Set (Cmd.Args (1).all), Constants.Decimal_Digit_Set));
      begin
         if Cmd.Args'Length = 2
           and then Is_Number (Cmd)
         then
            declare
               Size   : constant Natural :=
                          Natural'Value (Cmd.Args (1).all);
               Result : String (1 .. Size);
            begin
               if Size = 0 then
                  Cmd.Output := Null_Unbounded_String;
               else
                  String'Read (Channel.Channel, Result);
                  Cmd.Output := To_Unbounded_String (Result);
               end if;
            end;

         else
            raise Wrong_Command
              with "Expected DP found " & Command_Kind'Image (Cmd.Cmd);
         end if;
      end Handle_Output;

      Result : Command;
      Args   : Slice_Set;

   begin
      declare
         Line : constant String := String'Input (Channel.Channel);
         C    : constant String :=
                  (if Line'Length >= 2
                   then Line (Line'First .. Line'First + 1)
                   else "");
      begin
         if C in
           "EX" | "AK" | "TS" | "ES" | "FL" | "FR" | "OK" | "KO"
           | "CX" | "CU" | "DP" | "EC" | "PG" | "SY" | "IR"
         then
            Result.Cmd := Command_Kind'Value (C);

            --  Slice arguments

            Create
              (Args,
               Line (Line'First + 2 .. Line'Last),
               String'(1 => Args_Sep));

            Result.Args :=
              new Argument_List (1 .. Integer (Slice_Count (Args)));

            for K in Result.Args'Range loop
               Result.Args (K) := new String'(Slice (Args, Slice_Number (K)));
            end loop;

            if Result.Cmd = FL then
               --  We got some file data to write
               return Handle_File (Result);

            elsif Result.Cmd = FR then
               return Handle_RAW_File (Result);

            elsif Result.Cmd = DP then
               --  We got an output to display
               Handle_Output (Result);

            elsif Result.Cmd = EX then
               --  Last - 1 parameter is the compiler options, ensure that we
               --  are using native directory separator. This is a requirement
               --  to have a cross compilation from a Windows builder to a
               --  Linux slave.
               declare
                  F_Idx    : constant Positive :=
                               Result.Args'Last - 1;
                  Filename : constant String :=
                               To_Native_Directory_Separator
                                 (Result.Args (F_Idx).all);
               begin
                  Free (Result.Args (F_Idx));
                  Result.Args (F_Idx) := new String'(Filename);
               end;
            end if;

         else
            if Line'Length > 0 then
               raise Wrong_Command with Line;
            else
               raise Wrong_Command with "empty command line";
            end if;
         end if;

         return Result;
      end;

   exception
      when others =>
         --  Any exception means that the channel has been closed. Return an
         --  EC command (which has no parameter).
         Result.Cmd := SI;
         Free (Result.Args);
         Result.Args := new Argument_List (1 .. 0);
         return Result;
   end Get_Command;

   -----------------
   -- Get_Context --
   -----------------

   procedure Get_Context
     (Channel                    : Communication_Channel;
      Target                     : out Unbounded_String;
      Project_Name               : out Unbounded_String;
      Build_Env                  : out Unbounded_String;
      Sync                       : out Boolean;
      Timestamp                  : out Time_Stamp_Type;
      Version                    : out Unbounded_String;
      Hash                       : out Unbounded_String;
      Included_Artifact_Patterns : out Unbounded_String;
      Is_Ping                    : out Boolean)
   is
      Line : constant Command := Get_Command (Channel);
   begin
      Is_Ping := False;

      --  Note that to ensure GPRslave stays compatible with old
      --  version of GNAT Pro and GPRbuild all parameters after the
      --  6th must be optional when retrieving the context. Note doing
      --  that will make GPRslave raise an exception instead of
      --  reporting a proper non-compatible context.

      if Line.Cmd = CX
        and then Line.Args'Length >= 6
      then
         Target       := To_Unbounded_String (Line.Args (1).all);
         Project_Name := To_Unbounded_String (Line.Args (2).all);
         Build_Env    := To_Unbounded_String (Line.Args (3).all);
         Sync         := Boolean'Value (Line.Args (4).all);
         Timestamp    := Time_Stamp_Type (Line.Args (5).all);
         Version      := To_Unbounded_String (Line.Args (6).all);

         Hash :=
           (if Line.Args'Length > 6 then
              To_Unbounded_String (Line.Args (7).all)
            else Null_Unbounded_String);

         Included_Artifact_Patterns :=
           (if Line.Args'Length > 7 then
              To_Unbounded_String (Line.Args (8).all)
            else Null_Unbounded_String);

      elsif Line.Cmd = PG then
         Is_Ping := True;

      else
         raise Wrong_Command
           with "Expected CX found " & Command_Kind'Image (Line.Cmd);
      end if;
   end Get_Context;

   -----------------------
   -- Get_Info_Response --
   -----------------------

   procedure Get_Info_Response
     (Channel          : Communication_Channel;
      Version_String   : out Unbounded_String;
      Current_UTC_Time : out Stamps.Time_Stamp_Type;
      GPR_Hash         : out Unbounded_String;
      Success          : out Boolean)
   is
      Cmd : constant Command := Get_Command (Channel);
   begin
      if Cmd.Args'Length = 3
        and then Cmd.Cmd in OK | KO
      then
         Version_String := To_Unbounded_String (Cmd.Args (1).all);
         Current_UTC_Time := Stamps.Time_Stamp_Type (Cmd.Args (2).all);
         GPR_Hash := To_Unbounded_String (Cmd.Args (3).all);
         Success := (if Kind (Cmd) = KO then False);

      else
         Success := False;
      end if;
   end Get_Info_Response;

   -------------
   -- Get_Pid --
   -------------

   procedure Get_Pid
     (Channel : Communication_Channel;
      Pid     : out Remote_Id;
      Success : out Boolean)
   is
      Cmd : constant Command := Get_Command (Channel);
   begin
      if Cmd.Args'Length = 1
        and then Cmd.Cmd in OK | KO
      then
         Pid := Remote_Id'Value (Cmd.Args (1).all);
         Success := (if Kind (Cmd) = KO then False);

      else
         Success := False;
      end if;
   end Get_Pid;

   --------------------------
   -- Get_RAW_File_Content --
   --------------------------

   procedure Get_RAW_File_Content
     (Channel   : Communication_Channel;
      Path_Name : String;
      Timestamp : Time_Stamp_Type := Empty_Time_Stamp)
   is
      Buffer : Buffer_Access;
      Last   : Stream_Element_Offset;
      Size   : Stream_Element_Offset;
      File   : Stream_IO.File_Type;

   begin
      Buffer := new Stream_Element_Array (1 .. Buffer_Size);

      Stream_IO.Create (File, Stream_IO.Out_File, Path_Name);

      loop
         --  Get the size

         Stream_Element_Offset'Read (Channel.Channel, Size);

         exit when Size = 0;

         --  Read this chunk

         while Size > 0 loop
            Receive_Socket (Channel.Sock, Buffer (1 .. Size), Last);

            if Last = 0  then
               --  Last = First - 1 then socket closed by peer
               raise Socket_Error;
            end if;

            Stream_IO.Write (File, Buffer (1 .. Last));
            Size := Size - Last;
         end loop;
      end loop;

      Stream_IO.Close (File);

      if Timestamp /= Empty_Time_Stamp then
         Set_File_Stamp (Path_Name, Timestamp);
      end if;

      Unchecked_Free (Buffer);

   exception
      when others =>
         --  If the file was opened, let's close it

         if Stream_IO.Is_Open (File) then
            Stream_IO.Delete (File);

         elsif Exists (Path_Name) then
            --  If the file has been created, make sure it is deleted as the
            --  content may be truncated.
            Delete_File (Path_Name);
         end if;

         Unchecked_Free (Buffer);

         raise;
   end Get_RAW_File_Content;

   -----------
   -- Image --
   -----------

   function Image (N : Natural) return String is
      N_Img : constant String := Natural'Image (N);
   begin
      return N_Img (N_Img'First + 1 .. N_Img'Last);
   end Image;

   ----------------
   -- Initialize --
   ----------------

   overriding procedure Initialize (Channel : in out Communication_Channel) is
   begin
      Channel.Refs := new Shared_Counter (1);
   end Initialize;

   overriding procedure Initialize (Cmd : in out Command) is
   begin
      Cmd.Refs := new Shared_Counter (1);
   end Initialize;

   ----------
   -- Kind --
   ----------

   function Kind (Cmd : Command) return Command_Kind is
   begin
      return Cmd.Cmd;
   end Kind;

   ------------
   -- Output --
   ------------

   function Output (Cmd : Command) return Unbounded_String is
   begin
      return Cmd.Output;
   end Output;

   --------------
   -- Send_Ack --
   --------------

   procedure Send_Ack (Channel : Communication_Channel; Pid : Remote_Id) is
   begin
      String'Output
        (Channel.Channel, Command_Kind'Image (AK) & Image (Pid));
   end Send_Ack;

   -------------------
   -- Send_Clean_Up --
   -------------------

   procedure Send_Clean_Up
     (Channel : Communication_Channel; Project_Name : String) is
   begin
      String'Output
        (Channel.Channel, Command_Kind'Image (CU) & Project_Name);
   end Send_Clean_Up;

   ------------------
   -- Send_Context --
   ------------------

   procedure Send_Context
     (Channel                    : Communication_Channel;
      Target                     : String;
      Project_Name               : String;
      Build_Env                  : String;
      Sync                       : Boolean;
      Hash                       : String;
      Included_Artifact_Patterns : String) is
   begin
      String'Output
        (Channel.Channel,
         Command_Kind'Image (CX) & Target & Args_Sep & Project_Name
         & Args_Sep & Build_Env
         & Args_Sep & Boolean'Image (Sync)
         & Args_Sep & String (GPR.Util.UTC_Time)
         & Args_Sep & Gpr_Version_String (Host => False)
         & Args_Sep & Hash
         & Args_Sep & Included_Artifact_Patterns);
   end Send_Context;

   -----------------------------
   -- Send_End_Of_Compilation --
   -----------------------------

   procedure Send_End_Of_Compilation (Channel : Communication_Channel) is
   begin
      String'Output (Channel.Channel, Command_Kind'Image (EC));
   end Send_End_Of_Compilation;

   ---------------------------
   -- Send_End_Of_File_List --
   ---------------------------

   procedure Send_End_Of_File_List (Channel : Communication_Channel) is
   begin
      String'Output (Channel.Channel, Command_Kind'Image (ES));
   end Send_End_Of_File_List;

   ---------------
   -- Send_Exec --
   ---------------

   procedure Send_Exec
     (Channel  : Communication_Channel;
      Project  : String;
      Dir      : String;
      Language : String;
      Target   : String;
      Runtime  : String;
      Options  : String_Vectors.Vector;
      Obj_Name : String;
      Dep_Name : String;
      Env      : String;
      Filter   : access function (Str, Sep : String) return String := null)
   is
      function Filter_Wrapper (Str, Sep : String) return String
        is  (if Filter = null then Str else Filter (Str, Sep));

      R_Cmd : Unbounded_String;
   begin
      --  Options are serialized into a string and separated with Opts_Sep

      for K in Options.First_Index .. Options.Last_Index loop
         Append (R_Cmd, Filter_Wrapper (Options (K), WD_Path_Tag));

         if K /= Options.Last_Index then
            Append (R_Cmd, Opts_Sep);
         end if;
      end loop;

      --  Send the command over the channel

      String'Output
        (Channel.Channel,
         Command_Kind'Image (EX)
         & Filter_Wrapper (Project, WD_Path_Tag)
         & Args_Sep & Dir
         & Args_Sep & Language
         & Args_Sep & Target
         & Args_Sep & Runtime
         & Args_Sep & Obj_Name
         & Args_Sep & Dep_Name
         & Args_Sep & To_String (R_Cmd)
         & Args_Sep & Filter_Wrapper (Env, WD_Path_Tag));
   end Send_Exec;

   ---------------
   -- Send_File --
   ---------------

   procedure Send_File
     (Channel         : Communication_Channel;
      Path_Name       : String;
      Rewrite         : Boolean;
      Keep_Time_Stamp : Boolean := False)
   is
      Time_Stamp : Time_Stamp_Type := Empty_Time_Stamp;
   begin
      if Keep_Time_Stamp then
         Time_Stamp := GPR.Util.To_UTC_Time_Stamp
           (Modification_Time (Path_Name));
      end if;

      if Rewrite then
         Send_File_Internal (Channel, Path_Name, FL, Time_Stamp);

      else
         if Exists (Path_Name) then
            String'Output
              (Channel.Channel,
               Command_Kind'Image (FR)
               & Translate_Send (Channel, Path_Name)
               & (if Keep_Time_Stamp then Args_Sep & String (Time_Stamp)
                 else ""));

            Send_RAW_File_Content (Channel, Path_Name);
         end if;
      end if;
   end Send_File;

   ----------------
   -- Sync_Files --
   ----------------

   procedure Sync_Files
     (Channel  : Communication_Channel;
      Root_Dir : String;
      Files    : File_Data_Set.Vector) is
   begin
      Create_Args : declare
         Args  : Unbounded_String;
         First : Boolean := True;
      begin
         for F of Files loop
            if First then
               First := False;
            else
               Append (Args, Args_Sep);
            end if;

            Append (Args, F.Path_Name);
            Append (Args, Args_Sep);
            Append (Args, String (F.Timestamp));
            Append (Args, Args_Sep);
            Append (Args, Boolean'Image (F.Is_Executable));
         end loop;

         String'Output
           (Channel.Channel,
            Command_Kind'Image (TS) & To_String (Args));
      end Create_Args;

      declare
         Cmd : constant Command := Get_Command (Channel);
      begin
         if Kind (Cmd) = KO then
            for Filename of Args (Cmd).all loop
               Send_RAW_File_Content
                 (Channel,
                  (if Root_Dir = ""
                   then ""
                   else Root_Dir & Directory_Separator) & Filename.all);
            end loop;
         end if;
      end;
   end Sync_Files;

   ------------------------
   -- Send_File_Internal --
   ------------------------

   procedure Send_File_Internal
     (Channel    : Communication_Channel;
      Path_Name  : String;
      Cmd        : Command_Kind;
      Time_Stamp : Time_Stamp_Type)
   is
      use Ada.Streams.Stream_IO;

      procedure Input
        (Item : out Stream_Element_Array; Last : out Stream_Element_Offset);
      --  Get input data from file

      procedure Output (Item : Stream_Element_Array);
      --  Send data to channel

      function File_Size return Natural;
      --  Compute the size of the file as rewritten

      File     : File_Type;
      F_Size   : Natural;

      Rewriter    : Rewrite_Data.Buffer :=
                      Rewrite_Data.Create
                        (To_String (Channel.WD_From),
                         To_String (Channel.WD_To));

      Rewriter_CD : aliased Rewrite_Data.Buffer :=
                      Rewrite_Data.Create
                        (To_String (Channel.CD_From),
                         To_String (Channel.CD_To));

      ---------------
      -- File_Size --
      ---------------

      function File_Size return Natural is

         procedure Count (Item : Stream_Element_Array);
         --  Count bytes

         Result : Natural := Natural (Size (Path_Name));

         -----------
         -- Count --
         -----------

         procedure Count (Item : Stream_Element_Array) is
         begin
            Result := Result + Item'Length;
         end Count;

      begin
         if Channel.WD_From /= Null_Unbounded_String
           and then Length (Channel.WD_From) <= Result
         then
            Result := 0;
            Rewrite_Data.Rewrite (Rewriter, Input'Access, Count'Access);
            Reset (File);
         end if;

         return Result;
      end File_Size;

      -----------
      -- Input --
      -----------

      procedure Input
        (Item : out Stream_Element_Array; Last : out Stream_Element_Offset) is
      begin
         if End_Of_File (File) then
            Last := 0;
         else
            Read (File, Item, Last);
         end if;
      end Input;

      ------------
      -- Output --
      ------------

      procedure Output (Item : Stream_Element_Array) is
      begin
         Stream_Element_Array'Write (Channel.Channel, Item);
      end Output;

   begin
      Rewrite_Data.Link (Rewriter, Rewriter_CD'Unchecked_Access);

      if Exists (Path_Name) then
         begin
            Open (File, In_File, Path_Name);

            --  First compute the file size as translated, note that this
            --  means that we are parsing the file twice.

            F_Size := File_Size;

            String'Output
              (Channel.Channel,
               Command_Kind'Image (Cmd) & Image (F_Size)
               & Args_Sep & Translate_Send (Channel, Path_Name)
               & (if Time_Stamp /= Empty_Time_Stamp
                 then Args_Sep & String (Time_Stamp) else ""));

            if F_Size /= 0 then
               Rewrite_Data.Rewrite (Rewriter, Input'Access, Output'Access);
            end if;

            Close (File);
         exception
            when others =>
               if Is_Open (File) then
                  Close (File);
               end if;
         end;

      else
         raise Constraint_Error with "File not found : " & Path_Name;
      end if;
   end Send_File_Internal;

   --------------------
   -- Set_File_Stamp --
   --------------------

   procedure Set_File_Stamp
     (Path_Name : String; Time_Stamp : Time_Stamp_Type)
   is
      function TS (First, Last : Positive) return Integer is
        (Integer'Value (String (Time_Stamp (First .. Last))));
      --  Converts substring from Time_Stamp to Integer
   begin
      Set_File_Last_Modify_Time_Stamp
        (Path_Name,
         To_Ada
           (time_t
              (Conversions.To_Unix_Time
                 (Time_Of
                    (TS (1, 4), TS (5, 6), TS (7, 8),
                     TS (9, 10), TS (11, 12), TS (13, 14))))));
   end Set_File_Stamp;

   -----------------------
   -- Send_Info_Request --
   -----------------------

   procedure Send_Info_Request (Channel : Communication_Channel) is
   begin
      String'Output (Channel.Channel, Command_Kind'Image (IR));
   end Send_Info_Request;

   ------------------------
   -- Send_Info_Response --
   ------------------------

   procedure Send_Info_Response
     (Channel          : Communication_Channel;
      Version_String   : String;
      Current_UTC_Time : Stamps.Time_Stamp_Type;
      GPR_Hash         : String) is
   begin
      String'Output
        (Channel.Channel, Command_Kind'Image (OK) &
         Version_String & Args_Sep &
         String (Current_UTC_Time) & Args_Sep &
         GPR_Hash);
   end Send_Info_Response;

   -------------
   -- Send_Ko --
   -------------

   procedure Send_Ko
     (Channel : Communication_Channel; Pid : Compilation.Remote_Id) is
   begin
      String'Output
        (Channel.Channel, Command_Kind'Image (KO) & Image (Pid));
   end Send_Ko;

   procedure Send_Ko
     (Channel : Communication_Channel;
      Message : String := "") is
   begin
      String'Output (Channel.Channel, Command_Kind'Image (KO) & Message);
   end Send_Ko;

   procedure Send_Ko
     (Channel : Communication_Channel;
      Files   : File_Data_Set.Vector)
   is
      Args  : Unbounded_String;
      First : Boolean := True;
   begin
      for F of Files loop
         if First then
            First := False;
         else
            Append (Args, Args_Sep);
         end if;

         Append (Args, To_String (F.Path_Name));
      end loop;

      String'Output
        (Channel.Channel, Command_Kind'Image (KO) & To_String (Args));
   end Send_Ko;

   -------------
   -- Send_Ok --
   -------------

   procedure Send_Ok
     (Channel : Communication_Channel; Pid : Compilation.Remote_Id) is
   begin
      String'Output
        (Channel.Channel, Command_Kind'Image (OK) & Image (Pid));
   end Send_Ok;

   procedure Send_Ok (Channel : Communication_Channel) is
   begin
      String'Output (Channel.Channel, Command_Kind'Image (OK));
   end Send_Ok;

   -----------------
   -- Send_Output --
   -----------------

   procedure Send_Output
     (Channel : Communication_Channel; File_Name : String) is
   begin
      Send_File_Internal (Channel, File_Name, DP, Empty_Time_Stamp);
   end Send_Output;

   ------------------------
   -- Send_Ping_Response --
   ------------------------

   procedure Send_Ping_Response
     (Channel          : Communication_Channel;
      Version_String   : String;
      Current_UTC_Time : Stamps.Time_Stamp_Type;
      GPR_Hash         : String) is
   begin
      String'Output
        (Channel.Channel, Command_Kind'Image (OK) &
         Version_String & ASCII.GS &
         String (Current_UTC_Time) & ASCII.GS &
         GPR_Hash);
   end Send_Ping_Response;

   ---------------------------
   -- Send_RAW_File_Content --
   ---------------------------

   procedure Send_RAW_File_Content
     (Channel   : Communication_Channel;
      Path_Name : String)
   is
      type Buffer_Access is access Stream_Element_Array;

      procedure Unchecked_Free is
        new Unchecked_Deallocation (Stream_Element_Array, Buffer_Access);

      Buffer : Buffer_Access;
      Last   : Stream_Element_Offset;
      Sent   : Stream_Element_Offset;

      File   : Stream_IO.File_Type;
   begin
      Buffer := new Stream_Element_Array (1 .. Buffer_Size);
      --  A somewhat large buffer is needed to transfer big file efficiently.
      --  Here we use a buffer which should be large enough for read most file
      --  contents in one OS call.
      --
      --  This is allocated on the heap to avoid too much pressure on the
      --  stack of the tasks.

      --  Open the file in shared mode as multiple tasks could have
      --  to send it.

      Stream_IO.Open
        (File, Stream_IO.In_File, Path_Name, Form => "shared=yes");

      --  Always send an empty stream element array at the end.
      --  This is used as EOF tag.

      loop
         Stream_IO.Read (File, Buffer.all, Last);

         --  Send the chunk size

         Stream_Element_Offset'Write (Channel.Channel, Last);
         exit when Last = 0;

         --  Send the chunk data

         Sent := 1;

         loop
            Send_Socket (Channel.Sock, Buffer (Sent .. Last), Sent);
            exit when Sent = Last;
            Sent := Sent + 1;
         end loop;
      end loop;

      Stream_IO.Close (File);

      Unchecked_Free (Buffer);

   exception
      when others =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;

         Unchecked_Free (Buffer);

         raise;
   end Send_RAW_File_Content;

   -----------------------
   -- Send_Slave_Config --
   -----------------------

   procedure Send_Slave_Config
     (Channel        : Communication_Channel;
      Max_Process    : Positive;
      Root_Directory : String;
      Clock_Status   : Boolean) is
   begin
      String'Output
        (Channel.Channel,
         Command_Kind'Image (OK)
         & Image (Max_Process)
         & Args_Sep & Root_Directory
         & Args_Sep & Boolean'Image (Clock_Status));
   end Send_Slave_Config;

   -----------------------
   -- Send_Sync_Request --
   -----------------------

   procedure Send_Sync_Request (Channel : Communication_Channel) is
   begin
      String'Output (Channel.Channel, Command_Kind'Image (SY));
   end Send_Sync_Request;

   --------------------
   -- Set_Rewrite_CD --
   --------------------

   procedure Set_Rewrite_CD
     (Channel : in out Communication_Channel; Path : String)
   is
      P : String := Normalize_Pathname
                      (Path, Case_Sensitive => not On_Windows);
   begin
      if On_Windows then
         --  On Windows the mapping file contains non normalized pathname. The
         --  format is an upper-case driver letter, all the remaining of the
         --  path is lower-case and the directory separator is a slash. We
         --  ensure that the compiler path registered follows this format
         --  to properly rewrite the runtime path in the mapping file.

         P (P'First) := Characters.Handling.To_Upper (P (P'First));
         P := Strings.Fixed.Translate (P, Strings.Maps.To_Mapping ("\", "/"));
      end if;

      Channel.CD_From := To_Unbounded_String (P);
      Channel.CD_To := To_Unbounded_String (CD_Path_Tag);
   end Set_Rewrite_CD;

   --------------------
   -- Set_Rewrite_WD --
   --------------------

   procedure Set_Rewrite_WD
     (Channel : in out Communication_Channel; Path : String) is
   begin
      Channel.WD_From := To_Unbounded_String (Path);
      Channel.WD_To := To_Unbounded_String (WD_Path_Tag);
   end Set_Rewrite_WD;

   ----------
   -- Sock --
   ----------

   function Sock (Channel : Communication_Channel) return Socket_Type is
   begin
      return Channel.Sock;
   end Sock;

   -----------------------
   -- Translate_Receive --
   -----------------------

   function Translate_Receive
     (Channel : Communication_Channel; Str : String) return String
   is
      P : constant Natural := Index (Str, To_String (Channel.WD_To));
   begin
      return
        (if P = 0 then Str
         else To_Native_Directory_Separator
             (To_String (Channel.WD_From) &
              Str (P + Length (Channel.WD_To) .. Str'Last)));
   end Translate_Receive;

   --------------------
   -- Translate_Send --
   --------------------

   function Translate_Send
     (Channel : Communication_Channel; Str : String) return String
   is
      P : constant Natural := Index (Str, To_String (Channel.WD_From));
   begin
      return
        (if P = 0 then Str
         else To_String (Channel.WD_To) &
           Str (P + Length (Channel.WD_From) .. Str'Last));
   end Translate_Send;

end GPR.Compilation.Protocol;

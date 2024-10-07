------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--          Copyright (C) 2023, Free Software Foundation, Inc.         --
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

with Ada.Text_IO;
with Ada.Directories;
with Ada.Environment_Variables; use Ada.Environment_Variables;
with Ada.Strings.Fixed; use Ada.Strings.Fixed;

with GPR.Debug;
with Interfaces.C_Streams;

with GPR.Opt;

package body GPR.Jobserver is

   package IC_STR renames Interfaces.C_Streams;

   HR, HW : File_Descriptor;
   HRW : File_Descriptor;

   Current_Implemented_Connection : constant Implemented_Connection_Type :=
                                      (Named_Pipe  => True,
                                       Simple_Pipe => True,
                                       others      => False);

   procedure Release (Token : Character);
   --  Release the token to the pipe of the jobserver

   protected body Task_State_Object is
      procedure Set (State : Task_State) is
      begin
         S := State;
      end Set;
      function Get return Task_State is (S);
   end Task_State_Object;

   protected body Task_Token_Status_Object is
      procedure Set (Status : Task_Token_Status) is
      begin
         S := Status;
      end Set;
      function Get return Task_Token_Status is (S);
   end Task_Token_Status_Object;

   protected body Token_Process_State_Object is
      procedure Set (State : Token_Process_State) is
      begin
         S := State;
      end Set;
      function Get return Token_Process_State is (S);
   end Token_Process_State_Object;

   protected body Sync_Proc_Task_Object is
      procedure Set (Value : Boolean) is
      begin
         V := Value;
      end Set;
      function Synced return Boolean is (V);
   end Sync_Proc_Task_Object;

   protected body Preorder_Auth_Object is
      procedure Set (Auth : Boolean) is
      begin
         Value  := Auth;
         Is_Set := True;
      end Set;
      entry Get (Auth : out Boolean) when Is_Set is
      begin
         Auth   := Value;
         Is_Set := False;
      end Get;
   end Preorder_Auth_Object;

   task body Jobserver_Task is
      Job_Done : Boolean := False;
   begin
      loop
         exit when Job_Done;
         declare
            Auth : Boolean;
         begin
            Preorder_Auth_Object.Get (Auth);
            Task_State_Object.Set (Busy);
            Task_Token_Status_Object.Set (Unknown);
            Sync_Proc_Task_Object.Set (True);
            if GPR.Debug.Debug_Flag_J then
               Ada.Text_IO.Put_Line
                 ("[ Jobserver ] Jobserver_Task unlocked ; Auth = "
                  & Auth'Img);
            end if;
            if Auth then
               if Current_Connection_Method = Simple_Pipe then
                  if not (IC_STR.is_regular_file (IC_STR.int (HR)) = 0)
                    or else not (IC_STR.is_regular_file (IC_STR.int (HW)) = 0)
                  then
                     Task_State_Object.Set (Error);
                     Task_Token_Status_Object.Set (Unknown);
                     Job_Done := True;
                  end if;
               end if;

               if not Job_Done then
                  case Current_Connection_Method is
                     when Named_Pipe =>
                        if Read (HRW, Char'Address, 1) /= 1 then
                           Task_Token_Status_Object.Set (Unavailable);
                        else
                           Task_Token_Status_Object.Set (Available);
                        end if;
                     when Simple_Pipe =>
                        if Read (HR, Char'Address, 1) /= 1 then
                           Task_Token_Status_Object.Set (Unavailable);
                        else
                           Task_Token_Status_Object.Set (Available);
                        end if;
                     when Undefined | Windows_Semaphore =>
                        null;
                  end case;
               end if;

               if GPR.Debug.Debug_Flag_J then
                  Ada.Text_IO.Put_Line
                    ("[ Jobserver ] Jobserver_Task ended ; Token_Status = "
                     & Task_Token_Status_Object.Get'Img);
               end if;
            else
               Job_Done := True;
            end if;
         end;
         Task_State_Object.Set (Idle);
      end loop;
   end Jobserver_Task;

   --------------
   -- Finalize --
   --------------

   procedure Finalize is
   begin
      Preorder_Auth_Object.Set (Auth => False);
   end Finalize;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
      Makeflags             : constant String := Value ("MAKEFLAGS", "");
      JS_Auth               : constant String := "--jobserver-auth=";
      Simple_Pipe_Delimiter : constant String := ",";
      Named_Pipe_Delimiter  : constant String := "fifo:";
      Dry_Run               : constant String := "n";

      Idx : Natural := 0;

      procedure Initialize_Connection (Method : Connection_Type);
      --  Try all known ways to connect to a jobserver

      ---------------------------
      -- Initialize_Connection --
      ---------------------------

      procedure Initialize_Connection (Method : Connection_Type) is
         Idx_Tmp  : Natural := Idx;
         Idx0_Tmp : Natural := 0;
      begin

         case Method is
            when Named_Pipe =>
               Idx_Tmp := Idx_Tmp + JS_Auth'Length;
               Idx0_Tmp :=
                 Index (Makeflags, Named_Pipe_Delimiter, From => Idx_Tmp);

               if Idx0_Tmp = 0 then
                  return;
               end if;

               Idx_Tmp := Idx0_Tmp + Named_Pipe_Delimiter'Length;
               Idx0_Tmp := Index (Makeflags, " ", From => Idx_Tmp);

               if Idx0_Tmp = 0 then
                  Idx0_Tmp := Makeflags'Last;
               else
                  Idx0_Tmp := Idx0_Tmp - 1;
               end if;

               if not Ada.Directories.Exists (Makeflags (Idx_Tmp .. Idx0_Tmp))
               then
                  return;
               end if;

               HRW :=
                 Open_Read_Write (Name  => Makeflags (Idx_Tmp .. Idx0_Tmp),
                                  Fmode => Text);

            when Simple_Pipe =>
               Idx_Tmp := Idx_Tmp + JS_Auth'Length;
               Idx0_Tmp :=
                 Index (Makeflags, Simple_Pipe_Delimiter, From => Idx_Tmp);

               if Idx0_Tmp = 0 then
                  return;
               end if;

               HR :=
                 File_Descriptor'Value (Makeflags (Idx_Tmp .. Idx0_Tmp - 1));

               Idx_Tmp := Idx0_Tmp + Simple_Pipe_Delimiter'Length;
               Idx0_Tmp := Index (Makeflags, " ", From => Idx_Tmp);

               if Idx0_Tmp = 0 then
                  HW :=
                    File_Descriptor'Value
                      (Makeflags (Idx_Tmp .. Makeflags'Last));
               else
                  HW :=
                    File_Descriptor'Value
                      (Makeflags (Idx_Tmp .. Idx0_Tmp - 1));
               end if;

               if HR < 0 or else HW < 0 then
                  raise JS_Initialize_Error with "Invalid file descriptor to"
                    & " perform a connection to the jobserver. Make sure you"
                    & " prefixed your gprbuild command with a """
                    & '+' & """ in your makefile.";
               end if;

               if not (IC_STR.is_regular_file (IC_STR.int (HR)) = 0)
                 or else not (IC_STR.is_regular_file (IC_STR.int (HW)) = 0)
               then
                  raise JS_Initialize_Error with "Unable to connect to the"
                    & " jobserver. Make sure you prefixed your gprbuild"
                    & "  command with a """ & '+' & """ in your makefile.";
               end if;

            when Undefined | Windows_Semaphore =>
               null;
         end case;

         Current_Connection_Method := Method;

      end Initialize_Connection;

   begin
      if Makeflags = "" then
         return;
      end if;

      Idx := Index (Makeflags, " ");
      Idx := Index (Makeflags (Makeflags'First .. Idx - 1), Dry_Run);

      if Idx /= 0 then
         raise JS_Makeflags_Parsing_Detects_Dry_Run;
      end if;

      Idx := Index (Makeflags, JS_Auth, Going => Ada.Strings.Backward);

      if Idx = 0 then
         return;
      end if;

      for Connection_Method in Connection_Type loop
         if Current_Implemented_Connection (Connection_Method) then
            Initialize_Connection (Method => Connection_Method);
         end if;
         exit when Current_Connection_Method /= Undefined;
      end loop;

      if GPR.Debug.Debug_Flag_J then
         Ada.Text_IO.Put_Line ("[ Jobserver ] Makeflags : " & '"'
                               & Makeflags & '"');
         Ada.Text_IO.Put_Line ("[ Jobserver ] Connection method : "
                               & Current_Connection_Method'Img);
      end if;

      if Current_Connection_Method = Undefined then
         return;
      end if;

      if Opt.Maximum_Compilers > 1 then
         Ada.Text_IO.Put_Line
           ("warning: -j is ignored when using GNU make jobserver");
      end if;

      Opt.Use_GNU_Make_Jobserver := True;

      JS_Task := new Jobserver_Task;
   end Initialize;

   --------------------
   -- Preorder_Token --
   --------------------

   procedure Preorder_Token is
      Preorder_Condition : constant Boolean :=
                             (Token_Process_State_Object.Get = Idle
                              or else
                                (Sync_Proc_Task_Object.Synced
                                 and then
                                 Task_State_Object.Get = Idle
                                 and then
                                 Task_Token_Status_Object.Get = Unavailable));
   begin
      if GPR.Debug.Debug_Flag_J then
         Ada.Text_IO.Put_Line ("[ Jobserver ] Preorder_Token");
         Ada.Text_IO.Put_Line ("   [ Proc ] "
                               & Token_Process_State_Object.Get'Img
                               & " ; Auth = "
                               & Boolean'Image (Preorder_Condition));
         Ada.Text_IO.Put_Line ("   [ Task ] "
                               & Task_State_Object.Get'Img & " - "
                               & Task_Token_Status_Object.Get'Img);
      end if;

      if Preorder_Condition
      then
         Sync_Proc_Task_Object.Set (False);
         Preorder_Auth_Object.Set (Auth => True);
         Token_Process_State_Object.Set (Pending);
         if GPR.Debug.Debug_Flag_J then
            Ada.Text_IO.Put_Line ("   [ Proc ] New process state : "
                                  & Token_Process_State_Object.Get'Img);
         end if;
      end if;
   end Preorder_Token;

   -----------------------
   -- Register_Token_Id --
   -----------------------

   procedure Register_Token_Id (Id : GPR.Compilation.Id) is
      Key : constant String := (if Id.Kind = Local
                                then Pid_To_Integer (Id.Pid)'Img & "-Local"
                                else Id.R_Pid'Img & "-Remote");
   begin
      if GPR.Debug.Debug_Flag_J then
         Ada.Text_IO.Put_Line ("[ Jobserver ] Register_Token_Id");
         Ada.Text_IO.Put_Line ("   [ Proc ] "
                               & Token_Process_State_Object.Get'Img);
         Ada.Text_IO.Put_Line ("   [ Task ] "
                               & Task_State_Object.Get'Img & " - "
                               & Task_Token_Status_Object.Get'Img);
      end if;

      if Task_Token_Status_Object.Get = Available then
         Source_Id_Token_Map.Insert (Key, Char);
         Token_Process_State_Object.Set (Idle);
         if GPR.Debug.Debug_Flag_J then
            Ada.Text_IO.Put_Line ("   [ Proc ] New process state : "
                                  & Token_Process_State_Object.Get'Img);
         end if;
      else
         raise JS_Process_Error with "Tried to register a token when no" &
           " token was available";
      end if;
   end Register_Token_Id;

   -------------
   -- Release --
   -------------

   procedure Release (Token : Character) is
   begin
      case Current_Connection_Method is
         when Named_Pipe =>
            if Write (HRW, Token'Address, 1) /= 1 then
               raise JS_Access_Error with Errno_Message;
            end if;
         when Simple_Pipe =>
            if Write (HW, Token'Address, 1) /= 1 then
               raise JS_Access_Error with Errno_Message;
            end if;
         when Undefined | Windows_Semaphore =>
            null;
      end case;
   end Release;

   --------------------------
   -- Registered_Processes --
   --------------------------

   function Registered_Processes return Boolean is
     (not Source_Id_Token_Map.Is_Empty);

   ------------------------------
   -- Synchronize_Token_Status --
   ------------------------------

   procedure Monitor is
      Tmp_Task_State : Task_State;
   begin
      Tmp_Task_State := Task_State_Object.Get;

      if Task_State_Object.Get = Error then
         raise JS_Access_Error with "Connection to the jobserver have been"
           & " lost. Make sure you prefixed your gprbuild command with a """
           & '+' & """ in your makefile.";
      end if;

      if GPR.Debug.Debug_Flag_J then
         Ada.Text_IO.Put_Line ("[ Jobserver ] Monitor");
         Ada.Text_IO.Put_Line ("   [ Proc ] "
                               & Token_Process_State_Object.Get'Img);
         Ada.Text_IO.Put_Line ("   [ Task ] " & Tmp_Task_State'Img
                               & " - " & Task_Token_Status_Object.Get'Img);
      end if;

      if Task_State_Object.Get = Busy
        and then Last_Task_State = Busy
      then
         Busy_State_Count := Busy_State_Count + 1;
         if GPR.Debug.Debug_Flag_J then
            Ada.Text_IO.Put_Line ("   [ Info ] Busy_State_Count = "
                                  & Busy_State_Count'Img);
         end if;
      else
         Busy_State_Count := 0;
      end if;

      Last_Task_State := Tmp_Task_State;
   end Monitor;

   -----------------------------
   -- Unregister_All_Token_Id --
   -----------------------------

   procedure Unregister_All_Token_Id is
      Cursor : Token_Process_Id.Cursor;
   begin
      while not Source_Id_Token_Map.Is_Empty loop
         Cursor := Source_Id_Token_Map.First;
         Release (Token => Token_Process_Id.Element (Position => Cursor));
         Source_Id_Token_Map.Delete (Position => Cursor);
      end loop;
   end Unregister_All_Token_Id;

   -------------------------
   -- Unregister_Token_Id --
   -------------------------

   procedure Unregister_Token_Id (Id : GPR.Compilation.Id) is
      Key : constant String := (if Id.Kind = Local
                                then Pid_To_Integer (Id.Pid)'Img & "-Local"
                                else Id.R_Pid'Img & "-Remote");
   begin
      if GPR.Debug.Debug_Flag_J then
         Ada.Text_IO.Put_Line ("[ Jobserver ] Unregister_Token_Id");
      end if;

      Release (Token => Source_Id_Token_Map.Element (Key));
      Source_Id_Token_Map.Delete (Key);
      Busy_State_Count := 0;
   end Unregister_Token_Id;

end GPR.Jobserver;

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

with Ada.Containers.Doubly_Linked_Lists;
with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Strings.Unbounded;       use Ada.Strings.Unbounded;

with GPR.Compilation.Slave;
with GPR.Names;                   use GPR.Names;
with GPR.Opt;                     use GPR.Opt;
with GPR.Script;                  use GPR.Script;

package body GPR.Compilation.Process is

   use Ada;
   use type Containers.Count_Type;

   package Env_Maps is
     new Containers.Indefinite_Ordered_Maps (String, String);
   --  A set of key=value

   package Prj_Maps is new Containers.Indefinite_Ordered_Maps
     (String, Env_Maps.Map, Env_Maps."<", Env_Maps."=");
   --  A set of project+language=map

   function "<" (Left, Right : Id) return Boolean is
     (Left.R_Pid < Right.R_Pid);

   package Failures_Slave_Set is
     new Containers.Indefinite_Ordered_Maps (Id, String);

   function Get_Env (Project : Project_Id; Language : String) return String;
   --  Get the environment for a specific project and language

   Environments : Prj_Maps.Map;

   type Process_Data is record
      Process : Id;
      Status  : Boolean;
   end record;

   package Endded_Process is new Containers.Doubly_Linked_Lists (Process_Data);

   protected Results is
      procedure Add (Result : Process_Data);
      entry Get (Result : out Process_Data);

      procedure Record_Remote_Failure (Pid : Id; Slave : String);
      --  This is to be able to display on which slaves a specific compilation
      --  has failed.

      function Get_Slave_For (Pid : Id) return String;
      --  Returns the remote slave for the given compilation, or the empty
      --  string if the compilation was successful.

   private
      List        : Endded_Process.List;
      Failed_Proc : Failures_Slave_Set.Map;
   end Results;

   ----------------
   -- Add_Result --
   ----------------

   procedure Add_Result
     (Process : Id; Status : Boolean; Slave : String := "") is
   begin
      Results.Add (Process_Data'(Process, Status));

      --  For a compilation failure records the slave to be able to report it

      if not Status and then Slave /= "" then
         Results.Record_Remote_Failure (Process, Slave);
      end if;
   end Add_Result;

   ------------------
   -- Create_Local --
   ------------------

   function Create_Local (Pid : Process_Id) return Id is
   begin
      return Id'(Local, Pid);
   end Create_Local;

   -------------------
   -- Create_Remote --
   -------------------

   function Create_Remote (Pid : Remote_Id) return Id is
   begin
      return Id'(Remote, Pid);
   end Create_Remote;

   ---------------------------
   -- Get_Maximum_Processes --
   ---------------------------

   function Get_Maximum_Processes return Positive is
   begin
      return Opt.Maximum_Compilers + Slave.Get_Max_Processes;
   end Get_Maximum_Processes;

   -------------
   -- Get_Env --
   -------------

   function Get_Env (Project : Project_Id; Language : String) return String is
      Key  : constant String :=
               Get_Name_String (Project.Name) & "+" & Language;
      Res  : Unbounded_String;
   begin
      if Environments.Contains (Key) then
         for C in Environments (Key).Iterate loop
            if Res /= Null_Unbounded_String then
               Res := Res & Opts_Sep;
            end if;

            Res := Res & Env_Maps.Key (C) & '=' & Env_Maps.Element (C);
         end loop;
      end if;

      return To_String (Res);
   end Get_Env;

   -------------------
   -- Get_Slave_For --
   -------------------

   function Get_Slave_For (Pid : Id) return String is
   begin
      return (if Pid.Kind = Local then "" else Results.Get_Slave_For (Pid));
   end Get_Slave_For;

   ----------
   -- Hash --
   ----------

   function Hash (Process : Id) return Header_Num is
      Modulo : constant Integer := Integer (Header_Num'Last) + 1;
   begin
      return
        (if Process.Kind = Local then
           Header_Num (Pid_To_Integer (Process.Pid) mod Modulo)
         else Header_Num (Process.R_Pid mod Remote_Id (Modulo)));
   end Hash;

   ------------------------
   -- Record_Environment --
   ------------------------

   procedure Record_Environment
     (Project     : Project_Id;
      Language    : Name_Id;
      Name, Value : String)
   is
      Lang : constant String := Get_Name_String (Language);
      Key  : constant String := Get_Name_String (Project.Name) & "+" & Lang;
      New_Item : Env_Maps.Map;
   begin
      --  Create new item, variable association

      New_Item.Include (Name, Value);

      if Environments.Contains (Key) then
         if Environments (Key).Contains (Name) then
            Environments (Key).Replace (Name, Value);
         else
            Environments (Key).Insert (Name, Value);
         end if;

      else
         Environments.Insert (Key, New_Item);
      end if;
   end Record_Environment;

   -------------
   -- Results --
   -------------

   protected body Results is

      ---------
      -- Add --
      ---------

      procedure Add (Result : Process_Data) is
      begin
         List.Append (Result);
      end Add;

      ---------
      -- Get --
      ---------

      entry Get (Result : out Process_Data) when List.Length /= 0 is
      begin
         Result := List.First_Element;
         List.Delete_First;
      end Get;

      -------------------
      -- Get_Slave_For --
      -------------------

      function Get_Slave_For (Pid : Id) return String is
         use type Failures_Slave_Set.Cursor;
         Pos : constant Failures_Slave_Set.Cursor := Failed_Proc.Find (Pid);
      begin
         return
           (if Pos = Failures_Slave_Set.No_Element then ""
            else Failures_Slave_Set.Element (Pos));
      end Get_Slave_For;

      ---------------------------
      -- Record_Remote_Failure --
      ---------------------------

      procedure Record_Remote_Failure (Pid : Id; Slave : String) is
      begin
         Failed_Proc.Insert (Pid, Slave);
      end Record_Remote_Failure;

   end Results;

   ---------
   -- Run --
   ---------

   function Run
     (Executable    : String;
      Options       : String_Vectors.Vector;
      Project       : Project_Id;
      Obj_Name      : String;
      Source        : String := "";
      Language      : String := "";
      Dep_Name      : String := "";
      Output_File   : String := "";
      Err_To_Out    : Boolean := False;
      Force_Local   : Boolean := False;
      Response_File : Path_Name_Type := No_Path) return Id
   is
      Env : constant String := Get_Env (Project, Language);
      Success : Boolean;

   begin
      --  Run locally first, then send jobs to remote slaves. Note that to
      --  build remotely we need an output file and a language, if one of
      --  this requirement is not fulfilled we just run the process locally.

      if Force_Local
        or else not Distributed_Mode
        or else Local_Process.Count < Opt.Maximum_Compilers
        or else Output_File /= ""
        or else Language = ""
      then
         Run_Local : declare
            P    : Id (Local);
            Args : String_List_Access :=
                     new String_List'(To_Argument_List (Options));
         begin
            Set_Env (Env, Fail => True);

            if Response_File /= No_Path then
               declare
                  Opts : constant GNAT.OS_Lib.Argument_List :=
                    (1 => new String'("@" & Get_Name_String (Response_File)));
               begin
                  P.Pid := Non_Blocking_Spawn (Executable, Opts);
               end;

            elsif Output_File /= "" then
               P.Pid := Non_Blocking_Spawn
                 (Executable, Args.all, Output_File, Err_To_Out);

            elsif Source /= "" and then not No_Complete_Output then
               P.Pid := Non_Blocking_Spawn
                 (Executable, Args.all,
                  Stdout_File => Source & ".stdout",
                  Stderr_File => Source & ".stderr");

            else
               if Source /= "" then
                  Delete_File (Source & ".stdout", Success);
                  Delete_File (Source & ".stderr", Success);
               end if;

               P.Pid := Non_Blocking_Spawn (Executable, Args.all);
            end if;

            Check_Local_Process (P, Executable, Options);

            Script_Write (Executable, Options);
            Free (Args);

            Local_Process.Increment;

            return P;
         end Run_Local;

      else
         --  Even if the compilation is done remotely make sure that any
         --  .stderr/.stdout from a previous local compilation are removed.

         if Source /= "" then
            Delete_File (Source & ".stdout", Success);
            Delete_File (Source & ".stderr", Success);
         end if;

         return Slave.Run
           (Project, Language, Options, Obj_Name, Dep_Name, Env);
      end if;
   end Run;

   -----------------
   -- Wait_Result --
   -----------------

   procedure Wait_Result (Process : out Id; Status : out Boolean) is
      Data : Process_Data;
   begin
      Results.Get (Data);
      Process := Data.Process;
      Status := Data.Status;
   end Wait_Result;

end GPR.Compilation.Process;

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

--  This package manages the communication with GNU make jobserver

with Ada.Strings.Hash;
with GPR.Compilation; use GPR.Compilation;
with Ada.Containers.Indefinite_Hashed_Maps;

package GPR.Jobserver is

   JS_Initialize_Error                  : exception;
   --  Error exception raised when jobserver's initialization fails
   JS_Makeflags_Parsing_Detects_Dry_Run : exception;
   --  Exception raised when make was invoked with "-n"
   JS_Access_Error                      : exception;
   --  Error exception raised when jobserver's read or write fails
   JS_Process_Error                     : exception;
   --  Error exception raised when jobserver's process fails

   function Awaiting_Job_Slot return Boolean;
   --  Returns whether or not we are waiting for a job slot :
   --     Cached_Token_Status = Pending or Unavailable.

   function Unavailable_Job_Slot return Boolean;
   --  Returns whether or not there is no job slot available
   --  When Current_Connection_Method = Named_Pipe :
   --     Cached_Token_Status = Pending
   --     This is because the token retrivial is blocking
   --  When Current_Connection_Method = Simple_Pipe | Windows_Semaphore :
   --     Cached_Token_Status = Unavailable

   procedure Initialize;
   --  Initialize Jobserver communication

   procedure Preorder_Token;
   --  Preorder a token from GNU make Jobserver

   procedure Register_Token_Id (Id : GPR.Compilation.Id);
   --  Affiliates the last preordered token to the process Id

   procedure Unregister_All_Token_Id;
   --  Free all registered tokens

   procedure Unregister_Token_Id (Id : GPR.Compilation.Id);
   --  Release the token affiliated to the process Id

   function Registered_Processes return Boolean;
   --  Returns True if there are ongoing processes affiliated with a token,
   --  returns False if there are not.

   function Pending_Process return Boolean;
   --  Returns True if a token have been ordered,
   --  returns False if not.

   procedure Monitor;
   --  Monitor the process status and state.

   procedure Finalize;
   --  Finalize Jobserver processes

private

   package Token_Process_Id is new Ada.Containers.Indefinite_Hashed_Maps
     (String, Character, Ada.Strings.Hash, "=");
   Source_Id_Token_Map : Token_Process_Id.Map;

   type Connection_Type is
     (Undefined, Named_Pipe, Simple_Pipe, Windows_Semaphore);
   Current_Connection_Method : Connection_Type := Undefined;

   type Implemented_Connection_Type is array (Connection_Type) of Boolean;

   type Task_Token_Status is (Unknown, Available, Unavailable);

   type Task_State is (Idle, Busy, Error);

   type Token_Process_State is (Idle, Pending);

   Last_Task_State      : Task_State := Idle;
   Busy_State_Count     : Integer    := 0;
   Max_Busy_State_Count : constant   := 10;

   protected Task_State_Object is
      procedure Set (State : Task_State);
      function Get return Task_State;
   private
      S : Task_State := Idle;
   end Task_State_Object;

   protected Task_Token_Status_Object is
      procedure Set (Status : Task_Token_Status);
      function Get return Task_Token_Status;
   private
      S : Task_Token_Status := Unknown;
   end Task_Token_Status_Object;

   protected Token_Process_State_Object is
      procedure Set (State : Token_Process_State);
      function Get return Token_Process_State;
   private
      S : Token_Process_State := Idle;
   end Token_Process_State_Object;

   protected Sync_Proc_Task_Object is
      procedure Set (Value : Boolean);
      function Synced return Boolean;
   private
      V : Boolean := True;
   end Sync_Proc_Task_Object;

   protected Preorder_Auth_Object is
      procedure Set (Auth : Boolean);
      entry Get (Auth : out Boolean);
   private
      Value  : Boolean := False;
      Is_Set : Boolean := False;
   end Preorder_Auth_Object;

   Char : aliased Character := ASCII.NUL;

   task type Jobserver_Task is
   end Jobserver_Task;

   JS_Task : access Jobserver_Task;

   function Awaiting_Job_Slot return Boolean is
     (Task_State_Object.Get = Busy
      or else not Sync_Proc_Task_Object.Synced
      or else not (Task_Token_Status_Object.Get = Available));

   function Unavailable_Job_Slot return Boolean is
     ((if Current_Connection_Method = Named_Pipe
      then (Task_State_Object.Get = Busy
        and then Busy_State_Count >= Max_Busy_State_Count)
      else (Task_Token_Status_Object.Get = Unavailable)));

   function Pending_Process return Boolean is
     (Token_Process_State_Object.Get = Pending);

end GPR.Jobserver;

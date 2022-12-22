------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--          Copyright (C) 2017-2022, Free Software Foundation, Inc.         --
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

with Ada.Command_Line;                       use Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;              use Ada.Environment_Variables;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with GNAT.Regpat;               use GNAT.Regpat;
with GNAT.Sockets;

with GPR.Names; use GPR.Names;
with GPR.Opt;   use GPR.Opt;
with GPR.Tempdir;

package body GPR.Util.Aux is

   --------------------------------
   -- Create_Export_Symbols_File --
   --------------------------------

   procedure Create_Export_Symbols_File
     (Driver_Path         : String;
      Options             : Argument_List;
      Sym_Matcher         : String;
      Format              : Export_File_Format;
      Objects             : String_List;
      Library_Symbol_File : String;
      Export_File_Name    : out Path_Name_Type)
   is
      use Ada.Text_IO;
      use type Ada.Containers.Count_Type;

      package Syms_List renames String_Sets;

      procedure Get_Syms (Object_File : String);
      --  Read exported symbols from Object_File and add them into Syms

      procedure Write (Str : String);
      --  Write Str into the export file

      Pattern : constant Pattern_Matcher := Compile (Sym_Matcher);

      Syms : Syms_List.Set;
      FD   : File_Descriptor;

      --------------
      -- Get_Syms --
      --------------

      procedure Get_Syms (Object_File : String) is
         Success   : Boolean;
         Ret       : Integer;
         Opts      : Argument_List (1 .. Options'Length + 1);
         File      : File_Type;
         File_Name : Path_Name_Type;
         Matches   : Match_Array (0 .. 1);

         function Filename return String is (Get_Name_String (File_Name));
         --  Remove the ASCII.NUL from end of temporary file-name

      begin
         Opts (1 .. Options'Length) := Options;
         Opts (Opts'Last) := new String'(Object_File);

         GPR.Tempdir.Create_Temp_File (FD, File_Name);
         Record_Temp_File (null, File_Name);

         Close (FD);

         if Verbose_Mode then
            Put  (Driver_Path);
            for O of Opts loop
               Put (' ');
               Put (O.all);
            end loop;
            New_Line;
         end if;

         Spawn (Driver_Path, Opts, Filename, Success, Ret);

         if Success then
            Open (File, In_File, Filename);

            while not End_Of_File (File) loop
               declare
                  Buffer : constant String := Get_Line (File);
               begin
                  Match (Pattern, Buffer, Matches);

                  if Matches (1) /= No_Match then
                     Syms.Include
                       (Buffer (Matches (1).First .. Matches (1).Last));
                  end if;
               end;
            end loop;

            Close (File);
         end if;

         Free (Opts (Opts'Last));
      end Get_Syms;

      -----------
      -- Write --
      -----------

      procedure Write (Str : String) is
         S : constant String := Str & ASCII.LF;
         R : Integer with Unreferenced;
      begin
         R := Write (FD, S (S'First)'Address, S'Length);
      end Write;

   begin
      Export_File_Name := No_Path;

      if Format = None then
         return;
      end if;

      if Library_Symbol_File = "" then
         --  Get the exported symbols from every object files, first get the nm
         --  tool for the target.

         for K in Objects'Range loop
            Get_Syms (Objects (K).all);
         end loop;

      else
         --  Get the symbols from the symbol file, one symbol per line

         if Is_Readable_File (Library_Symbol_File) then
            declare
               File : File_Type;
               Line : String (1 .. 1_024);
               Last : Natural;
            begin
               Open (File, In_File, Library_Symbol_File);

               while not End_Of_File (File) loop
                  Get_Line (File, Line, Last);

                  if Last > 0 then
                     Syms.Include (Line (1 .. Last));
                  end if;
               end loop;

               Close (File);
            end;

         else
            raise Constraint_Error
              with "unable to locate Library_Symbol_File"""
                   & Library_Symbol_File & '"';
         end if;
      end if;

      if Syms.Length = 0 then
         return;
      end if;

      --  Now create the export file, either GNU or DEF format

      Create_Export_File : declare
         File_Name : Path_Name_Type;
         Success   : Boolean;
      begin
         --  Create (Export_File, Out_File);

         GPR.Tempdir.Create_Temp_File (FD, File_Name);
         Record_Temp_File (null, File_Name);

         Get_Name_String (File_Name);

         --  Always add .def at the end, this is needed for Windows

         Add_Str_To_Name_Buffer (".def");
         Export_File_Name := Name_Find;
         Record_Temp_File (null, Export_File_Name);

         --  Header

         case Format is
            when GNU =>
               Write ("SYMS {");
               Write ("   global:");

            when Def =>
               Write ("EXPORTS");

            when None | Flat =>
               null;
         end case;

         --  Symbols

         for Sym of Syms loop
            case Format is
               when GNU =>
                  Write (Sym & ";");

               when Def | Flat =>
                  Write (Sym);

               when None =>
                  null;
            end case;
         end loop;

         --  Footer

         case Format is
            when GNU =>
               Write ("   local: *;");
               Write ("};");

            when None | Def | Flat =>
               null;
         end case;

         Close (FD);

         Copy_File
           (Get_Name_String (File_Name),
            Get_Name_String (Export_File_Name),
            Success);

         if not Success then
            Fail_Program
              (null,
               "couldn't create an export file " &
               Get_Name_String (Export_File_Name));
         end if;

      end Create_Export_File;
   end Create_Export_Symbols_File;

   --------------------------
   -- Create_Response_File --
   --------------------------

   procedure Create_Response_File
     (Format            : Response_File_Format;
      Objects           : String_List;
      Other_Arguments   : String_List;
      Resp_File_Options : String_List;
      Name_1            : out Path_Name_Type;
      Name_2            : out Path_Name_Type)
   is
      Objects_Vector : String_Vectors.Vector;
      Other_Args_Vector : String_Vectors.Vector;
      Resp_File_Options_Vector : String_Vectors.Vector;
   begin
      for J in Objects'Range loop
         Objects_Vector.Append (Objects (J).all);
      end loop;
      for J in Other_Arguments'Range loop
         Other_Args_Vector.Append (Other_Arguments (J).all);
      end loop;
      for J in Resp_File_Options'Range loop
         Resp_File_Options_Vector.Append (Resp_File_Options (J).all);
      end loop;

      Create_Response_File
        (Format,
         Objects_Vector,
         Other_Args_Vector,
         Resp_File_Options_Vector,
         Name_1,
         Name_2);
   end Create_Response_File;

   --------------------------
   -- Create_Response_File --
   --------------------------

   procedure Create_Response_File
     (Format            : Response_File_Format;
      Objects           : String_Vectors.Vector;
      Other_Arguments   : String_Vectors.Vector;
      Resp_File_Options : String_Vectors.Vector;
      Name_1            : out Path_Name_Type;
      Name_2            : out Path_Name_Type)
   is
      GNU_Header  : aliased constant String := "INPUT (";
      GNU_Opening : aliased constant String := """";
      GNU_Closing : aliased constant String := '"' & ASCII.LF;
      GNU_Footer  : aliased constant String := ')' & ASCII.LF;

      Resp_File : File_Descriptor;
      Status    : Integer;
      pragma Warnings (Off, Status);
      Closing_Status : Boolean;
      pragma Warnings (Off, Closing_Status);

      function Modified_Argument (Arg : String) return String;
      --  If the argument includes a space, a backslash, or a double quote,
      --  escape the character with a preceding backsash.

      -----------------------
      -- Modified_Argument --
      -----------------------

      function Modified_Argument (Arg : String) return String is
         Result : String (1 .. 2 * Arg'Length);
         Last   : Natural := 0;

         procedure Add (C : Character);

         ---------
         -- Add --
         ---------

         procedure Add (C : Character) is
         begin
            Last := Last + 1;
            Result (Last) := C;
         end Add;

      begin
         for J in Arg'Range loop
            if Arg (J) = '\' or else Arg (J) = ' ' or else Arg (J) = '"' then
               Add ('\');
            end if;

            Add (Arg (J));
         end loop;

         return Result (1 .. Last);
      end Modified_Argument;

   begin
      Name_2 := No_Path;
      Tempdir.Create_Temp_File (Resp_File, Name => Name_1);
      Record_Temp_File (null, Name_1);

      if Format = GNU or else Format = GCC_GNU then
         Status := Write (Resp_File, GNU_Header'Address, GNU_Header'Length);
      end if;

      for Object of Objects loop
         if Format = GNU or else Format = GCC_GNU then
            Status :=
              Write (Resp_File, GNU_Opening'Address, GNU_Opening'Length);
         end if;

         Status :=
           Write (Resp_File, Object (1)'Address, Object'Length);

         Status :=
           (if Format = GNU or else Format = GCC_GNU then
              Write (Resp_File, GNU_Closing'Address, GNU_Closing'Length)
            else Write (Resp_File, ASCII.LF'Address, 1));
      end loop;

      if Format = GNU or else Format = GCC_GNU then
         Status := Write (Resp_File, GNU_Footer'Address, GNU_Footer'Length);
      end if;

      case Format is
         when GCC_GNU | GCC_Object_List | GCC_Option_List =>
            Close (Resp_File, Closing_Status);
            Name_2 := Name_1;
            Tempdir.Create_Temp_File (Resp_File, Name => Name_1);
            Record_Temp_File (null, Name_1);

            for Option of Resp_File_Options loop
               Status :=
                 Write
                   (Resp_File,
                    Option (1)'Address,
                    Option'Length);
               if Option /= Resp_File_Options.Last_Element then
                  Status := Write (Resp_File, ASCII.LF'Address, 1);
               end if;
            end loop;

            declare
               Arg : constant String :=
                       Modified_Argument (Get_Name_String (Name_2));

            begin
               Status := Write (Resp_File, Arg (1)'Address, Arg'Length);
            end;

            Status := Write (Resp_File, ASCII.LF'Address, 1);

         when GCC =>
            null;

         when others =>
            Close (Resp_File, Closing_Status);
      end case;

      if        Format = GCC
        or else Format = GCC_GNU
        or else Format = GCC_Object_List
        or else Format = GCC_Option_List
      then
         for Argument of Other_Arguments loop
            declare
               Arg : constant String :=
                       Modified_Argument (Argument);

            begin
               Status := Write (Resp_File, Arg (1)'Address, Arg'Length);
            end;

            Status := Write (Resp_File, ASCII.LF'Address, 1);
         end loop;

         Close (Resp_File, Closing_Status);
      end if;
   end Create_Response_File;

   -----------------------
   -- Compute_Slave_Env --
   -----------------------

   function Compute_Slave_Env
     (Project : Project_Tree_Ref; Auto : Boolean) return String
   is
      User      : String_Access := Getenv ("USER");
      User_Name : String_Access := Getenv ("USERNAME");
      Default   : constant String :=
                    (if User = null
                     then (if User_Name = null
                       then "unknown" else User_Name.all)
                     else User.all)
                    & '@' & GNAT.Sockets.Host_Name;

      package S_Set renames String_Sets;

      Set : S_Set.Set;
      Ctx : Context;

   begin
      Free (User);
      Free (User_Name);

      if Auto then
         --  In this mode the slave environment is computed based on
         --  the project variable value and the command line arguments.

         --  First adds all command line arguments

         for K in 1 .. Argument_Count loop
            --  Skip arguments that are not changing the actual compilation and
            --  this will ensure that the same environment will be created for
            --  gprclean.

            if Argument (K) not in "-p" | "-d" | "-c" | "-q"
              and then
                (Argument (K)'Length < 2
                 or else Argument (K) (1 .. 2) /= "-j")
            then
               Set.Insert (Argument (K));
            end if;
         end loop;

         --  Then all the global variables for the project tree

         for K in
           1 .. Variable_Element_Table.Last (Project.Shared.Variable_Elements)
         loop
            declare
               V : constant Variable :=
                     Project.Shared.Variable_Elements.Table (K);
            begin
               if V.Value.Kind = Single then
                  Set.Include
                    (Get_Name_String (V.Name)
                     & "=" & Get_Name_String (V.Value.Value));
               end if;
            end;
         end loop;

         --  Compute the MD5 sum of the sorted elements in the set

         for S of Set loop
            Update (Ctx, S);
         end loop;

         return Default & "-" & Digest (Ctx);

      else
         --  Otherwise use the default <user_name> & '@' & <host_name>
         return Default;
      end if;
   end Compute_Slave_Env;

   ----------------------
   -- Get_Slaves_Hosts --
   ----------------------

   function Get_Slaves_Hosts
     (Project_Tree : Project_Tree_Ref;
      Arg          : String) return String
   is
      use Ada.Strings.Unbounded;
      Hosts : Unbounded_String;
   begin
      if Arg'Length > Distributed_Option'Length
        and then Arg (Arg'First + Distributed_Option'Length) = '='
      then
         --  The hosts are specified on the command-line
         Hosts := To_Unbounded_String
           (Arg (Arg'First + Distributed_Option'Length + 1 .. Arg'Last));

      elsif Environment_Variables.Exists ("GPR_SLAVES") then
         Hosts := To_Unbounded_String (Value ("GPR_SLAVES"));

      elsif Environment_Variables.Exists ("GPR_SLAVES_FILE") then
         declare
            F_Name : constant String := Value ("GPR_SLAVES_FILE");
            F      : Text_IO.File_Type;
            Buffer : String (1 .. 100);
            Last   : Natural;
         begin
            if Directories.Exists (F_Name) then
               Text_IO.Open (F, Text_IO.In_File, F_Name);

               while not Text_IO.End_Of_File (F) loop
                  Text_IO.Get_Line (F, Buffer, Last);

                  if Last > 0 then
                     if Hosts /= Null_Unbounded_String then
                        Append (Hosts, ",");
                     end if;
                     Append (Hosts, Buffer (1 .. Last));
                  end if;
               end loop;

               Text_IO.Close (F);

            else
               Fail_Program
                 (Project_Tree,
                  "hosts distributed file " & F_Name & " not found",
                  Exit_Code => E_General);
            end if;
         end;
      end if;

      return To_String (Hosts);
   end Get_Slaves_Hosts;

end GPR.Util.Aux;

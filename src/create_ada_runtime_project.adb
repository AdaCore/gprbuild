------------------------------------------------------------------------------
--                          GNAT SYSTEM UTILITIES                           --
--                                                                          --
--           C R E A T E _ A D A _ R U N T I M E _ P R O J E C T            --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--         Copyright (C) 2006-2012, Free Software Foundation, Inc.          --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

--  This utility creates the Ada runtime project file ada_runtime.gpr

--  This project file resides in the parent directory of adainclude (the source
--  directory) and adalib (the object directory). It is "externally built". Its
--  package Naming gives the mapping of the source file names to unit names.

with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Command_Line;        use Ada.Command_Line;
with Ada.Text_IO;             use Ada.Text_IO;

with GNAT.Command_Line;         use GNAT.Command_Line;
with GNAT.Directory_Operations; use GNAT.Directory_Operations;
with GNAT.OS_Lib;               use GNAT.OS_Lib;
with GNAT.HTable;               use GNAT.HTable;

procedure Create_Ada_Runtime_Project is

   Err : exception;
   --  Raised to terminate execution

   Project_File : Ada.Text_IO.File_Type;
   --  The project file being created

   Adainclude : String_Access := new String'("adainclude");
   --  The path name of the adainclude directory, given as argument of the
   --  utility.

   Dir  : Dir_Type;
   Str  : String (1 .. 1_000);
   Last : Natural;

   Gcc : constant String := "gcc";
   Gcc_Path : String_Access;

   Args : Argument_List (1 .. 6) :=
            (1 => new String'("-c"),
             2 => new String'("-gnats"),
             3 => new String'("-gnatu"),
             4 => new String'("-x"),
             5 => new String'("ada"),
             6 => null);
   --  The arguments used when invoking the Ada compiler to get the name and
   --  kind (spec or body) of the unit contained in a source file.

   Success     : Boolean;
   Return_Code : Integer;

   Mapping_File_Name : String_Access := new String'("gnat_runtime.mapping");
   --  Location of the default mapping file.

   Output_File : String_Access := new String'("ada_runtime.gpr");
   --  Name of the final project file being created

   Output_File_Name : constant String := "output.txt";
   Output           : Ada.Text_IO.File_Type;
   --  The text file where the output of the compiler invocation is stored.
   --  This is temporary output from gcc

   Line      : String (1 .. 1_000);
   Line_Last : Natural;
   Spec      : Boolean;

   Verbose_Mode : Boolean := False;
   --  True if switch -v is used

   subtype Header_Num is Natural range 0 .. 4095;
   function Hash (Key : String_Access) return Header_Num;
   function Equal (K1, K2 : String_Access) return Boolean;

   type Element is record
      Spec : Boolean := False;
      Unit : String_Access := null;
   end record;

   No_Element : constant Element := (False, null);

   package Mapping is new GNAT.HTable.Simple_HTable
     (Header_Num => Header_Num,
      Element    => Element,
      No_Element => No_Element,
      Key        => String_Access,
      Hash       => Hash,
      Equal      => Equal);
   --  A hash table to keep the mapping of source file names to unit names
   --  found in file gnat_runtime.mapping.

   Key  : String_Access;
   Elem : Element;

   function Hash is new GNAT.HTable.Hash (Header_Num);

   procedure Get_Mapping (Mapping_File : String);
   --  Read file mapping file to get the mapping of source file names
   --  to unit names and populate hash table Mapping.
   --  If the file doesn't exist, nothing is done, but
   --  Create_Ada_Runtime_Project will execute more slowly

   procedure Fail (S : String);
   --  Outputs S to Standard_Error, followed by a newline and then raises the
   --  exception Err.

   procedure Help;
   --  Display help on using this application

   -----------
   -- Equal --
   -----------

   function Equal (K1, K2 : String_Access) return Boolean is
   begin
      return
        (if K1 = null or else K2 = null then K1 = K2 else K1.all = K2.all);
   end Equal;

   ----------
   -- Fail --
   ----------

   procedure Fail (S : String) is
   begin
      Put_Line (Standard_Error, S);
      raise Err;
   end Fail;

   -----------------
   -- Get_Mapping --
   -----------------

   procedure Get_Mapping (Mapping_File : String) is
      File : File_Type;
      Line : String (1 .. 1_000);
      Last : Natural;

   begin
      Open (File, In_File, Mapping_File);

      while not End_Of_File (File) loop
         Get_Line (File, Line, Last);

         --  Skip the line if it is a comment line

         if Last > 2 and then Line (1 .. 2) /= "--" then
            Key := new String'(Line (1 .. Last));
            Get_Line (File, Line, Last);
            Elem.Spec := Line (1 .. Last) = "spec";
            Get_Line (File, Line, Last);
            Elem.Unit := new String'(Line (1 .. Last));

            Mapping.Set (Key, Elem);
         end if;
      end loop;

      Close (File);

   exception
      when others =>
         if Is_Open (File) then
            Close (File);
         end if;

         if Verbose_Mode then
            Put_Line (Standard_Error, "Could not read " & Mapping_File);
         end if;
   end Get_Mapping;

   ----------
   -- Hash --
   ----------

   function Hash (Key : String_Access) return Header_Num is
   begin
      return (if Key = null then 0 else Hash (Key.all));
   end Hash;

   ----------
   -- Help --
   ----------

   procedure Help is
   begin
      Put_Line (" -adainclude <dir>: Location of the adainclude directory");
      Put_Line (" -mapping <file>  : Location of the pre-built mapping file");
      Put_Line (" -o <file>        : Output file name");
      Put_Line (" -v               : Verbose mode");
      Put_Line ("                    Default is " & Output_File.all);
   end Help;

--  Start of processing for Create_Ada_Runtime_Project

begin
   --  The utility needs to be invoked with only one argument: the path name
   --  of the adainclude directory.

   loop
      case Getopt ("adainclude: o: mapping: h v") is
         when 'a' =>
            Free (Adainclude);
            Adainclude := new String'(Parameter);
         when 'm' =>
            Free (Mapping_File_Name);
            Mapping_File_Name := new String'(Parameter);
         when 'o' =>
            Free (Output_File);
            Output_File := new String'(Parameter);
         when 'h' =>
            Help;
            return;
         when 'v' =>
            Verbose_Mode := True;
         when others =>
            exit;
      end case;
   end loop;

   Gcc_Path := Locate_Exec_On_Path (Gcc);

   if Gcc_Path = null then
      Fail ("cannot find " & Gcc);
   end if;

   Get_Mapping (Mapping_File_Name.all);

   --  Change the working directory to the adainclude directory

   begin
      Change_Dir (Adainclude.all);
   exception
      when Directory_Error =>
         Fail ("cannot find adainclude directory " & Adainclude.all);
   end;

   --  Create the project file in the parent directory of adainclude

   Create (Project_File, Out_File, Output_File.all);

   --  Put the first lines that are always the same

   Put_Line (Project_File, "project Ada_Runtime is");
   New_Line (Project_File);
   Put_Line (Project_File, "   for Languages use (""Ada"");");
   Put_Line (Project_File, "   for Source_Dirs use ("""
             & Adainclude.all & """);");
   Put_Line (Project_File, "   for Object_Dir use """
             & Adainclude.all
             & ".." & Directory_Separator & "adalib"";");
   New_Line (Project_File);
   Put_Line (Project_File, "   for Externally_Built use ""true"";");
   New_Line (Project_File);
   Put_Line (Project_File, "   package Naming is");

   Open (Dir, ".");

   --  For each regular file in the adainclude directory, invoke the compiler
   --  to get the unit name.

   loop
      Read (Dir, Str, Last);
      exit when Last = 0;

      if Is_Regular_File (Str (1 .. Last)) then
         Key := new String'(Str (1 .. Last));
         Elem := Mapping.Get (Key);

         --  Mapping found in hash table

         if Elem /= No_Element then
            if To_Lower (Elem.Unit.all) /= Str (1 .. Last - 4) then
               Put (Project_File, "      for ");

               if Elem.Spec then
                  Put (Project_File, "Spec (""");
               else
                  Put (Project_File, "Body (""");
               end if;

               Put (Project_File, Elem.Unit.all);
               Put (Project_File, """) use """);
               Put (Project_File, Str (1 .. Last));
               Put_Line (Project_File, """;");
            end if;

         --  Case where Mapping.Get returned no element: use the compiler
         --  to get the unit name.

         else
            Args (Args'Last) := new String'(Str (1 .. Last));

            if Verbose_Mode then
               Put (Gcc_Path.all);

               for J in Args'Range loop
                  Put (' ' & Args (J).all);
               end loop;

               New_Line;
            end if;

            Spawn (Gcc_Path.all, Args, Output_File_Name, Success, Return_Code);

            if Success then
               Open (Output, In_File, Output_File_Name);

               if not End_Of_File (Output) then
                  Get_Line (Output, Line, Line_Last);

                  --  Find the first closing parenthesis

                  Char_Loop : for J in 1 .. Line_Last loop
                     if Line (J) = ')' then
                        if J >= 13 and then  Line (1 .. 4) = "Unit" then

                           --  No need for a spec or body declaration if the
                           --  file name is as expected.

                           if To_Lower (Line (6 .. J - 7)) /=
                                                           Str (1 .. Last - 4)
                           then
                              Spec := Line (J - 5 .. J) = "(spec)";

                              Put (Project_File, "      for ");

                              if Spec then
                                 Put (Project_File, "Spec (""");
                              else
                                 Put (Project_File, "Body (""");
                              end if;

                              Put (Project_File, Line (6 .. J - 7));
                              Put (Project_File, """) use """);
                              Put (Project_File, Str (1 .. Last));
                              Put_Line (Project_File, """;");
                           end if;
                        end if;

                        exit Char_Loop;
                     end if;
                  end loop Char_Loop;
               end if;

               Close (Output);
            end if;
         end if;
      end if;
   end loop;

   --  Put the closing lines and close the project file

   Put_Line (Project_File, "   end Naming;");
   New_Line (Project_File);
   Put_Line (Project_File, "end Ada_Runtime;");
   Close (Project_File);

   --  Clean up: delete the output file

   Delete_File (Output_File_Name, Success);

exception
   when Invalid_Switch | Invalid_Parameter =>
      Put_Line ("Invalid switch: " & Full_Switch);
      Help;

   when Err =>
      Set_Exit_Status (1);

   when others =>
      Put_Line ("unexpected exception");
      raise;
end Create_Ada_Runtime_Project;

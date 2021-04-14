------------------------------------------------------------------------------
--                                                                          --
--                             GPR TECHNOLOGY                               --
--                                                                          --
--                     Copyright (C) 2006-2020, AdaCore                     --
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

--  This is the version of the body of procedure Build_Shared_Lib for most
--  where shared libraries are supported.

with GPR.Util.Aux;

separate (Gprlib)
procedure Build_Shared_Lib is

   Lib_File : constant String :=
                Shared_Lib_Prefix.all &
                Library_Name.all & Shared_Lib_Suffix.all;

   Lib_Path : constant String :=
                Library_Directory.all & Lib_File;

   Maj_Version : String_Access := new String'("");

   Result  : Integer;
   pragma Unreferenced (Result);

   procedure Build (Output_File : String);
   --  Find the library builder executable and invoke it with the correct
   --  options to build the shared library.

   -----------
   -- Build --
   -----------

   procedure Build (Output_File : String) is
      Success  : Boolean;

      Windows_Target : constant Boolean := Shared_Lib_Suffix.all = ".dll";

      Out_Opt : constant String_Access := new String'("-o");
      Out_V   : constant String_Access := new String'(Output_File);

      Driver   : String_Access;

      Response_File_Name : Path_Name_Type := No_Path;
      Response_2         : Path_Name_Type := No_Path;
      Export_File        : Path_Name_Type := No_Path;

      procedure Display_Linking_Command;
      --  Display the linking command, depending on verbosity and quiet output

      -----------------------------
      -- Display_Linking_Command --
      -----------------------------

      procedure Display_Linking_Command is
      begin
         if not Opt.Quiet_Output then
            if Opt.Verbose_Mode then
               Set_Name_Buffer (Driver.all);

               for Arg of Arguments loop
                  Add_Str_To_Name_Buffer (" ");
                  Add_Str_To_Name_Buffer (Arg);
               end loop;

               Put_Line (Name_Buffer (1 .. Name_Len));

            else
               Display
                 (Section  => Build_Libraries,
                  Command  => "link library",
                  Argument => Lib_File);
            end if;
         end if;
      end Display_Linking_Command;

   begin
      --  Get the executable to use, either the specified Driver, or "gcc"

      if Driver_Name = No_Name then
         Driver := Locate_Exec_On_Path (Gcc_Name);

         if Driver = null then
            Fail_Program (null, Gcc_Name & " not found in path");
         end if;

      else
         Driver := Locate_Exec_On_Path (Get_Name_String (Driver_Name));

         if Driver = null then
            Fail_Program
              (null, Get_Name_String (Driver_Name) & " not found in path");
         end if;
      end if;

      Arguments := String_Vectors.Empty_Vector;
      --  Argument_Length := Driver'Length;

      --  The leading library options, if any
      Arguments.Append (Leading_Library_Options_Table);

      --  The minimum arguments
      Arguments.Append (Shared_Lib_Minimum_Options);

      --  -o <library file name>

      Arguments.Append (Out_Opt.all);
      Arguments.Append (Out_V.all);

      --  The options

      for Option of Options_Table loop
         if Option /= "" then
            Arguments.Append (Option);
         end if;
      end loop;

      --  Other options

      for Option of Library_Version_Options loop
         if Option /= "" then
            Arguments.Append (Option);
         end if;
      end loop;

      --  The object files

      if Partial_Linker /= null then
         Partial_Linker_Path := Locate_Exec_On_Path (Partial_Linker.all);

         if Partial_Linker_Path = null then
            Fail_Program
              (null, "unable to locate linker " & Partial_Linker.all);
         end if;
      end if;

      if Resp_File_Format = GPR.None
        and then Partial_Linker_Path /= null
      then
         --  If partial linker is used, do a partial link first

         Partial_Number := 0;
         First_Object := Object_Files.First_Index;

         loop
            declare
               Partial : constant String :=
                           Partial_Name
                             (Library_Name.all,
                              Partial_Number,
                              Object_Suffix);
               Size    : Natural := 0;

               Saved_PL_Options : String_Vectors.Vector;
            begin
               Saved_PL_Options := PL_Options;

               PL_Options.Append (Partial);
               Size := Size + 1 + Partial'Length;

               if Partial_Number > 0 then
                  PL_Options.Append
                    (Partial_Name
                       (Library_Name.all,
                        Partial_Number - 1,
                        Object_Suffix));
               end if;

               for Option of PL_Options loop
                  Size := Size + 1 + Option'Length;
               end loop;

               loop
                  PL_Options.Append (Object_Files (First_Object));
                  Size := Size + 1 + PL_Options.Last_Element'Length;

                  First_Object := First_Object + 1;
                  exit when
                    First_Object > Object_Files.Last_Index or else
                    Size >= Maximum_Size;
               end loop;

               if not Quiet_Output then
                  if Verbose_Mode then
                     Set_Name_Buffer (Partial_Linker_Path.all);

                     for Option of PL_Options loop
                        Add_Str_To_Name_Buffer (" ");
                        Add_Str_To_Name_Buffer (Option);
                     end loop;

                     Put_Line (Name_Buffer (1 .. Name_Len));
                  end if;
               end if;

               Spawn_And_Script_Write
                 (Partial_Linker_Path.all,
                  PL_Options,
                  Success);

               Set_Name_Buffer (Get_Current_Dir & Partial);
               Record_Temp_File
                 (Shared => null,
                  Path   => Name_Find);

               if not Success then
                  Fail_Program
                    (null,
                     "call to linker driver " &
                     Partial_Linker.all & " failed");
               end if;

               if First_Object > Object_Files.Last_Index then
                  Arguments.Append (Partial);
                  exit;
               end if;

               PL_Options := Saved_PL_Options;
               Partial_Number := Partial_Number + 1;
            end;
         end loop;

      else
         First_Object := Arguments.Last_Index + 1;

         for Obj of Object_Files loop
            Arguments.Append (Obj);
         end loop;
      end if;

      Last_Object := Arguments.Last_Index;

      --  In Ofiles we can have at the end some libraries -lname, so ensure
      --  that the object are only taken up to Last_Object_File_Index.

      if Last_Object_File_Index > First_Object
        and then Last_Object_File_Index < Last_Object
      then
         Last_Object := Last_Object_File_Index;
      end if;

      --  Finally the additional switches, the library switches and the library
      --  options.

      Arguments.Append (Additional_Switches);

      Arguments.Append (Library_Switches_Table);

      Arguments.Append (Ada_Runtime_Switches);

      Arguments.Append (Library_Options_Table);

      --  Check if a response file is needed
      if Max_Command_Line_Length > 0
        and then Resp_File_Format /= GPR.None
      then

         declare
            Arg_Length : Natural := Driver'Length;
            Options    : String_Vectors.Vector;
            Objects    : String_Vectors.Vector;
         begin
            Arg_Length := Arg_Length + Natural (Arguments.Length);

            for Arg of Arguments loop
               Arg_Length := Arg_Length + Arg'Length;
            end loop;

            if Arg_Length > Max_Command_Line_Length then
               Options :=
                 Slice (Arguments, Last_Object + 1, Arguments.Last_Index);
               Objects :=
                 Slice (Arguments, First_Object, Last_Object);

               Aux.Create_Response_File
                 (Format            => Resp_File_Format,
                  Objects           => Objects,
                  Other_Arguments   => Options,
                  Resp_File_Options => Response_File_Switches,
                  Name_1            => Response_File_Name,
                  Name_2            => Response_2);

               Record_Temp_File
                 (Shared => null,
                  Path   => Response_File_Name);

               if Response_2 /= No_Path then
                  Record_Temp_File
                    (Shared => null,
                     Path   => Response_2);
               end if;

               --  Remove objects and tail options from Arguments
               while Arguments.Last_Index > First_Object - 1 loop
                  Arguments.Delete_Last;
               end loop;

               if Resp_File_Format = GCC
                 or else Resp_File_Format = GCC_GNU
                 or else Resp_File_Format = GCC_Object_List
                 or else Resp_File_Format = GCC_Option_List
               then
                  Arguments.Append
                    ("@" & Get_Name_String (Response_File_Name));
               else
                  if Response_File_Switches.Is_Empty then
                     Arguments.Append (Get_Name_String (Response_File_Name));
                  else
                     Response_File_Switches.Replace_Element
                       (Response_File_Switches.Last_Index,
                        Response_File_Switches.Last_Element &
                          Get_Name_String (Response_File_Name));
                     Arguments.Append (Response_File_Switches);
                  end if;

                  --  Put back the options
                  Arguments.Append (Options);
               end if;
            end if;
         end;
      end if;

      --  For a standalone shared library, create an export symbols file if
      --  supported. We need a support for an export file and either:
      --
      --  A library symbol file to be defined
      --    or
      --  An object lister and the corresponding matcher

      if Standalone /= No and then Export_File_Switch /= null then
         if Library_Symbol_File /= null then
            --  The exported symbols are to be taken from the symbol file

            Aux.Create_Export_Symbols_File
              (Driver_Path         => "",
               Options             => To_Argument_List (OL_Options),
               Sym_Matcher         => "",
               Format              => Export_File_Format,
               Objects             => String_List'(1 .. 0 => null),
               Library_Symbol_File => Library_Symbol_File.all,
               Export_File_Name    => Export_File);

         elsif Object_Lister /= null
           and then Object_Lister_Matcher /= null
         then
            --  The exported symbols are to be read from the object artifacts
            --  of the library interface.

            declare
               List : String_Vectors.Vector;
            begin
               --  Ada unit interfaces

               List := Interface_Objs;

               --  We need to add the binder generated object file which
               --  contains the library initilization code to be explicitely
               --  called by the main application.
               List.Append (Generated_Objects);

               Aux.Create_Export_Symbols_File
                 (Driver_Path         => Object_Lister.all,
                  Options             => To_Argument_List (OL_Options),
                  Sym_Matcher         => Object_Lister_Matcher.all,
                  Format              => Export_File_Format,
                  Objects             => To_Argument_List (List),
                  Library_Symbol_File => "",
                  Export_File_Name    => Export_File);
            end;
         end if;

         --  If the export file has been created properly pass it to the linker

         if Export_File /= No_Path then
            Arguments.Append
              (Export_File_Switch.all & Get_Name_String (Export_File));
         end if;
      end if;

      --  On Windows, if we are building a standard library or a library with
      --  unrestricted symbol-policy make sure all symbols are exported.

      if Windows_Target
        and then (Standalone = No or else Export_File_Switch = null)
      then
         --  This is needed if an object contains a declspec(dllexport) as in
         --  this case only the specified symbols will be exported. That is the
         --  linker change from export-all to export only the symbols specified
         --  as dllexport.

         Arguments.Append ("-Wl,--export-all-symbols");
      end if;

      Display_Linking_Command;

      --  Finally spawn the library builder driver

      Spawn_And_Script_Write
        (Driver.all, Arguments, Success);

      if not Success then
         if Driver_Name = No_Name then
            Fail_Program (null, Gcc_Name & " execution error");

         else
            Fail_Program
              (null, Get_Name_String (Driver_Name) & " execution error");
         end if;
      end if;
   end Build;

--  Start of processing for Build_Shared_Lib

begin
   if Verbosity_Level > Opt.Low then
      Put ("building relocatable shared library ");
      Put_Line (Lib_File);
   end if;

   if Library_Version.all = "" or else not Symbolic_Link_Supported then
      --  If no Library_Version specified, make sure the table is empty and
      --  call Build.

      Library_Version_Options.Clear;
      Build (Lib_Path);

   else
      --  Put the necessary options corresponding to the Library_Version in the
      --  table.

      if Major_Minor_Id_Supported then
         Maj_Version :=
           new String'(Major_Id_Name (Lib_File, Library_Version.all));
      end if;

      if not Library_Version_Options.Is_Empty then
         if Maj_Version.all /= "" then
            Library_Version_Options.Replace_Element
              (Library_Version_Options.Last_Index,
               Library_Version_Options.Last_Element & Maj_Version.all);

         else
            Library_Version_Options.Replace_Element
              (Library_Version_Options.Last_Index,
               Library_Version_Options.Last_Element & Library_Version.all);
         end if;
      end if;

      if Is_Absolute_Path (Library_Version.all) then
         Library_Version_Path := Library_Version;

      else
         Library_Version_Path :=
           new String'
             (Library_Directory.all & Library_Version.all);
      end if;

      --  Now that the table has been filled, call Build

      Build (Library_Version_Path.all);

      --  Create symbolic link, if appropriate

      if Library_Version.all /= Lib_Path then
         Create_Sym_Links
           (Lib_Path,
            Library_Version.all,
            Library_Directory.all,
            Maj_Version.all);
      end if;

   end if;
end Build_Shared_Lib;

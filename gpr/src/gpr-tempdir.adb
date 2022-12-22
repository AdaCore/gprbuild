------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--          Copyright (C) 2003-2017, Free Software Foundation, Inc.         --
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

with GNAT.Directory_Operations; use GNAT.Directory_Operations;

with GPR.Names;  use GPR.Names;
with GPR.Opt;    use GPR.Opt;
with GPR.Output; use GPR.Output;

with GNAT.Strings;

package body GPR.Tempdir is

   Tmpdir_Needs_To_Be_Displayed : Boolean := True;

   Tmpdir   : constant String := "TMPDIR";
   Temp     : constant String := "TEMP";
   Tmp      : constant String := "TMP";

   Windows_List : constant GNAT.Strings.String_List (1 .. 4) :=
     (new String'("C:\TEMP"),
      new String'("C:\TMP"),
      new String'("\TEMP"),
      new String'("\TMP"));

   Other_List : constant GNAT.Strings.String_List (1 .. 3) :=
     (new String'("/tmp"),
      new String'("/var/tmp"),
      new String'("/usr/tmp"));

   Temp_Dir : String_Access := new String'("");

   ----------------------
   -- Create_Temp_File --
   ----------------------

   procedure Create_Temp_File
     (FD   : out File_Descriptor;
      Name : out Path_Name_Type)
   is
      File_Name   : String_Access;
      Current_Dir : constant String := Get_Current_Dir;

      function Directory return String;
      --  Returns Temp_Dir.all if not empty, else return current directory

      ---------------
      -- Directory --
      ---------------

      function Directory return String is
      begin
         return (if Temp_Dir'Length /= 0 then Temp_Dir.all else Current_Dir);
      end Directory;

   --  Start of processing for Create_Temp_File

   begin
      if Temp_Dir'Length /= 0 then

         --  In verbose mode, display once the value of TMPDIR, so that
         --  if temp files cannot be created, it is easier to understand
         --  where temp files are supposed to be created.

         if Opt.Verbosity_Level > Opt.Low and then
           Tmpdir_Needs_To_Be_Displayed
         then
            Write_Str ("TMPDIR = """);
            Write_Str (Temp_Dir.all);
            Write_Line ("""");
            Tmpdir_Needs_To_Be_Displayed := False;
         end if;

         --  Change directory to TMPDIR before creating the temp file,
         --  then change back immediately to the previous directory.

         Change_Dir (Temp_Dir.all);
         Create_Temp_File (FD, File_Name);
         Change_Dir (Current_Dir);

      else
         Create_Temp_File (FD, File_Name);
      end if;

      if FD = Invalid_FD then
         Write_Line ("could not create temporary file in " & Directory);
         Name := No_Path;

      else
         declare
            Path_Name : constant String :=
                          Normalize_Pathname
                            (Directory & Directory_Separator & File_Name.all);
         begin
            Name_Len := Path_Name'Length;
            Name_Buffer (1 .. Name_Len) := Path_Name;
            Name := Name_Find;
            Free (File_Name);
         end;
      end if;
   end Create_Temp_File;

   ------------------
   -- Use_Temp_Dir --
   ------------------

   procedure Use_Temp_Dir (Status : Boolean) is
      Dir : String_Access := null;

      function Dir_Is_Temporary_Dir return Boolean is
        (Dir /= null
         and then Dir'Length > 0
         and then Is_Absolute_Path (Dir.all)
         and then Is_Directory (Dir.all));

   begin
      if not Status then
         Temp_Dir := new String'("");
         return;
      end if;

      --  Checking environment variables.

      Dir := Getenv (Tmpdir);

      if not Dir_Is_Temporary_Dir then
         Free (Dir);
         Dir := Getenv (Temp);

         if not Dir_Is_Temporary_Dir then
            Free (Dir);
            Dir := Getenv (Tmp);
         end if;
      end if;

      Free (Temp_Dir);

      if Dir_Is_Temporary_Dir then
         Temp_Dir := new String'(Normalize_Pathname (Dir.all));
         Free (Dir);
         return;
      end if;

      Free (Dir);

      if Directory_Separator = '\' then

         for I in Windows_List'Range loop
            Dir := Windows_List (I);
            if Dir_Is_Temporary_Dir then
               Temp_Dir := new String'(Normalize_Pathname (Dir.all));
               return;
            end if;
         end loop;

      else

         for I in Other_List'Range loop
            Dir := Other_List (I);
            if Dir_Is_Temporary_Dir then
               Temp_Dir := new String'(Normalize_Pathname (Dir.all));
               return;
            end if;
         end loop;

      end if;

      Temp_Dir := new String'(Get_Current_Dir);

   end Use_Temp_Dir;

   ------------------------------
   -- Temporary_Directory_Path --
   ------------------------------

   function Temporary_Directory_Path return String is
   begin
      return (if Temp_Dir /= null then Temp_Dir.all else "");
   end Temporary_Directory_Path;

--  Start of elaboration for package Tempdir

begin
   Use_Temp_Dir (Status => True);
end GPR.Tempdir;

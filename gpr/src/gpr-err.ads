------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--          Copyright (C) 2001-2022, Free Software Foundation, Inc.         --
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

--  This package contains the routines to output error messages and the scanner
--  for the project files. It replaces Errout and Scn. It is not dependent on
--  the GNAT tree packages (Atree, Sinfo, ...). It uses exactly the same global
--  variables as Errout, located in package Err_Vars. Like Errout, it also uses
--  the common variables and routines in package Erroutc.
--
--  Parameters are set through Err_Vars.Error_Msg_File_* or
--  Err_Vars.Error_Msg_Name_*, and replaced automatically in the messages
--  ("{{" for files, "%%" for names).
--
--  However, in this package you can configure the error messages to be sent
--  to your own callback by setting Report_Error in the flags. This ensures
--  that applications can control where error messages are displayed.

package GPR.Err is

   ------------------------------
   -- Error Output Subprograms --
   ------------------------------

   procedure Initialize;
   --  Initializes for output of error messages. Must be called for each
   --  file before using any of the other routines in the package.

   procedure Finalize;
   --  Finalize processing of error messages for one file and output message
   --  indicating the number of detected errors.

   procedure Error_Msg
     (Flags    : Processing_Flags;
      Msg      : String;
      Location : Source_Ptr := No_Location;
      Project  : Project_Id := null;
      Always   : Boolean    := False;
      One_Line : Boolean    := False);
   --  Output an error message, either through Flags.Error_Report or through
   --  Errutil. The location defaults to the project's location ("project"
   --  in the source code). If Msg starts with "?", this is a warning, and
   --  Warning: is added at the beginning. If Msg starts with "<", see comment
   --  for Err_Vars.Error_Msg_Warn.
   --  One_Line flag mean only one error message per line, need to hide some
   --  wrong error message in project parser.

   function Mask_Control_Characters (Message : String) return String;
   --  Returns the message with all control characters masked by apostrophe

   procedure Error_Msg
     (Msg : String; Flag_Location : Source_Ptr; One_Line : Boolean := False);
   --  Output a message at specified location.
   --  One_Line flag mean only one error message per line, need to hide some
   --  wrong error message in project parser.

   -------------
   -- Scanner --
   -------------

   package Scanner is
      type Language is (Ada, Project);

      procedure Initialize_Scanner
        (Index : Source_File_Index;
         Lang  : Language);
      --  Initialize lexical scanner for scanning a new file referenced by
      --  Index. Initialize_Scanner does not call Scan.

      procedure Scan;
      --  Scan scans out the next token, and advances the scan state
      --  accordingly (see package Scan_State for details). If the scan
      --  encounters an illegal token, then an error message is issued pointing
      --  to the bad character, and Scan returns a reasonable substitute token
      --  of some kind. For tokens Char_Literal, Identifier, Real_Literal,
      --  Integer_Literal, String_Literal and Operator_Symbol, Post_Scan is
      --  called after scanning.

      procedure Set_End_Of_Line_As_Token (Value : Boolean);
      --  Indicate if End_Of_Line is a token or not.
      --  By default, End_Of_Line is not a token.

      procedure Set_Comment_As_Token (Value : Boolean);
      --  Indicate if a comment is a token or not.
      --  By default, a comment is not a token.

      procedure Set_Special_Character (C : Character);
      --  Indicate that one of the following character '#', '$', '?', '@', '`',
      --  '\', '^', '_' or '~', when found is a Special token.

      procedure Reset_Special_Characters;
      --  Indicate that there is no characters that are Special tokens., which
      --  is the default.

   end Scanner;

end GPR.Err;

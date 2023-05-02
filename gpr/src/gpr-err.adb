------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--          Copyright (C) 2002-2021, Free Software Foundation, Inc.         --
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

--  with Ada.Text_IO; use Ada.Text_IO;

with GPR.Cset;    use GPR.Cset;
with GPR.Erroutc; use GPR.Erroutc;
with GPR.Names;   use GPR.Names;
with GPR.Opt;     use GPR.Opt;
with GPR.Osint;   use GPR.Osint;
with GPR.Output;  use GPR.Output;
with GPR.Scans;   use GPR.Scans;
with GPR.Sinput;  use GPR.Sinput;

package body GPR.Err is

   Current_Error_Source_File : Source_File_Index := No_Source_File;

   procedure Post_Scan;
   --  Only for debugging. Does nothing.

   procedure Output_Source_Line
     (L     : Line_Number;
      Sfile : Source_File_Index;
      Errs  : Boolean);
   --  Outputs text of source line L, in file S, together with preceding line
   --  number, as described above for Output_Line_Number. The Errs parameter
   --  indicates if there are errors attached to the line, which forces
   --  listing on, even in the presence of pragma List (Off).

   procedure Prescan_Message (Msg : String);
   --  Scans message text and sets the following variables:
   --
   --    Is_Warning_Msg is set True if Msg is a warning message (contains a
   --    question mark character), and False otherwise.
   --
   --    Is_Info_Msg is set True if Msg is an information message (starts
   --    with "info: ". Such messages must contain a ? sequence since they
   --    are also considered to be warning messages, and get a tag.
   --
   --    Is_Serious_Error is set to True unless the message is a warning or
   --    style message or contains the character | (non-serious error).
   --
   --    Is_Unconditional_Msg is set True if the message contains the character
   --    ! and is otherwise set False.
   --
   --    Has_Double_Exclam is set True if the message contains the sequence !!
   --    and is otherwise set False.
   --
   --  We need to know right away these aspects of a message, since we will
   --  test these values before doing the full error scan.
   --
   --  Note that the call has no effect for continuation messages (those whose
   --  first character is '\'), and all variables are left unchanged.

   procedure Set_Msg_Text (Text : String);
   --  Add a sequence of characters to the current message. The characters may
   --  be one of the special insertion characters (see documentation in spec).
   --  Flag is the location at which the error is to be posted, which is used
   --  to determine whether or not the # insertion needs a file name. The
   --  variables Msg_Buffer, Msglen, Is_Warning_Msg, and Is_Unconditional_Msg
   --  are set on return.

   ---------------
   -- Error_Msg --
   ---------------

   procedure Error_Msg
     (Msg : String; Flag_Location : Source_Ptr; One_Line : Boolean := False)
   is
      Next_Msg : Error_Msg_Id;
      --  Pointer to next message at insertion point

      Prev_Msg : Error_Msg_Id;
      --  Pointer to previous message at insertion point

      Sptr : Source_Ptr renames Flag_Location;
      --  Corresponds to the Sptr value in the error message object

      Optr : Source_Ptr renames Flag_Location;
      --  Corresponds to the Optr value in the error message object. Note that
      --  for this usage, Sptr and Optr always have the same value, since we do
      --  not have to worry about generic instantiations.

      Sfile : Source_File_Index;
      Line  : Line_Number;
      Col   : Column_Number;
   begin
      Prescan_Message (Msg);
      Set_Msg_Text (Msg);

      --  Kill continuation if parent message killed

      if Continuation and Last_Killed then
         return;
      end if;

      --  Immediate return if warning message and warnings are suppressed.

      if Is_Warning_Msg and then Opt.Warning_Mode = Suppress then
         Cur_Msg := No_Error_Msg;
         return;
      end if;

      --  Otherwise build error message object for new message.
      --  First check that we do want to insert the error.

      Sfile    := Get_Source_File_Index (Sptr);
      Line     := Get_Line_Number (Sptr);
      Col      := Get_Column_Number (Sptr);
      Prev_Msg := No_Error_Msg;
      Next_Msg := First_Error_Msg;

      while Next_Msg /= No_Error_Msg loop
         exit when Sfile < Errors.Table (Next_Msg).Sfile;

         if Sfile = Errors.Table (Next_Msg).Sfile then
            exit when Sptr < Errors.Table (Next_Msg).Sptr;
         end if;

         Prev_Msg := Next_Msg;
         Next_Msg := Errors.Table (Next_Msg).Next;
      end loop;

      --  Now we insert the new message in the error chain. The insertion
      --  point for the message is after Prev_Msg and before Next_Msg.

      --  The possible insertion point for the new message is after Prev_Msg
      --  and before Next_Msg. However, this is where we do a special check
      --  for redundant parsing messages, defined as messages posted on the
      --  same line. The idea here is that probably such messages are junk
      --  from the parser recovering. In full errors mode, we don't do this
      --  deletion, but otherwise such messages are discarded at this stage.

      if Prev_Msg /= No_Error_Msg
        and then Errors.Table (Prev_Msg).Line = Line
        and then (One_Line or else Errors.Table (Prev_Msg).Col = Col)
        and then Errors.Table (Prev_Msg).Sfile = Sfile
      then
         --  Don't delete unconditional messages and at this stage, don't
         --  delete continuation lines (we attempted to delete those earlier
         --  if the parent message was deleted.

         if not Is_Unconditional_Msg and then not Continuation then
            --  Don't delete if prev msg is warning and new msg is an error.
            --  This is because we don't want a real error masked by a warning.
            --  In all other cases (that is parse errors for the same line that
            --  are not unconditional) we do delete the message. This helps to
            --  avoid junk extra messages from cascaded parsing errors

            if not Errors.Table (Prev_Msg).Warn or else Is_Warning_Msg then
               --  All tests passed, delete the message by simply returning
               --  without any further processing.

               if not Continuation then
                  Last_Killed := True;
               end if;

               return;
            end if;
         end if;
      end if;

      --  Come here if message is to be inserted in the error chain

      Errors.Append
        (New_Val =>
           (Text     => new String'(Msg_Buffer (1 .. Msglen)),
            Next     => No_Error_Msg,
            Prev     => No_Error_Msg,
            Sfile    => Sfile,
            Sptr     => Sptr,
            Optr     => Optr,
            Line     => Line,
            Col      => Get_Column_Number (Sptr),
            Warn     => Is_Warning_Msg,
            Info     => Is_Info_Msg,
            Warn_Err => Warning_Mode = Treat_As_Error,
            Warn_Chr => Warning_Msg_Char,
            Serious  => Is_Serious_Error,
            Uncond   => Is_Unconditional_Msg,
            Msg_Cont => Continuation,
            Deleted  => False));
      Cur_Msg  := Errors.Last;

      if not Continuation then
         Last_Killed := False;
      end if;

      if Prev_Msg = No_Error_Msg then
         First_Error_Msg := Cur_Msg;
      else
         Errors.Table (Prev_Msg).Next := Cur_Msg;
      end if;

      Errors.Table (Cur_Msg).Next := Next_Msg;

      --  Bump appropriate statistics count

      if Errors.Table (Cur_Msg).Warn then
         Warnings_Detected := Warnings_Detected + 1;

         if Errors.Table (Cur_Msg).Info then
            Info_Messages := Info_Messages + 1;
         end if;

      else
         Total_Errors_Detected := Total_Errors_Detected + 1;

         if Errors.Table (Cur_Msg).Serious then
            Serious_Errors_Detected := Serious_Errors_Detected + 1;
         end if;
      end if;

   end Error_Msg;

   --------------
   -- Finalize --
   --------------

   procedure Finalize is
      Cur  : Error_Msg_Id;
      Nxt  : Error_Msg_Id;
      E, F : Error_Msg_Id;

      procedure Write_File_Name (Name : File_Name_Type);
      --  Write name to standard output if it is defined or (null) otherwise

      ---------------------
      -- Write_File_Name --
      ---------------------

      procedure Write_File_Name (Name : File_Name_Type) is
      begin
         Write_Str
           ((if Name = No_File then "(null)" else Get_Name_String (Name)));
      end Write_File_Name;

   begin
      --  Eliminate any duplicated error messages from the list. This is
      --  done after the fact to avoid problems with Change_Error_Text.

      Cur := First_Error_Msg;
      while Cur /= No_Error_Msg loop
         Nxt := Errors.Table (Cur).Next;

         F := Nxt;
         while F /= No_Error_Msg
           and then Errors.Table (F).Sptr = Errors.Table (Cur).Sptr
         loop
            Check_Duplicate_Message (Cur, F);
            F := Errors.Table (F).Next;
         end loop;

         Cur := Nxt;
      end loop;

      --  Brief Error mode

      if Brief_Output or not Verbose_Mode then
         E := First_Error_Msg;
         Set_Standard_Error;

         while E /= No_Error_Msg loop
            if not Errors.Table (E).Deleted then
               Write_File_Name
                 ((if Full_Path_Name_For_Brief_Errors then
                     Full_Ref_Name (Errors.Table (E).Sfile)
                   else Reference_Name (Errors.Table (E).Sfile)));

               Write_Char (':');
               Write_Int (Int (Errors.Table (E).Line));
               Write_Char (':');

               if Errors.Table (E).Col < 10 then
                  Write_Char ('0');
               end if;

               Write_Int (Int (Errors.Table (E).Col));
               Write_Str (": ");
               Output_Msg_Text (E);
               Write_Eol;
            end if;

            E := Errors.Table (E).Next;
         end loop;

         Set_Standard_Output;
      end if;

      --  Verbose mode (error lines only with error flags)

      if Verbose_Mode then
         E := First_Error_Msg;

         --  Loop through error lines

         while E /= No_Error_Msg loop
            Write_Eol;
            Output_Source_Line
              (Errors.Table (E).Line,
               Errors.Table (E).Sfile,
               True);
            Output_Error_Msgs (E);
         end loop;
      end if;

      --  Output error summary if verbose or full list mode

      if Opt.Verbosity_Level > Opt.Low then

         --  Extra blank line if error messages or source listing were output

         if Total_Errors_Detected + Warnings_Detected > 0 then
            Write_Eol;
         end if;

         --  Message giving number of lines read and number of errors detected.
         --  This normally goes to Standard_Output. The exception is when brief
         --  mode is not set, verbose mode (or full list mode) is set, and
         --  there are errors. In this case we send the message to standard
         --  error to make sure that *something* appears on standard error in
         --  an error situation.

         --  Historical note: Formerly, only the "# errors" suffix was sent
         --  to stderr, whereas "# lines:" appeared on stdout. This caused
         --  some problems on now-obsolete ports, but there seems to be no
         --  reason to revert this page since it would be incompatible.

         if Total_Errors_Detected + Warnings_Detected /= 0
           and then not Brief_Output
           and then Verbose_Mode
         then
            Set_Standard_Error;
         end if;

         --  Message giving total number of lines

         Write_Str (" ");
         Write_Int (Num_Source_Lines (Main_Source_File));

         Write_Str
           ((if Num_Source_Lines (Main_Source_File) = 1 then " line: "
             else " lines: "));

         if Total_Errors_Detected = 0 then
            Write_Str ("No errors");

         elsif Total_Errors_Detected = 1 then
            Write_Str ("1 error");

         else
            Write_Int (Total_Errors_Detected);
            Write_Str (" errors");
         end if;

         if Warnings_Detected - Info_Messages  /= 0 then
            Write_Str (", ");
            Write_Int (Warnings_Detected - Info_Messages);
            Write_Str (" warning");

            if Warnings_Detected - Info_Messages /= 1 then
               Write_Char ('s');
            end if;

            if Warning_Mode = Treat_As_Error then
               Write_Str (" (treated as error");

               if Warnings_Detected - Info_Messages /= 1 then
                  Write_Char ('s');
               end if;

               Write_Char (')');
            end if;
         end if;

         Write_Eol;
         Set_Standard_Output;
      end if;

      if Warning_Mode = Treat_As_Error then
         Total_Errors_Detected :=
           Total_Errors_Detected + Warnings_Detected - Info_Messages;
         Warnings_Detected := Info_Messages;
      end if;

      --  Deallocate the memory associated to text

      Cur := First_Error_Msg;
      while Cur /= No_Error_Msg loop
         Free (Errors.Table (Cur).Text);
         Cur := Errors.Table (Cur).Next;
      end loop;

      --  Prevent displaying the same messages again in the future

      First_Error_Msg := No_Error_Msg;
   end Finalize;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
      Cur : Error_Msg_Id;
   begin
      --  Sometimes Initialize is being called to reset the table, while
      --  memory is still allocated in this table - if so, deallocate
      --  the memory before resetting.
      if not Errors.Is_Empty then
         Cur := First_Error_Msg;
         while Cur /= No_Error_Msg loop
            Free (Errors.Table (Cur).Text);
            Cur := Errors.Table (Cur).Next;
         end loop;
      end if;

      Errors.Init;
      First_Error_Msg := No_Error_Msg;
      Last_Error_Msg  := No_Error_Msg;
      Serious_Errors_Detected := 0;
      Total_Errors_Detected := 0;
      Warnings_Detected := 0;
      Info_Messages := 0;
      Cur_Msg := No_Error_Msg;

      --  Initialize warnings table, if all warnings are suppressed, supply
      --  an initial dummy entry covering all possible source locations.

      Warnings.Init;

      if Warning_Mode = Suppress then
         Warnings.Append
           (New_Val =>
              (Start  => Source_Ptr'First,
               Stop   => Source_Ptr'Last,
               Reason => No_Name));
      end if;
   end Initialize;

   -----------------------------
   -- Mask_Control_Characters --
   -----------------------------

   function Mask_Control_Characters (Message : String) return String is
      Result : String (1 .. Message'Length * 2);
      Last   : Natural := 0;
   begin
      for C of Message loop
         if C in '%' | '$' | '{' | '}' | '*' | '&' | '#' | '\' | '@' | '^'
           | '`' | '!' | '?' | '<' | '|' | ''' | '~' | 'A' .. 'Z'
         then
            Last := Last + 1;
            Result (Last) := ''';
         end if;

         Last := Last + 1;
         Result (Last) := C;
      end loop;

      return Result (1 .. Last);
   end Mask_Control_Characters;

   ------------------------
   -- Output_Source_Line --
   ------------------------

   procedure Output_Source_Line
     (L     : Line_Number;
      Sfile : Source_File_Index;
      Errs  : Boolean)
   is
      S : Source_Ptr;
      C : Character;

      Line_Number_Output : Boolean := False;
      --  Set True once line number is output

   begin
      if Sfile /= Current_Error_Source_File then
         Write_Str ("==============Messages for file: ");

         Write_Name (Full_File_Name (Sfile));
         Write_Eol;

         Current_Error_Source_File := Sfile;
      end if;

      if Errs then
         Output_Line_Number (L);
         Line_Number_Output := True;
      end if;

      S := Line_Start (L, Sfile);

      loop
         C := Source_Text (Sfile) (S);
         exit when C = ASCII.LF or else C = ASCII.CR or else C = EOF;

         if Errs then
            Write_Char (C);
         end if;

         S := S + 1;
      end loop;

      --  If we have output a source line, then add the line terminator, with
      --  training spaces preserved (so we output the line exactly as input).

      if Line_Number_Output then
         Write_Eol;
      end if;
   end Output_Source_Line;

   ---------------
   -- Post_Scan --
   ---------------

   procedure Post_Scan is
      Debug_Tokens : constant Boolean := False;

   begin
      if Debug_Tokens then
         Write_Line (Token_Type'Image (Token));

         if Token = Tok_Identifier
           or else Token = Tok_String_Literal
         then
            Write_Line ("  " & Get_Name_String (Token_Name));
         end if;
      end if;
   end Post_Scan;

   ---------------
   -- Error_Msg --
   ---------------

   procedure Error_Msg
     (Flags    : Processing_Flags;
      Msg      : String;
      Location : Source_Ptr := No_Location;
      Project  : Project_Id := null;
      Always   : Boolean    := False;
      One_Line : Boolean    := False)
   is
      Real_Location : Source_Ptr := Location;

   begin
      --  Don't post message if incompleted with's (avoid junk cascaded errors)

      if not Always and then Flags.Incomplete_Withs then
         return;
      end if;

      --  Display the error message in the traces so that it appears in the
      --  correct location in the traces (otherwise error messages are only
      --  displayed at the end and it is difficult to see when they were
      --  triggered)

      if Current_Verbosity = High then
         Debug_Output ("ERROR: " & Msg);
      end if;

      --  If location of error is unknown, use the location of the project

      if Real_Location = No_Location
        and then Project /= null
      then
         Real_Location := Project.Location;
      end if;

      if Real_Location = No_Location then

         --  If still null, we are parsing a project that was created in-memory
         --  so we shouldn't report errors for projects that the user has no
         --  access to in any case.

         if Current_Verbosity = High then
            Debug_Output ("Error in in-memory project, ignored");
         end if;

         return;
      end if;

      --  Report the error through Errutil, so that duplicate errors are
      --  properly removed, messages are sorted, and correctly interpreted,...

      Error_Msg (Msg, Real_Location, One_Line);

      --  Let the application know there was an error

      if Flags.Report_Error /= null then
         Flags.Report_Error
           (Project,
            Is_Warning =>
              Msg (Msg'First) = '?'
                or else (Msg (Msg'First) = '<'
                          and then Error_Msg_Warn)
                or else (Msg (Msg'First) = '\'
                          and then Msg (Msg'First + 1) = '<'
                          and then Error_Msg_Warn));
      end if;
   end Error_Msg;

   ---------------------
   -- Prescan_Message --
   ---------------------

   procedure Prescan_Message (Msg : String) is
      J : Natural;

   begin
      --  Nothing to do for continuation line

      if Msg (Msg'First) = '\' then
         return;
      end if;

      --  Set initial values of globals (may be changed during scan)

      Is_Serious_Error     := True;
      Is_Unconditional_Msg := False;
      Is_Warning_Msg       := False;
      Has_Double_Exclam    := False;

      --  Check info message

      Is_Info_Msg :=
        Msg'Length > 6 and then Msg (Msg'First .. Msg'First + 5) = "info: ";

      J := Msg'First;
      while J <= Msg'Last loop

         --  If we have a quote, don't look at following character

         if Msg (J) = ''' then
            J := J + 2;

         --  Warning message (? or < insertion sequence)

         elsif Msg (J) = '?' or else Msg (J) = '<' then
            Is_Warning_Msg := Msg (J) = '?' or else Error_Msg_Warn;
            Warning_Msg_Char := ' ';
            J := J + 1;

            if Is_Warning_Msg then
               declare
                  C : constant Character := Msg (J - 1);
               begin
                  if J <= Msg'Last then
                     if Msg (J) = C then
                        Warning_Msg_Char := '?';
                        J := J + 1;

                     elsif J < Msg'Last and then Msg (J + 1) = C
                       and then (Msg (J) in 'a' .. 'z' or else
                                 Msg (J) in 'A' .. 'Z' or else
                                 Msg (J) = '*'         or else
                                 Msg (J) = '$')
                     then
                        Warning_Msg_Char := Msg (J);
                        J := J + 2;
                     end if;
                  end if;
               end;
            end if;

            --  Bomb if untagged warning message. This code can be uncommented
            --  for debugging when looking for untagged warning messages.

            --  if Is_Warning_Msg and then Warning_Msg_Char = ' ' then
            --     raise Program_Error;
            --  end if;

         --  Unconditional message (! insertion)

         elsif Msg (J) = '!' then
            Is_Unconditional_Msg := True;
            J := J + 1;

            if J <= Msg'Last and then Msg (J) = '!' then
               Has_Double_Exclam := True;
               J := J + 1;
            end if;

         --  Non-serious error (| insertion)

         elsif Msg (J) = '|' then
            Is_Serious_Error := False;
            J := J + 1;

         else
            J := J + 1;
         end if;
      end loop;

      if Is_Warning_Msg then
         Is_Serious_Error := False;
      end if;
   end Prescan_Message;

   ------------------
   -- Set_Msg_Text --
   ------------------

   procedure Set_Msg_Text (Text : String) is
      C : Character; -- Current character
      P : Natural;   -- Current index;

   begin
      Manual_Quote_Mode := False;
      Msglen := 0;
      P := Text'First;

      while P <= Text'Last loop
         C := Text (P);
         P := P + 1;

         --  Check for insertion character

         if C = '%' then
            if P <= Text'Last and then Text (P) = '%' then
               P := P + 1;
               Set_Msg_Insertion_Name_Literal;
            else
               Set_Msg_Insertion_Name;
            end if;

         elsif C = '$' then

            --  '$' is ignored

            null;

         elsif C = '{' then
            Set_Msg_Insertion_File_Name;

         elsif C = '}' then

            --  '}' is ignored

            null;

         elsif C = '*' then
            Set_Msg_Insertion_Reserved_Name;

         elsif C = '&' then

            --  '&' is ignored

            null;

         elsif C = '#' then
            null;

         elsif C = '\' then
            Continuation := True;

         elsif C = '@' then
            null;

         elsif C = '^' then
            null;

         elsif C = '`' then
            Manual_Quote_Mode := not Manual_Quote_Mode;
            Set_Msg_Char ('"');

         elsif C = '!' then
            null;

         elsif C = '?' then
            null;

         elsif C = '<' then
            null;

         elsif C = '|' then
            null;

         elsif C = ''' then
            Set_Msg_Char (Text (P));
            P := P + 1;

         --  Upper case letter (start of reserved word if 2 or more)

         elsif C in 'A' .. 'Z'
           and then P <= Text'Last
           and then Text (P) in 'A' .. 'Z'
         then
            P := P - 1;
            Set_Msg_Insertion_Reserved_Word (Text, P);

         elsif C = '~' then
            Set_Msg_Str (Error_Msg_String (1 .. Error_Msg_Strlen));

         --  Normal character with no special treatment

         else
            Set_Msg_Char (C);
         end if;

      end loop;
   end Set_Msg_Text;

   package body Scanner is separate;

end GPR.Err;

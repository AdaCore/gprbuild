with Ada.Text_IO; use Ada.Text_IO;
package body Ada_Lib is

   X : String := "aaa" & "bbb";

   procedure Do_It_In_Ada is
   begin
      Put_Line ("Done in Ada:" & X);
   end Do_It_In_Ada;

end Ada_Lib;

package Pkg2 is
   procedure Execute;
end;

with Ada.Text_IO; use Ada.Text_IO;
package body Pkg2 is
   procedure Execute is
   begin
      Put_Line ("Pkg2.Execute");
   end;
end;

procedure Main is
   procedure Toto;
   pragma Import (C, Toto, "toto");
begin
   null;
   Toto;
end;


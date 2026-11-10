--  logger_health.adb

package body Logger_Health is

   Missed_Count : Unsigned_16 := 0;
   Error_Count  : Unsigned_16 := 0;

   --  Add one to a count, stopping at the maximum so it can't wrap.
   procedure Bump (Count : in out Unsigned_16) is
   begin
      if Count < Unsigned_16'Last then
         Count := Count + 1;
      end if;
   end Bump;

   procedure Count_Miss is
   begin
      Bump (Missed_Count);
   end Count_Miss;

   procedure Count_Error is
   begin
      Bump (Error_Count);
   end Count_Error;

   function Missed return Unsigned_16 is (Missed_Count);
   function Errors return Unsigned_16 is (Error_Count);

end Logger_Health;

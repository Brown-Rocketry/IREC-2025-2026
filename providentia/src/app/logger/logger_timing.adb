--  logger_timing.adb

with Ada.Real_Time; use Ada.Real_Time;

with Logger_Health;

package body Logger_Timing is

   Tick : constant Time_Span := Microseconds (Tick_Us);

   Deadline   : Time;
   Tick_Count : Unsigned_32 := 0;

   procedure Start is
   begin
      Deadline := Clock + Tick;
   end Start;

   procedure Wait_For_Next_Tick is
   begin
      Tick_Count := Tick_Count + 1;

      if Clock >= Deadline then
         Logger_Health.Count_Miss;
         Deadline := Clock + Tick;
         return;
      end if;

      delay until Deadline;
      Deadline := Deadline + Tick;
   end Wait_For_Next_Tick;

   function Ticks return Unsigned_32 is (Tick_Count);

end Logger_Timing;

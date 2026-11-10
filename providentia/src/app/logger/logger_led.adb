--  logger_led.adb

with Ada.Real_Time; use Ada.Real_Time;
with Interfaces;    use Interfaces;

with Logger_Timing;

package body Logger_Led is

   --  ticks between LED changes, by Flight.Phase'Pos
   type Led_Table is array (0 .. 5) of Positive;
   Led_Every : constant Led_Table := (100, 25, 5, 5, 5, 200);

   Full : Boolean := False;

   procedure Fault_Blink is
   begin
      for I in 1 .. 20 loop
         Payload.Led_Toggle;
         delay until Clock + Milliseconds (50);
      end loop;
   end Fault_Blink;

   procedure Halt_Needs_Dump is
   begin
      loop
         for I in 1 .. 4 loop
            Payload.Led_Toggle;
            delay until Clock + Milliseconds (100);
         end loop;
         delay until Clock + Milliseconds (1_000);
      end loop;
   end Halt_Needs_Dump;

   procedure Show_Full is
   begin
      Full := True;
      Payload.Led_On;
   end Show_Full;

   procedure Update (Phase : Payload.Flight.Phase) is
      Every : constant Unsigned_32 :=
        Unsigned_32 (Led_Every (Payload.Flight.Phase'Pos (Phase)));
   begin
      if not Full and then Logger_Timing.Ticks mod Every = 0 then
         Payload.Led_Toggle;
      end if;
   end Update;

end Logger_Led;

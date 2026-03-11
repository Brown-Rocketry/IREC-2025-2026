with Ada.Real_Time; use Ada.Real_time;

with RP.Clock;
with RP.GPIO;
with Pico;

procedure Blinky_Demo is
begin
   RP.Clock.Initialize (Pico.XOSC_Frequency);
   Pico.LED.Configure (RP.GPIO.Output);
   loop
      delay 1.0;
      Pico.LED.Toggle;
   end loop;
end Blinky_Demo;

with Ada.Real_Time; use Ada.Real_Time;
with Board;
with Gpio;

procedure Providentia is
   Period : constant Time_Span := Milliseconds (500);
   Next   : Time := Clock;
begin
   Board.Initialize;

   loop
      Gpio.Toggle (Board.Led);
      Next := Next + Period;
      delay until Next;
   end loop;
end Providentia;

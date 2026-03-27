with Board;
with Gpio;
with Gpio_Types;

procedure Blinky_0 is
begin
   Board.Init_Led_Gpio;
   loop
      Gpio.Toggle (Board.LED);
      delay 1.0;
   end loop;
end Blinky_0;
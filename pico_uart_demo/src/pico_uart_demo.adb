with RP.Device;  use RP.Device;
with RP.GPIO;    use RP.GPIO;
with RP.UART;
with RP.Clock;

with Pico;

with HAL.UART;   use HAL.UART;

procedure Pico_Uart_Demo is
   UART    : RP.UART.UART_Port renames RP.Device.UART_0;
   UART_TX : RP.GPIO.GPIO_Point renames Pico.GP0;
   UART_RX : RP.GPIO.GPIO_Point renames Pico.GP1;

   Status  : UART_Status;

   procedure Send_Hello is
      Hello       : constant String := "Hello, Pico!" & ASCII.CR & ASCII.LF;
      Hello_Bytes : UART_Data_8b (1 .. Hello'Length);
   begin
      for I in Hello'Range loop
         Hello_Bytes (I) := Character'Pos (Hello (I));
      end loop;
      UART.Transmit (Hello_Bytes, Status);
   end Send_Hello;

begin
   RP.Clock.Initialize (Pico.XOSC_Frequency);
   RP.Clock.Enable (RP.Clock.PERI);
   RP.Device.Timer.Enable;
   RP.GPIO.Enable;
   Pico.LED.Configure (Output);

   UART_TX.Configure (Output, Pull_Up, RP.GPIO.UART);
   UART_RX.Configure (Input, Floating, RP.GPIO.UART);
   UART.Configure
      (Config =>
         (Baud      => 115_200,
          Word_Size => 8,
          Parity    => False,
          Stop_Bits => 1,
          others    => <>));

   loop
      Send_Hello;
      Pico.LED.Toggle;
      RP.Device.Timer.Delay_Milliseconds (1000);
   end loop;
end Pico_Uart_Demo;
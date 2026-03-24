with RP.GPIO; use RP.GPIO;
with RP.Clock;
with RP.Device;
with RP.I2C_Master;
with RP.UART;
with HAL; use HAL;
with HAL.I2C; use HAL.I2C;
with HAL.UART; use HAL.UART;
with Pico;

procedure i2c_demo is
   UART    : RP.UART.UART_Port renames RP.Device.UART_1;
   UART_TX : GPIO_Point := (Pin => 8);
   UART_RX : GPIO_Point := (Pin => 9);
   Status  : UART_Status;

   SDA : GPIO_Point := (Pin => 0);
   SCL : GPIO_Point := (Pin => 1);

   --  SDO/SA0 pulled HIGH by Adafruit breakout
   --  HAL expects 7-bit addresses; it shifts left internally
   Addr_AG  : constant HAL.I2C.I2C_Address := 16#D6#;  -- 0x6B shifted left = 0xD6
   Addr_Mag : constant HAL.I2C.I2C_Address := 16#3C#;  -- 0x1E shifted left = 0x3C

   REG_WHO_AM_I : constant UInt8 := 16#0F#;
   --  AG  WHO_AM_I expected: 0x68
   --  Mag WHO_AM_I expected: 0x3D

   procedure Put_Line (S : String) is
      Bytes : UART_Data_8b (1 .. S'Length + 2);
   begin
      for I in S'Range loop
         Bytes (I - S'First + 1) := Character'Pos (S (I));
      end loop;
      Bytes (S'Length + 1) := Character'Pos (ASCII.CR);
      Bytes (S'Length + 2) := Character'Pos (ASCII.LF);
      UART.Transmit (Bytes, Status);
   end Put_Line;

   procedure Read_Who_Am_I
      (Label    : String;
       Addr     : HAL.I2C.I2C_Address;
       Expected : UInt8)
   is
      Port   : RP.I2C_Master.I2C_Master_Port renames RP.Device.I2CM_0;
      Data   : I2C_Data (1 .. 1);
      Stat   : HAL.I2C.I2C_Status;
   begin
      Put_Line ("Reading WHO_AM_I for " & Label);
      Port.Mem_Read
         (Addr          => Addr,
          Mem_Addr      => UInt16 (REG_WHO_AM_I),
          Mem_Addr_Size => Memory_Size_8b,
          Data          => Data,
          Status        => Stat,
          Timeout       => 1000);
      if Stat /= HAL.I2C.Ok then
         Put_Line (Label & ": ERR status=" & Stat'Image);
      elsif Data (1) = Expected then
         Put_Line (Label & ": WHO_AM_I=" & Data (1)'Image & " [OK]");
      else
         Put_Line (Label & ": WHO_AM_I=" & Data (1)'Image
                   & " [UNEXPECTED, expected" & Expected'Image & "]");
      end if;
   end Read_Who_Am_I;

   procedure I2C_Scan is
      Port   : RP.I2C_Master.I2C_Master_Port renames RP.Device.I2CM_0;
      Data   : I2C_Data (1 .. 1);
      Stat   : HAL.I2C.I2C_Status;
   begin
      Put_Line ("Scanning I2C bus (7-bit addrs 1..127)...");
      for Addr in HAL.I2C.I2C_Address range 1 .. 127 loop
         Port.Mem_Read
            (Addr          => Addr,
             Mem_Addr      => 0,
             Mem_Addr_Size => Memory_Size_8b,
             Data          => Data,
             Status        => Stat,
             Timeout       => 50);
         if Stat = HAL.I2C.Ok then
            Put_Line ("Found device at 7-bit addr: " & Addr'Image);
         end if;
         --  if Stat /= HAL.I2C.Ok then
         --     Put_Line ("nothing @: " & Addr'Image);
         end if;
      end loop;
      Put_Line ("Scan complete.");
   end I2C_Scan;

begin
   RP.Clock.Initialize (12_000_000);
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

   Put_Line ("UART ready");

   SDA.Configure (Output, Pull_Up, RP.GPIO.I2C, Schmitt => True);
   SCL.Configure (Output, Pull_Up, RP.GPIO.I2C, Schmitt => True);
   RP.Device.I2CM_0.Configure (Baudrate => 100_000);
   Put_Line ("I2C ready");

   Put_Line ("Timer check...");
   RP.Device.Timer.Delay_Milliseconds (500);
   Put_Line ("Timer OK (500ms elapsed)");

   I2C_Scan;

   loop
      Read_Who_Am_I ("LSM9DS1 AG",  Addr_AG,  16#68#);
      Read_Who_Am_I ("LSM9DS1 Mag", Addr_Mag, 16#3D#);
      Pico.LED.Toggle;
      RP.Device.Timer.Delay_Milliseconds (3000);
   end loop;
end i2c_demo;
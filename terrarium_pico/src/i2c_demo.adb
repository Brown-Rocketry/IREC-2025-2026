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

   --  SHT30 fixed address 0x44
   --  HAL shifts internally so pass 8-bit: 0x44 << 1 = 0x88
   Addr_SHT : constant HAL.I2C.I2C_Address := 16#88#;

   --  SHT30 status register 0xF32D (16-bit command)
   --  For a simple presence check we just attempt a read
   REG_STATUS : constant UInt8 := 16#F3#;

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

   procedure Check_SHT30 is
      Port   : RP.I2C_Master.I2C_Master_Port renames RP.Device.I2CM_0;
      Data   : I2C_Data (1 .. 3);
      Stat   : HAL.I2C.I2C_Status;
   begin
      Put_Line ("Checking SHT30...");
      Port.Mem_Read
         (Addr          => Addr_SHT,
          Mem_Addr      => UInt16 (REG_STATUS),
          Mem_Addr_Size => Memory_Size_8b,
          Data          => Data,
          Status        => Stat,
          Timeout       => 1000);
      if Stat /= HAL.I2C.Ok then
         Put_Line ("SHT30: ERR status=" & Stat'Image);
      else
         Put_Line ("SHT30: responded [OK] status bytes="
                   & Data (1)'Image & Data (2)'Image & Data (3)'Image);
      end if;
   end Check_SHT30;

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
      Check_SHT30;
      Pico.LED.Toggle;
      RP.Device.Timer.Delay_Milliseconds (3000);
   end loop;
end i2c_demo;
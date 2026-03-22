with RP.GPIO; use RP.GPIO;
with RP.Clock;
with RP.Device;
with RP.I2C_Master;
with RP.UART;
with HAL; use HAL;
with HAL.I2C; use HAL.I2C;
with HAL.UART; use HAL.UART;
--  with Ada.Text_IO; use Ada.Text_IO;
with Pico;

procedure i2c_demo is
   -- UART configuring
   UART    : RP.UART.UART_Port renames RP.Device.UART_0;
   UART_TX : RP.GPIO.GPIO_Point renames Pico.GP0;
   UART_RX : RP.GPIO.GPIO_Point renames Pico.GP1;

   Status  : UART_Status;

   SDA : GPIO_Point := (Pin => 2);
   SCL : GPIO_Point := (Pin => 3);

   --  LSM9DS1 has two I2C devices on the bus.
   --  SA0/SDO pin HIGH (pulled up) gives these default addresses:
   --    AG  = 0x6B -> 8-bit write = 0xD6, read = 0xD7
   --    Mag = 0x1E -> 8-bit write = 0x3C, read = 0x3D
   --  Addr_AG  : constant HAL.I2C.I2C_Address := 2#11010110#;  -- 0xD6
   --  Addr_Mag : constant HAL.I2C.I2C_Address := 2#00111100#;  -- 0x3C

   --  7-bit addresses (SDO/SA0 pulled HIGH)
   -- HAL auto shifts them left and adds a zero
   Addr_AG  : constant HAL.I2C.I2C_Address := 16#6B#;  -- was 0xD6
   Addr_Mag : constant HAL.I2C.I2C_Address := 16#1E#;  -- was 0x3C

   --  WHO_AM_I registers
   REG_WHO_AM_I_AG  : constant UInt8 := 16#0F#;  -- expected: 0x68
   REG_WHO_AM_I_MAG : constant UInt8 := 16#0F#;  -- expected: 0x3D

   procedure Put_Line(S : String) is
      Bytes  : UART_Data_8b (1 .. S'Length + 2);
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
       Reg      : UInt8;
       Expected : UInt8)
   is
      Port   : RP.I2C_Master.I2C_Master_Port renames RP.Device.I2CM_0;
      Data   : I2C_Data (1 .. 1);
      Status : HAL.I2C.I2C_Status;
   begin
      -- moved to procedure
      --  Port.Configure (Baudrate => 100_000);
      Put_Line ("entering Mem_Read for " & Label);

      Port.Mem_Read
         (Addr          => Addr,
          Mem_Addr      => UInt16 (Reg),
          Mem_Addr_Size => Memory_Size_8b,
          Data          => Data,
          Status        => Status,
          Timeout       => 1000);

      if Status /= HAL.I2C.Ok then
         Put_Line (Label & ": read error (status=" & Status'Image & ")");
         return;
      end if;

      --  Put (Label & " WHO_AM_I:" & Data (1)'Image);
      if Data (1) = Expected then
         Put_Line (Label & " WHO_AM_I=" & Data (1)'Image & " [OK]");
      else
         Put_Line (Label & " WHO_AM_I=" & Data (1)'Image & " [UNEXPECTED, expected" & Expected'Image & "]");
      end if;
   end Read_Who_Am_I;

   procedure I2C_Scan is
      Port   : RP.I2C_Master.I2C_Master_Port renames RP.Device.I2CM_0;
      Data   : I2C_Data (1 .. 1);
      Status : HAL.I2C.I2C_Status;
   begin
      Put_Line ("Scanning I2C bus...");
      for Addr in HAL.I2C.I2C_Address range 1 .. 127 loop
         Port.Mem_Read
            (Addr          => Addr,
            Mem_Addr      => 0,
            Mem_Addr_Size => Memory_Size_8b,
            Data          => Data,
            Status        => Status,
            Timeout       => 100);
         if Status = HAL.I2C.Ok then
            Put_Line ("Found device at: " & Addr'Image);
         end if;
      end loop;
      Put_Line ("Scan complete.");
   end I2C_Scan;

begin
   --  RP.Clock.Initialize (12_000_000);
   RP.Clock.Initialize (Pico.XOSC_Frequency);
   RP.Clock.Enable (RP.Clock.PERI);
   RP.GPIO.Enable;
   RP.Device.Timer.Enable;

   -- config LED for later debugging purposes
   Pico.LED.Configure (Output);

   -- UART  configure
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

   -- LSM configure
   SDA.Configure (Output, Pull_Up, RP.GPIO.I2C, Schmitt => True);
   SCL.Configure (Output, Pull_Up, RP.GPIO.I2C, Schmitt => True);
   RP.Device.I2CM_0.Configure (Baudrate => 100_000);

   Put_Line ("I2C ready");


   I2C_Scan;
   
   loop
      Put_Line ("loop start");

      Read_Who_Am_I
         (Label    => "LSM9DS1 Accel/Gyro",
          Addr     => Addr_AG,
          Reg      => REG_WHO_AM_I_AG,
          Expected => 16#68#);

      Read_Who_Am_I
         (Label    => "LSM9DS1 Mag",
          Addr     => Addr_Mag,
          Reg      => REG_WHO_AM_I_MAG,
          Expected => 16#3D#);

      Pico.LED.Toggle;
      RP.Device.Timer.Delay_Milliseconds (100);
   end loop;
end i2c_demo;
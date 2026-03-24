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


   --  7-bit addresses (SDO/SA0 pulled HIGH)
   -- HAL auto shifts them left and adds a zero
   Addr_BMP : constant HAL.I2C.I2C_Address := 16#EE#;  

   --  WHO_AM_I registers
   REG_WHO_AM_I_BMP : constant UInt8 := 16#00#;  -- expected: 0x60

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
   Port    : RP.I2C_Master.I2C_Master_Port renames RP.Device.I2CM_0;
   Data    : I2C_Data (1 .. 1) := (others => 0);
   Status  : HAL.I2C.I2C_Status;
   Count   : Natural := 0;
begin
   Put_Line ("Scanning I2C bus...");
   for Addr in HAL.I2C.I2C_Address range 16 .. 238 loop
      if Addr mod 2 = 0 then
         Count := Count + 1;
         Port.Master_Transmit
            (Addr    => Addr,
             Data    => Data,
             Status  => Status,
             Timeout => 50);
         if Status = HAL.I2C.Ok then
            Put_Line ("Found device at 8-bit addr: " & Addr'Image);
         end if;
         Pico.LED.Toggle;
      end if;
   end loop;
   Put_Line ("Scan complete. Tried " & Count'Image & " addresses.");
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

   -- BSM configure
   SDA.Configure (Output, Pull_Up, RP.GPIO.I2C, Schmitt => True);
   SCL.Configure (Output, Pull_Up, RP.GPIO.I2C, Schmitt => True);
   Put_Line ("Configuring I2C...");
   RP.Device.I2CM_0.Configure (Baudrate => 100_000);
   Put_Line ("I2C configured");

   Put_Line ("I2C ready");
   Put_Line ("Timer test start");
   RP.Device.Timer.Delay_Milliseconds (500);
   Put_Line ("Timer test end (should be ~500ms later)");

   I2C_Scan;

   loop
      Read_Who_Am_I
         (Label    => "BMP390",
         Addr     => Addr_BMP,
         Reg      => REG_WHO_AM_I_BMP,
         Expected => 16#60#);

      Pico.LED.Toggle;
      RP.Device.Timer.Delay_Milliseconds (3000);
   end loop;
end i2c_demo;
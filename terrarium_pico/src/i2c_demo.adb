with RP.GPIO; use RP.GPIO;
with RP.Clock;
with RP.Device;
with RP.I2C_Master;
with RP.UART;
with HAL; use HAL;
with HAL.I2C; use HAL.I2C;
with HAL.UART; use HAL.UART;
with Pico;
with Interfaces; use Interfaces;

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
   CTRL_REG6_XL : constant UInt8 := 16#20#;
   OUT_X_L_XL : constant UInt8 := 16#28#;
   -- read 6 bytes from this, 2 bytes for x y and z

   ODR_XL : constant UInt8 := 16#60#;
   -- bits: 0 1 1  0 0  0  0 0
   -- ODR=011 FS=00 BW_SCAL=0 BW=00
   -- values scale to +- 2g at max and min

   procedure Put_Line (S : String) is
      Bytes : UART_Data_8b (1 .. S'Length + 2);
   begin
      for I in S'Range loop
         Bytes (I - S'First + 1) := Character'Pos (S (I));
      end loop;
      Bytes (S'Length + 1) := Character'Pos (ASCII.CR);
      Bytes (S'Length + 2) := Character'Pos (ASCII.LF);
      UART.Transmit (Bytes, Status);
      for I in 1 .. 10_000 loop
         null;
      end loop;
   end Put_Line;

   procedure Read_Data
      (Label    : String;
       Addr     : HAL.I2C.I2C_Address)
   is
      Port   : RP.I2C_Master.I2C_Master_Port renames RP.Device.I2CM_0;
      Data   : I2C_Data (1 .. 6);
      Stat   : HAL.I2C.I2C_Status;
      Raw    : Integer_16;
   begin
      Put_Line ("Reading Data for " & Label);
      Port.Mem_Read
        (Addr          => Addr,
         Mem_Addr      => UInt16 (OUT_X_L_XL),
         Mem_Addr_Size => Memory_Size_8b,
         Data          => Data,
         Status        => Stat,
         Timeout       => 1000);
      if Stat /= HAL.I2C.Ok then
         Put_Line (Label & ": ERR status=" & Stat'Image);
      else
         for Coord in 1 .. 3 loop
            -- low first then high?
            declare
               Lo  : Unsigned_16 := Unsigned_16(Data(2*Coord - 1));
               Hi  : Unsigned_16 := Unsigned_16(Data(2*Coord));
               U   : Unsigned_16 := Hi * 256 + Lo;
               S   : Integer_32  := Integer_32(U);
            begin
               -- trick giving a sign to correct for the unsigned version, using this trick because converting an integer to string causes a hanging
               if S > 32767 then
                  S := S - 65536;
               end if;
               Raw := Integer_16(S);
               case Coord is
                  when 1 => Put_Line (Label & ": X=" & Raw'Image);
                  when 2 => Put_Line (Label & ": Y=" & Raw'Image);
                  when 3 => Put_Line (Label & ": Z=" & Raw'Image);
               end case;
            end;
         end loop;
      end if;
   end Read_Data;

   procedure Enable_Sensor
     (Label    : String;
      Addr     : HAL.I2C.I2C_Address; 
      Code     : UInt8)
   is
      Port   : RP.I2C_Master.I2C_Master_Port renames RP.Device.I2CM_0;
      Data   : I2C_Data (1 .. 1) := (1 => Code);
      Stat   : HAL.I2C.I2C_Status;
   begin
      Put_Line ("Enable for " & Label);
      Port.Mem_Write
           (Addr          => Addr,
            Mem_Addr      => UInt16 (CTRL_REG6_XL),
            Mem_Addr_Size => Memory_Size_8b,
            Data          => Data,
            Status        => Stat,
            Timeout       => 1000);
      if Stat /= HAL.I2C.Ok then
         Put_Line ("Enable failed: " & Stat'Image);
      end if;
   end Enable_Sensor;


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

   SDA.Configure (Output, Pull_Up, RP.GPIO.I2C, Schmitt => True);
   SCL.Configure (Output, Pull_Up, RP.GPIO.I2C, Schmitt => True);
   RP.Device.I2CM_0.Configure (Baudrate => 100_000);
   
   Put_Line ("Starting..."); 

   Enable_Sensor ("LSM9DS1 AG", Addr_AG, ODR_XL);

   loop
      Put_Line ("loop");  
      Read_Data ("LSM9DS1 AG", Addr_AG);
      RP.Device.Timer.Delay_Milliseconds (3000);
      Pico.LED.Toggle;
   end loop;
end i2c_demo;
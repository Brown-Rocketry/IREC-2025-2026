with RP.GPIO; use RP.GPIO;
with RP.Clock;
with RP.Device;
with RP.I2C_Master;
with HAL; use HAL;
with HAL.I2C; use HAL.I2C;
with Ada.Text_IO; use Ada.Text_IO;

procedure i2c_demo is
   SDA : GPIO_Point := (Pin => 2);
   SCL : GPIO_Point := (Pin => 3);

   --  LSM9DS1 has two I2C devices on the bus.
   --  SA0/SDO pin HIGH (pulled up) gives these default addresses:
   --    AG  = 0x6B -> 8-bit write = 0xD6, read = 0xD7
   --    Mag = 0x1E -> 8-bit write = 0x3C, read = 0x3D
   Addr_AG  : constant HAL.I2C.I2C_Address := 2#11010110#;  -- 0xD6
   Addr_Mag : constant HAL.I2C.I2C_Address := 2#00111100#;  -- 0x3C

   --  WHO_AM_I registers
   REG_WHO_AM_I_AG  : constant UInt8 := 16#0F#;  -- expected: 0x68
   REG_WHO_AM_I_MAG : constant UInt8 := 16#0F#;  -- expected: 0x3D

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
      Port.Configure (Baudrate => 100_000);
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

      Put (Label & " WHO_AM_I:" & Data (1)'Image);
      if Data (1) = Expected then
         Put_Line ("  [OK]");
      else
         Put_Line ("  [UNEXPECTED, expected" & Expected'Image & "]");
      end if;
   end Read_Who_Am_I;

begin
   RP.Clock.Initialize (12_000_000);
   SDA.Configure (Output, Pull_Up, RP.GPIO.I2C, Schmitt => True);
   SCL.Configure (Output, Pull_Up, RP.GPIO.I2C, Schmitt => True);
   RP.Device.Timer.Enable;

   loop
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

      RP.Device.Timer.Delay_Milliseconds (100);
   end loop;
end i2c_demo;
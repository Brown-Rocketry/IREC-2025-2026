-- flight_logger.adb
-- Reads LSM9DS1 (accel/gyro/mag) and BMP390, packs 28-byte samples into
-- 256-byte pages, and writes sequentially to W25Q128 SPI flash.
--
-- Sample format (28 bytes):
--   0-3:   Timestamp  (Unsigned_32, microseconds, LSB first)
--   4-5:   Accel X    (Int16, LSB first)
--   6-7:   Accel Y
--   8-9:   Accel Z
--   10-11: Gyro X
--   12-13: Gyro Y
--   14-15: Gyro Z
--   16-17: Mag X
--   18-19: Mag Y
--   20-21: Mag Z
--   22-24: Pressure raw (24-bit, LSB first)
--   25-27: Temperature raw (24-bit, LSB first)
--
-- Page layout (256 bytes):
--   Bytes 0-251:   9 samples x 28 bytes = 252 bytes
--   Bytes 252-255: Page sequence number (Unsigned_32, LSB first)

with RP.SPI;         use RP.SPI;
with RP2040_SVD.SPI;
with RP2040_SVD.TIMER;
with RP.GPIO;        use RP.GPIO;
with RP.Device;
with RP.Clock;
with RP.I2C_Master;
with RP.UART;
with HAL;            use HAL;
with HAL.SPI;
with HAL.I2C;        use HAL.I2C;
with HAL.UART;       use HAL.UART;
with Pico;
with Interfaces;     use Interfaces;

procedure Flight_Logger is

   ----------------------------------------------------------------------------
   --  UART
   ----------------------------------------------------------------------------
   UART    : RP.UART.UART_Port renames RP.Device.UART_1;
   UART_TX : GPIO_Point := (Pin => 8);
   UART_RX : GPIO_Point := (Pin => 9);
   U_Stat  : UART_Status;

   ----------------------------------------------------------------------------
   --  I2C pins
   ----------------------------------------------------------------------------
   SDA : GPIO_Point := (Pin => 0);
   SCL : GPIO_Point := (Pin => 1);

   ----------------------------------------------------------------------------
   --  SPI / flash pins
   ----------------------------------------------------------------------------
   MISO_Pin : GPIO_Point := (Pin => 16);
   CS_Pin   : GPIO_Point := (Pin => 17);
   SCK_Pin  : GPIO_Point := (Pin => 18);
   MOSI_Pin : GPIO_Point := (Pin => 19);

   SPI_Port : RP.SPI.SPI_Port renames RP.Device.SPI_0;

   ----------------------------------------------------------------------------
   --  I2C addresses  (8-bit form — HAL shifts right internally)
   ----------------------------------------------------------------------------
   Addr_AG  : constant HAL.I2C.I2C_Address := 16#D6#;  -- LSM9DS1 accel/gyro
   Addr_Mag : constant HAL.I2C.I2C_Address := 16#3C#;  -- LSM9DS1 mag
   Addr_BMP : constant HAL.I2C.I2C_Address := 16#EE#;  -- BMP390 (SDO high)

   ----------------------------------------------------------------------------
   --  LSM9DS1 registers
   ----------------------------------------------------------------------------
   CTRL_REG6_XL : constant UInt8 := 16#20#;
   CTRL_REG1_G  : constant UInt8 := 16#10#;
   CTRL_REG1_M  : constant UInt8 := 16#20#;
   CTRL_REG3_M  : constant UInt8 := 16#22#;
   OUT_X_L_XL   : constant UInt8 := 16#28#;
   OUT_X_L_G    : constant UInt8 := 16#18#;
   OUT_X_L_M    : constant UInt8 := 16#28#;
   --  ODR_XL       : constant UInt8 := 16#60#;
   --  ODR_G        : constant UInt8 := 16#68#;
   --  ODR_M1       : constant UInt8 := 16#10#;
   --  ODR_M3       : constant UInt8 := 16#00#;
   ODR_XL       : constant UInt8 := 2#01101000#;
   --  (ODR 119Hz, FS ±16g)
   ODR_G        : constant UInt8 := 2#01111000#;
   --  (ODR 119Hz, FS ±2000dps)
   ODR_M1       : constant UInt8 := 2#11110000#;
   --  (temp comp, XY ultra-high perf, ODR 10Hz)
   ODR_M3       : constant UInt8 := 16#00#;
   -- (continuous mode, already correct)

   ----------------------------------------------------------------------------
   --  BMP390 registers
   ----------------------------------------------------------------------------
   CTRL_PWR_BMP  : constant UInt8 := 16#1B#;
   OUT_BMP       : constant UInt8 := 16#04#;
   SETTINGS_BMP  : constant UInt8 := 16#33#;

   ----------------------------------------------------------------------------
   --  W25Q128 flash commands
   ----------------------------------------------------------------------------
   CMD_WRITE_ENABLE : constant := 16#06#;
   CMD_SECTOR_ERASE : constant := 16#20#;
   CMD_PAGE_PROGRAM : constant := 16#02#;
   CMD_READ_STATUS  : constant := 16#05#;
   CMD_JEDEC_ID     : constant := 16#9F#;

   ----------------------------------------------------------------------------
   --  Flash geometry
   ----------------------------------------------------------------------------
   SAMPLES_PER_PAGE : constant := 9;
   SAMPLE_SIZE      : constant := 28;
   PAGE_SIZE        : constant := 256;

   -- Total flash = 16 MB = 16,777,216 bytes
   -- Pages        = 65,536 (each 256 bytes)
   -- Sectors      = 4,096  (each 4 KB = 16 pages)
   -- We erase sector by sector as we advance through flash.
   -- Sector 0 is erased at startup; subsequent sectors erased on demand.
   SECTOR_SIZE      : constant := 4096;
   PAGES_PER_SECTOR : constant := 16;
   MAX_PAGE         : constant := 65_535;

   TEST_ADDR : constant := 16#000000#;

   ----------------------------------------------------------------------------
   --  State
   ----------------------------------------------------------------------------
   SPI_Stat : HAL.SPI.SPI_Status;
   Busy_Buf : HAL.SPI.SPI_Data_8b (1 .. 1);

   -- Page buffer: 252 bytes of samples + 4 bytes sequence number
   Page_Buf    : HAL.SPI.SPI_Data_8b (1 .. PAGE_SIZE) := (others => 0);
   Sample_Idx  : Natural := 0;      -- 0..8, samples written into current page
   Page_Num    : Unsigned_32 := 0;  -- sequence number stamped into each page
   Write_Addr  : Natural := 0;      -- byte address in flash for next page write

   ----------------------------------------------------------------------------
   --  UART helpers
   ----------------------------------------------------------------------------
   procedure Put_Line (S : String) is
      Bytes : UART_Data_8b (1 .. S'Length + 2);
   begin
      for I in S'Range loop
         Bytes (I - S'First + 1) := Character'Pos (S (I));
      end loop;
      Bytes (S'Length + 1) := Character'Pos (ASCII.CR);
      Bytes (S'Length + 2) := Character'Pos (ASCII.LF);
      UART.Transmit (Bytes, U_Stat);
      for I in 1 .. 10_000 loop null; end loop;
   end Put_Line;

   ----------------------------------------------------------------------------
   --  SPI low-level helpers
   --
   --  All flash transactions use Transfer exclusively — never Send_Byte or
   --  Send_Address (HAL Transmit) — so that CS_High is always called after
   --  the last byte has fully clocked out.  HAL Transmit returns as soon as
   --  bytes are queued in the TX FIFO, which can cause CS_High to fire while
   --  bytes are still in flight, producing truncated transactions that the
   --  flash chip silently rejects.
   --
   --  Transfer is synchronous: it waits for TNF before writing each byte and
   --  waits for RNE before reading it back, so by the time it returns every
   --  bit has been clocked on the wire.
   ----------------------------------------------------------------------------
   procedure CS_Low is
   begin
      CS_Pin.Clear;
      RP.Device.Timer.Delay_Milliseconds (1);
   end CS_Low;

   procedure CS_High is
   begin
      CS_Pin.Set;
      RP.Device.Timer.Delay_Milliseconds (1);
   end CS_High;

   -- Full-duplex byte-by-byte transfer via SVD registers.
   -- Fully synchronous: each byte is completely clocked before moving on.
   procedure Transfer (TX : HAL.SPI.SPI_Data_8b;
                       RX : out HAL.SPI.SPI_Data_8b) is
      Periph : RP2040_SVD.SPI.SPI_Peripheral renames SPI_Port.Periph.all;
   begin
      for I in TX'Range loop
         while not Periph.SSPSR.TNF loop null; end loop;
         Periph.SSPDR.DATA := RP2040_SVD.SPI.SSPDR_DATA_Field (TX (I));
         while not Periph.SSPSR.RNE loop null; end loop;
         RX (I) := HAL.UInt8 (Periph.SSPDR.DATA);
      end loop;
   end Transfer;

   --  procedure Send_Byte (Cmd : HAL.UInt8) is
   --     Buf : constant HAL.SPI.SPI_Data_8b (1 .. 1) := (1 => Cmd);
   --  begin
   --     SPI_Port.Transmit (Buf, SPI_Stat);  -- was Status
   --  end Send_Byte;

   --  procedure Send_Address (Addr : Natural) is
   --     Buf : constant HAL.SPI.SPI_Data_8b (1 .. 3) :=
   --     (1 => HAL.UInt8 (Addr / 65536),
   --        2 => HAL.UInt8 ((Addr / 256) mod 256),
   --        3 => HAL.UInt8 (Addr mod 256));
   --  begin
   --     SPI_Port.Transmit (Buf, SPI_Stat);  -- was Status
   --  end Send_Address;

   -- Convenience: build a 3-byte address array for Transfer calls.
   function Addr_Bytes (Addr : Natural) return HAL.SPI.SPI_Data_8b is
      Result : HAL.SPI.SPI_Data_8b (1 .. 3);
   begin
      Result (1) := HAL.UInt8 (Addr / 65536);
      Result (2) := HAL.UInt8 ((Addr / 256) mod 256);
      Result (3) := HAL.UInt8 (Addr mod 256);
      return Result;
   end Addr_Bytes;

   ----------------------------------------------------------------------------
   --  Wait for the WIP (Write In Progress) bit to clear.
   --  Uses Transfer throughout so the status read is also fully synchronous.
   ----------------------------------------------------------------------------
   procedure Wait_Until_Ready is
      S     : HAL.UInt8;
      Count : Natural := 0;
      Cmd   : constant HAL.SPI.SPI_Data_8b (1 .. 1) := (1 => HAL.UInt8 (CMD_READ_STATUS));
      Dummy : constant HAL.SPI.SPI_Data_8b (1 .. 1) := (others => 0);
      Junk  : HAL.SPI.SPI_Data_8b (1 .. 1);
   begin
      loop
         CS_Low;
         Transfer (Cmd,   Junk);       -- send READ_STATUS, discard echo
         Transfer (Dummy, Busy_Buf);   -- clock one dummy, receive status byte
         CS_High;
         S := Busy_Buf (1);
         --  if Count mod 10 = 0 then
         --     Put_Line ("WIP #" & Count'Image &
         --               " S="   & Integer'Image (Integer (S)) &
         --               " WIP=" & Integer'Image (Integer (S and 1)) &
         --               " WEL=" & Integer'Image (Integer ((S / 2) and 1)));
         --  end if;
         exit when (S and 16#01#) = 0;
         Count := Count + 1;
         if Count > 1000 then
            Put_Line ("TIMEOUT - chip not responding");
            return;
         end if;
      end loop;
   end Wait_Until_Ready;

   procedure Write_Enable is
      Cmd  : constant HAL.SPI.SPI_Data_8b (1 .. 1) := (1 => HAL.UInt8 (CMD_WRITE_ENABLE));
      Junk : HAL.SPI.SPI_Data_8b (1 .. 1);
   begin
      CS_Low;
      Transfer (Cmd, Junk);
      CS_High;
   end Write_Enable;

   ----------------------------------------------------------------------------
   --  Write Enable — must precede every erase or program command.
   --  Uses Transfer so CS_High only fires after 0x06 has fully clocked out.
   ----------------------------------------------------------------------------
   procedure Write_Page (Data : HAL.SPI.SPI_Data_8b) is
      Cmd   : constant HAL.SPI.SPI_Data_8b (1 .. 1) := (1 => HAL.UInt8 (CMD_PAGE_PROGRAM));
      Addr3 : constant HAL.SPI.SPI_Data_8b (1 .. 3) := (1 => 0, 2 => 0, 3 => 0);
      Junk1 : HAL.SPI.SPI_Data_8b (1 .. 1);
      Junk3 : HAL.SPI.SPI_Data_8b (1 .. 3);
      JunkD : HAL.SPI.SPI_Data_8b (1 .. PAGE_SIZE);
   begin
      Write_Enable;
      CS_Low;
      Transfer (Cmd,   Junk1);
      Transfer (Addr3, Junk3);
      Transfer (Data,  JunkD);
      CS_High;
      Wait_Until_Ready;
   end Write_Page;

   ----------------------------------------------------------------------------
   --  Erase one 4 KB sector at byte address Addr (must be sector-aligned).
   --  Uses Transfer for command and address so CS_High is always safe.
   ----------------------------------------------------------------------------
   procedure Erase_Sector (Addr : Natural) is
      Cmd   : constant HAL.SPI.SPI_Data_8b (1 .. 1) := (1 => HAL.UInt8 (CMD_SECTOR_ERASE));
      Addr3 : constant HAL.SPI.SPI_Data_8b (1 .. 3) := Addr_Bytes (Addr);
      Junk1 : HAL.SPI.SPI_Data_8b (1 .. 1);
      Junk3 : HAL.SPI.SPI_Data_8b (1 .. 3);
   begin
      Write_Enable;
      CS_Low;
      Transfer (Cmd,   Junk1);
      Transfer (Addr3, Junk3);
      CS_High;
      Wait_Until_Ready;
   end Erase_Sector;

   ----------------------------------------------------------------------------
   --  Write exactly 256 bytes to the flash page at byte address Addr.
   --  Uses Transfer for command, address, and data payload.
   ----------------------------------------------------------------------------
   procedure Write_Page_To_Flash (Data : HAL.SPI.SPI_Data_8b; Addr : Natural) is
      Cmd   : constant HAL.SPI.SPI_Data_8b (1 .. 1) := (1 => HAL.UInt8 (CMD_PAGE_PROGRAM));
      Addr3 : constant HAL.SPI.SPI_Data_8b (1 .. 3) := Addr_Bytes (Addr);
      Junk1 : HAL.SPI.SPI_Data_8b (1 .. 1);
      Junk3 : HAL.SPI.SPI_Data_8b (1 .. 3);
      JunkD : HAL.SPI.SPI_Data_8b (1 .. PAGE_SIZE);
   begin
      Write_Enable;
      CS_Low;
      Transfer (Cmd,  Junk1);
      Transfer (Addr3, Junk3);
      Transfer (Data, JunkD);
      CS_High;
      Wait_Until_Ready;
   end Write_Page_To_Flash;

   ----------------------------------------------------------------------------
   --  I2C helpers
   ----------------------------------------------------------------------------
   procedure Enable_Sensor (Addr     : HAL.I2C.I2C_Address;
                             Mem_Addr : UInt8;
                             Code     : UInt8;
                             Label    : String) is
      Port : RP.I2C_Master.I2C_Master_Port renames RP.Device.I2CM_0;
      Data : I2C_Data (1 .. 1) := (1 => Code);
      Stat : HAL.I2C.I2C_Status;
   begin
      Port.Mem_Write
        (Addr          => Addr,
         Mem_Addr      => UInt16 (Mem_Addr),
         Mem_Addr_Size => Memory_Size_8b,
         Data          => Data,
         Status        => Stat,
         Timeout       => 1000);
      if Stat /= HAL.I2C.Ok then
         Put_Line ("Enable failed: " & Label & " " & Stat'Image);
      end if;
   end Enable_Sensor;

   procedure Read_IMU_Raw (Addr     : HAL.I2C.I2C_Address;
                           Mem_Addr : UInt8;
                           Data     : out I2C_Data;
                           Ok       : out Boolean) is
      Port : RP.I2C_Master.I2C_Master_Port renames RP.Device.I2CM_0;
      Stat : HAL.I2C.I2C_Status;
   begin
      Port.Mem_Read
        (Addr          => Addr,
         Mem_Addr      => UInt16 (Mem_Addr),
         Mem_Addr_Size => Memory_Size_8b,
         Data          => Data,
         Status        => Stat,
         Timeout       => 1000);
      Ok := (Stat = HAL.I2C.Ok);
   end Read_IMU_Raw;

   procedure Read_BMP_Raw (Data : out I2C_Data;
                           Ok   : out Boolean) is
      Port : RP.I2C_Master.I2C_Master_Port renames RP.Device.I2CM_0;
      Stat : HAL.I2C.I2C_Status;
   begin
      Port.Mem_Read
        (Addr          => Addr_BMP,
         Mem_Addr      => UInt16 (OUT_BMP),
         Mem_Addr_Size => Memory_Size_8b,
         Data          => Data,
         Status        => Stat,
         Timeout       => 1000);
      Ok := (Stat = HAL.I2C.Ok);
   end Read_BMP_Raw;

   ----------------------------------------------------------------------------
   --  Timestamp: lower 32 bits of RP2040 hardware microsecond counter.
   ----------------------------------------------------------------------------
   function Get_Timestamp return Unsigned_32 is
   begin
      return Unsigned_32 (RP2040_SVD.TIMER.TIMER_Periph.TIMERAWL);
   end Get_Timestamp;

   ----------------------------------------------------------------------------
   --  Packing helpers — write into Page_Buf at 1-based Ada index Base+1.
   ----------------------------------------------------------------------------
   procedure Pack_U32 (Val : Unsigned_32; Base : Natural) is
   begin
      Page_Buf (Base + 1) := HAL.UInt8 (Val and 16#FF#);
      Page_Buf (Base + 2) := HAL.UInt8 (Shift_Right (Val,  8) and 16#FF#);
      Page_Buf (Base + 3) := HAL.UInt8 (Shift_Right (Val, 16) and 16#FF#);
      Page_Buf (Base + 4) := HAL.UInt8 (Shift_Right (Val, 24) and 16#FF#);
   end Pack_U32;

   procedure Pack_I16 (Val : Unsigned_16; Base : Natural) is
   begin
      Page_Buf (Base + 1) := HAL.UInt8 (Val and 16#FF#);
      Page_Buf (Base + 2) := HAL.UInt8 (Shift_Right (Val, 8) and 16#FF#);
   end Pack_I16;

   procedure Pack_U24 (Val : Unsigned_32; Base : Natural) is
   begin
      Page_Buf (Base + 1) := HAL.UInt8 (Val and 16#FF#);
      Page_Buf (Base + 2) := HAL.UInt8 (Shift_Right (Val,  8) and 16#FF#);
      Page_Buf (Base + 3) := HAL.UInt8 (Shift_Right (Val, 16) and 16#FF#);
   end Pack_U24;

   procedure Pack_Sample (TS         : Unsigned_32;
                          AX, AY, AZ : Unsigned_16;
                          GX, GY, GZ : Unsigned_16;
                          MX, MY, MZ : Unsigned_16;
                          Press      : Unsigned_32;
                          Temp       : Unsigned_32) is
      Base : constant Natural := Sample_Idx * SAMPLE_SIZE;
   begin
      Pack_U32 (TS,    Base);
      --  declare
      --     B0 : constant HAL.UInt8 := Page_Buf (253);
      --     B1 : constant HAL.UInt8 := Page_Buf (254);
      --     B2 : constant HAL.UInt8 := Page_Buf (255);
      --     B3 : constant HAL.UInt8 := Page_Buf (256);
      --  begin
      --     Put_Line ("SeqBytes: " & B0'Image & " " & B1'Image & " " & B2'Image & " " & B3'Image);
      --  end;
      Pack_I16 (AX,    Base + 4);
      Pack_I16 (AY,    Base + 6);
      Pack_I16 (AZ,    Base + 8);
      Pack_I16 (GX,    Base + 10);
      Pack_I16 (GY,    Base + 12);
      Pack_I16 (GZ,    Base + 14);
      Pack_I16 (MX,    Base + 16);
      Pack_I16 (MY,    Base + 18);
      Pack_I16 (MZ,    Base + 20);
      Pack_U24 (Press, Base + 22);
      Pack_U24 (Temp,  Base + 25);
   end Pack_Sample;

   ----------------------------------------------------------------------------
   --  Flush the current page to flash and advance the write pointer.
   ----------------------------------------------------------------------------
   procedure Flush_Page is
   begin
      Pack_U32 (Page_Num, 252);

      if Write_Addr mod SECTOR_SIZE = 0 then
         Erase_Sector (Write_Addr);
         --  Erase_Sector;
         Put_Line ("Erased sector at " & Write_Addr'Image);
      end if;

      Write_Page_To_Flash (Page_Buf, Write_Addr);
      Put_Line ("Page " & Page_Num'Image & " written at " & Write_Addr'Image);

      Page_Num   := Page_Num + 1;
      Write_Addr := Write_Addr + PAGE_SIZE;
      Sample_Idx := 0;
      Page_Buf   := (others => 0);

      if Write_Addr > MAX_PAGE * PAGE_SIZE then
         Put_Line ("FLASH FULL - halting");
         loop null; end loop;
      end if;
   end Flush_Page;

   ----------------------------------------------------------------------------
   --  Raw byte assembly helpers
   ----------------------------------------------------------------------------
   function To_U16 (Lo : UInt8; Hi : UInt8) return Unsigned_16 is
   begin
      return Unsigned_16 (Hi) * 256 + Unsigned_16 (Lo);
   end To_U16;

   function To_U24 (B0 : UInt8; B1 : UInt8; B2 : UInt8) return Unsigned_32 is
   begin
      return Unsigned_32 (B0) +
             Unsigned_32 (B1) * 256 +
             Unsigned_32 (B2) * 65536;
   end To_U24;

begin
   ----------------------------------------------------------------------------
   --  System init
   ----------------------------------------------------------------------------
   RP.Clock.Initialize (Pico.XOSC_Frequency);
   RP.Clock.Enable (RP.Clock.PERI);
   RP.Device.Timer.Enable;
   RP.GPIO.Enable;
   Pico.LED.Configure (Output);

   ----------------------------------------------------------------------------
   --  UART init
   ----------------------------------------------------------------------------
   UART_TX.Configure (Output, Pull_Up, RP.GPIO.UART);
   UART_RX.Configure (Input,  Floating, RP.GPIO.UART);
   UART.Configure
     (Config =>
        (Baud      => 115_200,
         Word_Size => 8,
         Parity    => False,
         Stop_Bits => 1,
         others    => <>));

   Put_Line ("--- Flight Logger Boot ---");

   ----------------------------------------------------------------------------
   --  SPI / flash init
   ----------------------------------------------------------------------------
   MISO_Pin.Configure (Input,  Floating, RP.GPIO.SPI);
   SCK_Pin.Configure  (Output, Floating, RP.GPIO.SPI);
   MOSI_Pin.Configure (Output, Floating, RP.GPIO.SPI);
   CS_Pin.Configure   (Output, Floating);
   CS_High;
   RP.Device.Timer.Delay_Milliseconds (10);

   SPI_Port.Configure
     (Config =>
        (Role      => RP.SPI.Master,
         Baud      => 10_000_000,
         Data_Size => HAL.SPI.Data_Size_8b,
         Polarity  => RP.SPI.Active_Low,   -- CPOL=0 clock idles low
         Phase     => RP.SPI.Rising_Edge,  -- CPHA=0
         others    => <>));
   Put_Line ("SPI ready");

   ----------------------------------------------------------------------------
   --  Verify JEDEC ID before doing anything destructive
   ----------------------------------------------------------------------------
   declare
      Cmd   : constant HAL.SPI.SPI_Data_8b (1 .. 1) := (1 => HAL.UInt8 (CMD_JEDEC_ID));
      Dummy : constant HAL.SPI.SPI_Data_8b (1 .. 3) := (others => 0);
      Junk  : HAL.SPI.SPI_Data_8b (1 .. 1);
      ID    : HAL.SPI.SPI_Data_8b (1 .. 3);
   begin
      CS_Low;
      Transfer (Cmd,   Junk);
      Transfer (Dummy, ID);
      CS_High;
      declare
         B0 : constant HAL.UInt8 := ID (1);
         B1 : constant HAL.UInt8 := ID (2);
         B2 : constant HAL.UInt8 := ID (3);
      begin
         Put_Line ("JEDEC: " & B0'Image & " " & B1'Image & " " & B2'Image);
         if B0 /= 239 or B1 /= 64 or B2 /= 24 then
            Put_Line ("JEDEC mismatch - check wiring");
         end if;
      end;
   end;

   ----------------------------------------------------------------------------
   --  I2C init (commented out until sensor integration is re-enabled)
   ----------------------------------------------------------------------------
   SDA.Configure (Output, Pull_Up, RP.GPIO.I2C, Schmitt => True);
   SCL.Configure (Output, Pull_Up, RP.GPIO.I2C, Schmitt => True);
   RP.Device.I2CM_0.Configure (Baudrate => 100_000);
   Put_Line ("I2C ready");
   
   ----------------------------------------------------------------------------
   --  Sensors disabled until flash write path is verified
   ----------------------------------------------------------------------------
   Enable_Sensor (Addr_AG,  CTRL_REG6_XL, ODR_XL,  "Accel");
   Enable_Sensor (Addr_AG,  CTRL_REG1_G,  ODR_G,   "Gyro");
   Enable_Sensor (Addr_Mag, CTRL_REG1_M,  ODR_M1,  "Mag mode");
   Enable_Sensor (Addr_Mag, CTRL_REG3_M,  ODR_M3,  "Mag power");
   Enable_Sensor (Addr_BMP, CTRL_PWR_BMP, SETTINGS_BMP, "BMP390");
   Put_Line ("Sensors enabled");


   -- Scan for first unwritten page to resume after power cycle
   declare
      Blank : constant HAL.SPI.SPI_Data_8b (1 .. PAGE_SIZE) := (others => 0);
      Cmd   : constant HAL.SPI.SPI_Data_8b (1 .. 1) := (1 => 16#03#);
      Junk1 : HAL.SPI.SPI_Data_8b (1 .. 1);
      Junk3 : HAL.SPI.SPI_Data_8b (1 .. 3);
      Addr3 : HAL.SPI.SPI_Data_8b (1 .. 3);
   begin
      loop
         Addr3 := (1 => HAL.UInt8 (Write_Addr / 65536),
                  2 => HAL.UInt8 ((Write_Addr / 256) mod 256),
                  3 => HAL.UInt8 (Write_Addr mod 256));
         CS_Low;
         Transfer (Cmd,   Junk1);
         Transfer (Addr3, Junk3);
         Transfer (Blank, Page_Buf);
         CS_High;

         exit when Page_Buf (253) = 16#FF# and then
                  Page_Buf (254) = 16#FF# and then
                  Page_Buf (255) = 16#FF# and then
                  Page_Buf (256) = 16#FF#;

         Page_Num   := Page_Num + 1;
         Write_Addr := Write_Addr + PAGE_SIZE;

         if Write_Addr > MAX_PAGE * PAGE_SIZE then
            Put_Line ("Flash full - halting");
            loop null; end loop;
         end if;
      end loop;
      Put_Line ("Resuming at page" & Page_Num'Image);
   end;

   ----------------------------------------------------------------------------
   --  Main logging loop
   ----------------------------------------------------------------------------
   loop
      declare
         TS          : constant Unsigned_32 := Get_Timestamp;
         IMU_Data    : I2C_Data (1 .. 6);
         BMP_Data    : I2C_Data (1 .. 6);
         IMU_Ok      : Boolean;
         BMP_Ok      : Boolean;
         AX, AY, AZ : Unsigned_16 := 0;
         GX, GY, GZ : Unsigned_16 := 0;
         MX, MY, MZ : Unsigned_16 := 0;
         Press, Temp : Unsigned_32 := 0;
      begin
         -- Accel
         Read_IMU_Raw (Addr_AG, OUT_X_L_XL, IMU_Data, IMU_Ok);
         if IMU_Ok then
            AX := To_U16 (IMU_Data (1), IMU_Data (2));
            AY := To_U16 (IMU_Data (3), IMU_Data (4));
            AZ := To_U16 (IMU_Data (5), IMU_Data (6));
         else
            Put_Line ("Accel read ERR");
         end if;

         -- Gyro
         Read_IMU_Raw (Addr_AG, OUT_X_L_G, IMU_Data, IMU_Ok);
         if IMU_Ok then
            GX := To_U16 (IMU_Data (1), IMU_Data (2));
            GY := To_U16 (IMU_Data (3), IMU_Data (4));
            GZ := To_U16 (IMU_Data (5), IMU_Data (6));
         else
            Put_Line ("Gyro read ERR");
         end if;

         -- Mag
         Read_IMU_Raw (Addr_Mag, OUT_X_L_M, IMU_Data, IMU_Ok);
         if IMU_Ok then
            MX := To_U16 (IMU_Data (1), IMU_Data (2));
            MY := To_U16 (IMU_Data (3), IMU_Data (4));
            MZ := To_U16 (IMU_Data (5), IMU_Data (6));
         else
            Put_Line ("Mag read ERR");
         end if;

         -- BMP390
         Read_BMP_Raw (BMP_Data, BMP_Ok);
         if BMP_Ok then
            Press := To_U24 (BMP_Data (1), BMP_Data (2), BMP_Data (3));
            Temp  := To_U24 (BMP_Data (4), BMP_Data (5), BMP_Data (6));
         else
            Put_Line ("BMP read ERR");
         end if;

         Pack_Sample (TS,
                      AX, AY, AZ,
                      GX, GY, GZ,
                      MX, MY, MZ,
                      Press, Temp);

         Sample_Idx := Sample_Idx + 1;

         if Sample_Idx = SAMPLES_PER_PAGE then
            --  Put_Line ("Before Flush");
            Flush_Page;
         end if;
      end;

      RP.Device.Timer.Delay_Milliseconds (8);
      Pico.LED.Toggle;
   end loop;

end Flight_Logger;
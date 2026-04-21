-- flash_reader.adb
-- Reads W25Q128 flash page by page and prints sample data over UART.
-- Stops when it finds a page whose sequence number bytes (252-255) are
-- all 0xFF, which means that page was never written (erased flash).
--
-- Output format (human-readable, for screen/copy-paste):
--   PAGE 0  (seq=0)
--   S0  TS:123456  AX:100 AY:-20 AZ:980  GX:0 GY:1 GZ:-1  MX:300 MY:12 MZ:-50  P:6543210 T:2621440
--   ...
--   End of data at page 5

with RP.SPI;         use RP.SPI;
with RP2040_SVD.SPI;
with RP.GPIO;        use RP.GPIO;
with RP.Device;
with RP.Clock;
with RP.UART;
with HAL;            use HAL;
with HAL.SPI;
with HAL.UART;       use HAL.UART;
with Pico;
with Interfaces;     use Interfaces;

procedure Flash_Reader_2 is

   ----------------------------------------------------------------------------
   --  UART
   ----------------------------------------------------------------------------
   UART    : RP.UART.UART_Port renames RP.Device.UART_1;
   UART_TX : GPIO_Point := (Pin => 8);
   UART_RX : GPIO_Point := (Pin => 9);
   U_Stat  : UART_Status;

   ----------------------------------------------------------------------------
   --  SPI / flash pins
   ----------------------------------------------------------------------------
   MISO_Pin : GPIO_Point := (Pin => 16);
   CS_Pin   : GPIO_Point := (Pin => 17);
   SCK_Pin  : GPIO_Point := (Pin => 18);
   MOSI_Pin : GPIO_Point := (Pin => 19);

   SPI_Port : RP.SPI.SPI_Port renames RP.Device.SPI_0;
   SPI_Stat : HAL.SPI.SPI_Status;

   ----------------------------------------------------------------------------
   --  Flash commands
   ----------------------------------------------------------------------------
   CMD_READ_DATA : constant := 16#03#;

   ----------------------------------------------------------------------------
   --  Layout constants (must match flight_logger)
   ----------------------------------------------------------------------------
   PAGE_SIZE        : constant := 256;
   SAMPLE_SIZE      : constant := 28;
   SAMPLES_PER_PAGE : constant := 9;
   MAX_PAGE         : constant := 65_535;

   ----------------------------------------------------------------------------
   --  Page buffer
   ----------------------------------------------------------------------------
   Page_Buf : HAL.SPI.SPI_Data_8b (1 .. PAGE_SIZE);

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
      for I in 1 .. Bytes'Length loop
         declare
            One : UART_Data_8b (1 .. 1) := (1 => Bytes (I));
         begin
            UART.Transmit (One, U_Stat);
         end;
         for J in 1 .. 1_000 loop null; end loop;
      end loop;
   end Put_Line;

   -- Integer to string (no Image on bare-metal for some types)
   -- Works for signed 32-bit values by casting.
   function I32_Img (V : Unsigned_32) return String is
      S : constant Integer_32 := Integer_32 (V);
   begin
      return Integer_32'Image (S);
   end I32_Img;

   ----------------------------------------------------------------------------
   --  SPI low-level helpers
   ----------------------------------------------------------------------------
   procedure CS_Low is
   begin
      CS_Pin.Clear;
      RP.Device.Timer.Delay_Milliseconds (1);
   end CS_Low;

   procedure CS_High is begin CS_Pin.Set;   end CS_High;

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

   procedure Send_Byte (Cmd : HAL.UInt8) is
      Buf : constant HAL.SPI.SPI_Data_8b (1 .. 1) := (1 => Cmd);
   begin
      SPI_Port.Transmit (Buf, SPI_Stat);
   end Send_Byte;

   procedure Send_Address (Addr : Natural) is
      Buf : constant HAL.SPI.SPI_Data_8b (1 .. 3) :=
        (1 => HAL.UInt8 (Addr / 65536),
         2 => HAL.UInt8 ((Addr / 256) mod 256),
         3 => HAL.UInt8 (Addr mod 256));
   begin
      SPI_Port.Transmit (Buf, SPI_Stat);
   end Send_Address;

   ----------------------------------------------------------------------------
   --  Read exactly 256 bytes from flash at byte address Addr into Page_Buf.
   --  Uses the 03h Read Data command (no dummy byte needed at low speed).
   ----------------------------------------------------------------------------
  procedure Read_Page (Addr : Natural) is
      Blank : constant HAL.SPI.SPI_Data_8b (1 .. PAGE_SIZE) := (others => 0);
      Cmd : constant HAL.SPI.SPI_Data_8b (1 .. 1) := (1 => HAL.UInt8 (CMD_READ_DATA));
      Addr3 : constant HAL.SPI.SPI_Data_8b (1 .. 3) :=
               (1 => HAL.UInt8 (Addr / 65536),
               2 => HAL.UInt8 ((Addr / 256) mod 256),
               3 => HAL.UInt8 (Addr mod 256));
      Junk1 : HAL.SPI.SPI_Data_8b (1 .. 1);
      Junk3 : HAL.SPI.SPI_Data_8b (1 .. 3);
   begin
      CS_Low;
      Transfer (Cmd,   Junk1);
      Transfer (Addr3, Junk3);
      Transfer (Blank, Page_Buf);
      CS_High;
   end Read_Page;

   function To_Hex (B : HAL.UInt8) return String is
      Hex_Chars : constant String := "0123456789ABCDEF";
      Hi     : constant Natural := Natural (Shift_Right (Unsigned_32 (B), 4) and 16#0F#);
      Lo     : constant Natural := Natural (Unsigned_32 (B) and 16#0F#);
   begin
      return Hex_Chars (Hi + 1) & Hex_Chars (Lo + 1);
   end To_Hex;

   function U32_To_Hex (V : Unsigned_32) return String is
   begin
      return To_Hex (HAL.UInt8 (Shift_Right (V, 24) and 16#FF#)) &
            To_Hex (HAL.UInt8 (Shift_Right (V, 16) and 16#FF#)) &
            To_Hex (HAL.UInt8 (Shift_Right (V,  8) and 16#FF#)) &
            To_Hex (HAL.UInt8 (V and 16#FF#));
   end U32_To_Hex;
   ----------------------------------------------------------------------------
   --  Reassemble helpers (LSB first, matching Pack_U32 / Pack_I16 / Pack_U24)
   ----------------------------------------------------------------------------
   function Unpack_U32 (Base : Natural) return Unsigned_32 is
      -- Base is 0-indexed byte offset; array is 1-based so add 1
      B0 : constant Unsigned_32 := Unsigned_32 (Page_Buf (Base + 1));
      B1 : constant Unsigned_32 := Unsigned_32 (Page_Buf (Base + 2));
      B2 : constant Unsigned_32 := Unsigned_32 (Page_Buf (Base + 3));
      B3 : constant Unsigned_32 := Unsigned_32 (Page_Buf (Base + 4));
   begin
      return B0 + B1 * 256 + B2 * 65536 + B3 * 16777216;
   end Unpack_U32;

   function Unpack_I16 (Base : Natural) return Unsigned_16 is
      Lo : constant Unsigned_16 := Unsigned_16 (Page_Buf (Base + 1));
      Hi : constant Unsigned_16 := Unsigned_16 (Page_Buf (Base + 2));
   begin
      return Lo + Hi * 256;
   end Unpack_I16;

   function Unpack_U24 (Base : Natural) return Unsigned_32 is
      B0 : constant Unsigned_32 := Unsigned_32 (Page_Buf (Base + 1));
      B1 : constant Unsigned_32 := Unsigned_32 (Page_Buf (Base + 2));
      B2 : constant Unsigned_32 := Unsigned_32 (Page_Buf (Base + 3));
   begin
      return B0 + B1 * 256 + B2 * 65536;
   end Unpack_U24;

   ----------------------------------------------------------------------------
   --  Print one 28-byte sample from the page buffer.
   --  Sample_Idx is 0-based (0..8); byte offset = Sample_Idx * 28.
   ----------------------------------------------------------------------------
   procedure Print_Sample (Sample_Idx : Natural; Page_Idx : Natural) is
      Base : constant Natural := Sample_Idx * SAMPLE_SIZE;
      TS   : constant Unsigned_32 := Unpack_U32 (Base);
      AX   : constant Unsigned_16 := Unpack_I16 (Base + 4);
      AY   : constant Unsigned_16 := Unpack_I16 (Base + 6);
      AZ   : constant Unsigned_16 := Unpack_I16 (Base + 8);
      GX   : constant Unsigned_16 := Unpack_I16 (Base + 10);
      GY   : constant Unsigned_16 := Unpack_I16 (Base + 12);
      GZ   : constant Unsigned_16 := Unpack_I16 (Base + 14);
      MX   : constant Unsigned_16 := Unpack_I16 (Base + 16);
      MY   : constant Unsigned_16 := Unpack_I16 (Base + 18);
      MZ   : constant Unsigned_16 := Unpack_I16 (Base + 20);
      P    : constant Unsigned_32 := Unpack_U24 (Base + 22);
      T    : constant Unsigned_32 := Unpack_U24 (Base + 25);

      function Signed_Img (V : Unsigned_16) return String is
         S : constant Integer_32 := (if V >= 32768
                                    then Integer_32 (V) - 65536
                                    else Integer_32 (V));
      begin
         return Integer_32'Image (S);
      end Signed_Img;

   begin
      pragma Unreferenced (Sample_Idx, Page_Idx);
      Put_Line (Unsigned_32'Image (Unsigned_32 (TS)));   -- TS
      --  Put_Line (Signed_Img (AX));                      -- AX
      --  Put_Line (Signed_Img (AY));                      -- AY
      --  Put_Line (Signed_Img (AZ));                      -- AZ
      --  Put_Line (Signed_Img (GX));                      -- GX
      --  Put_Line (Signed_Img (GY));                      -- GY
      --  Put_Line (Signed_Img (GZ));                      -- GZ
      --  Put_Line (Signed_Img (MX));                      -- MX
      --  Put_Line (Signed_Img (MY));                      -- MY
      --  Put_Line (Signed_Img (MZ));                      -- MZ
      --  Put_Line (Integer_32'Image (Integer_32 (P)));    -- P
      --  Put_Line (Integer_32'Image (Integer_32 (T)));    -- T
   end Print_Sample;


-- ... same pattern for AZ, GX, GY, GZ, MX, MY, MZ

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


   ----------------------------------------------------------------------------
   --  SPI / flash init
   ----------------------------------------------------------------------------
   MISO_Pin.Configure (Input,  Floating, RP.GPIO.SPI);
   SCK_Pin.Configure  (Output, Floating, RP.GPIO.SPI);
   MOSI_Pin.Configure (Output, Floating, RP.GPIO.SPI);
   CS_Pin.Configure   (Output, Floating);
   CS_High;

   SPI_Port.Configure
     (Config =>
        (Role      => RP.SPI.Master,
         Baud      => 10_000_000,
         Data_Size => HAL.SPI.Data_Size_8b,
         Polarity  => RP.SPI.Active_Low,
         Phase     => RP.SPI.Rising_Edge,
         others    => <>));


   ----------------------------------------------------------------------------
   --  Main read loop
   ----------------------------------------------------------------------------
   declare
      Page_Idx  : Natural   := 0;
      Read_Addr : Natural   := 0;
      Seq       : Unsigned_32;
   begin
      declare
         ID    : HAL.SPI.SPI_Data_8b (1 .. 3);
         Dummy : constant HAL.SPI.SPI_Data_8b (1 .. 3) := (others => 0);
         Junk  : HAL.SPI.SPI_Data_8b (1 .. 1);
         D1    : constant HAL.SPI.SPI_Data_8b (1 .. 1) := (others => 0);
      begin
         CS_Low;
         declare
            Cmd : constant HAL.SPI.SPI_Data_8b (1 .. 1) := (1 => 16#9F#);
         begin
            Transfer (Cmd, Junk);
         end;
         Transfer (Dummy, ID);
         CS_High;
      end;
      declare
         Data  : HAL.SPI.SPI_Data_8b (1 .. 4) := (others => 0);
         Cmd   : constant HAL.SPI.SPI_Data_8b (1 .. 1) := (1 => 16#03#);
         Addr3 : constant HAL.SPI.SPI_Data_8b (1 .. 3) := (1 => 0, 2 => 0, 3 => 0);
         Junk1 : HAL.SPI.SPI_Data_8b (1 .. 1);
         Junk3 : HAL.SPI.SPI_Data_8b (1 .. 3);
      begin
         CS_Low;
         Transfer (Cmd,   Junk1);
         Transfer (Addr3, Junk3);
         Transfer (Data,  Data);
         CS_High;
      end;
      loop
         Read_Page (Read_Addr);

         -- Check sequence number at bytes 252-255 (1-based: 253..256)
         -- If all four are 0xFF, this page was never written — stop.
         if Page_Buf (253) = 16#FF# and then
            Page_Buf (254) = 16#FF# and then
            Page_Buf (255) = 16#FF# and then
            Page_Buf (256) = 16#FF#
         then
            exit;
         end if;

         

         -- Reassemble sequence number (LSB first, offset 252 = index 253)
         Seq := Unsigned_32 (Page_Buf (253)) +
                Unsigned_32 (Page_Buf (254)) * 256 +
                Unsigned_32 (Page_Buf (255)) * 65536 +
                Unsigned_32 (Page_Buf (256)) * 16777216;

         -- Print all 9 samples in this page
         for S in 0 .. SAMPLES_PER_PAGE - 1 loop
            Print_Sample (S, Page_Idx);
            
         end loop;

         -- Safety check — stop if we've read the whole chip
         if Page_Idx >= MAX_PAGE then
            exit;
         end if;

         Page_Idx  := Page_Idx + 1;
         Read_Addr := Read_Addr + PAGE_SIZE;
         RP.Device.Timer.Delay_Milliseconds (1);
      end loop;
   end;
   loop 
      RP.Device.Timer.Delay_Milliseconds (100);
      Pico.LED.Toggle;
   end loop;

end Flash_Reader_2;
with RP.SPI; use RP.SPI;
with RP2040_SVD.SPI;
with RP.GPIO;  use RP.GPIO;
with RP.Device;
with HAL.SPI;
with HAL; use HAL;
with RP.Clock;
with Pico;
with HAL.UART; use HAL.UART;
with RP.UART;

procedure SPI_Flash_Test is

   -- UART pin definitions
   UART    : RP.UART.UART_Port renames RP.Device.UART_1;
   UART_TX : GPIO_Point := (Pin => 8);
   UART_RX : GPIO_Point := (Pin => 9);

   Stat  : UART_Status;
   --  Pin definitions
   MISO_Pin : RP.GPIO.GPIO_Point := (Pin => 16);
   CS_Pin   : RP.GPIO.GPIO_Point := (Pin => 17);
   SCK_Pin  : RP.GPIO.GPIO_Point := (Pin => 18);
   MOSI_Pin : RP.GPIO.GPIO_Point := (Pin => 19);

   SPI_Port : RP.SPI.SPI_Port renames RP.Device.SPI_0;

   --  W25Q128 command bytes
   CMD_WRITE_ENABLE  : constant := 16#06#;
   CMD_SECTOR_ERASE  : constant := 16#20#;
   CMD_PAGE_PROGRAM  : constant := 16#02#;
   CMD_READ_DATA     : constant := 16#03#;
   CMD_READ_STATUS   : constant := 16#05#;
   CMD_JEDEC_ID      : constant := 16#9F#;

   --  We'll use sector 0, page 0 = address 0x000000
   TEST_ADDR : constant := 16#000000#;

   Status   : HAL.SPI.SPI_Status;
   Busy_Buf : HAL.SPI.SPI_Data_8b (1 .. 1);

   --  Helper: assert CS low (select chip)
   procedure CS_Low is
   begin
      CS_Pin.Clear;
      RP.Device.Timer.Delay_Milliseconds (1);
   end CS_Low;

   --  Helper: assert CS high (deselect chip)
   procedure CS_High is
   begin
      CS_Pin.Set;
   end CS_High;

   -- deal with issue of missing dummy bytes interfereing with response
   procedure Transfer (TX : HAL.SPI.SPI_Data_8b; RX : out HAL.SPI.SPI_Data_8b) is
      Periph : RP2040_SVD.SPI.SPI_Peripheral renames SPI_Port.Periph.all;
   begin
      for I in TX'Range loop
         --  Wait for TX FIFO to have space
         while not Periph.SSPSR.TNF loop null; end loop;
         Periph.SSPDR.DATA := RP2040_SVD.SPI.SSPDR_DATA_Field (TX (I));
         --  Wait for RX FIFO to have data
         while not Periph.SSPSR.RNE loop null; end loop;
         RX (I) := HAL.UInt8 (Periph.SSPDR.DATA);
      end loop;
   end Transfer;

   -- prints line in UART output
   procedure Put_Line (S : String) is
      Bytes : UART_Data_8b (1 .. S'Length + 2);
   begin
      for I in S'Range loop
         Bytes (I - S'First + 1) := Character'Pos (S (I));
      end loop;
      Bytes (S'Length + 1) := Character'Pos (ASCII.CR);
      Bytes (S'Length + 2) := Character'Pos (ASCII.LF);
      UART.Transmit (Bytes, Stat);
      for I in 1 .. 10_000 loop
         null;
      end loop;
   end Put_Line;

   -- flush the RX FIFO
   procedure Flush_RX is
      Dummy : HAL.SPI.SPI_Data_8b (1 .. 1);
   begin
      while SPI_Port.Receive_Status = RP.SPI.Not_Full or
            SPI_Port.Receive_Status = RP.SPI.Full loop
         SPI_Port.Receive (Dummy, Status);
      end loop;
   end Flush_RX;

   --  Helper: send a single byte, ignore response
   procedure Send_Byte (Cmd : HAL.UInt8) is
      -- single byte array with argument as the item
      Buf : constant HAL.SPI.SPI_Data_8b (1 .. 1) := (1 => Cmd); 
   begin
      SPI_Port.Transmit (Buf, Status);
   end Send_Byte;

   --  Helper: send address as 3 bytes (24-bit, MSB first)
   procedure Send_Address (Addr : Natural) is
      Buf : constant HAL.SPI.SPI_Data_8b (1 .. 3) :=
        (1 => HAL.UInt8 (Addr / 65536), -- truncates I am guessing since natural
         2 => HAL.UInt8 ((Addr / 256) mod 256), --mod to deal with potential higher values carried
         3 => HAL.UInt8 (Addr mod 256));-- makes sense since first byte
   begin
      SPI_Port.Transmit (Buf, Status);
   end Send_Address;

   --  Poll WIP (Write In Progress) bit in status register until clear
   procedure Wait_Until_Ready is
   S : HAL.UInt8;
   Count : Natural := 0;
   begin
      loop
         CS_Low;
         Send_Byte (CMD_READ_STATUS);
         Flush_RX;
         declare
            Dummy : constant HAL.SPI.SPI_Data_8b (1 .. 1) := (others => 0);
         begin
            Transfer (Dummy, Busy_Buf);
         end;
         CS_High;
         S := Busy_Buf (1);
         declare
            SB : constant HAL.UInt8 := S;
         begin
            --  Put_Line ("WIP status: " & SB'Image);
            if Count mod 10 = 0 then
               Put_Line ("WIP #" & Count'Image & " - WIP status: " & SB'Image);
            end if;
         end;
         exit when (S and 16#01#) = 0;
         Count := Count + 1;
         if Count > 1000 then
            Put_Line ("TIMEOUT - chip not responding");
            return;
         end if;
         --  RP.Device.Timer.Delay_Milliseconds (50);
      end loop;
   end Wait_Until_Ready;

   --  Write enable must be called before every erase or program
   procedure Write_Enable is
   begin
      CS_Low;
      Send_Byte (CMD_WRITE_ENABLE);
      CS_High;
   end Write_Enable;
 
   --  Erase the 4KB sector containing TEST_ADDR
   procedure Erase_Sector is
   begin
      Write_Enable;
      CS_Low;
      Send_Byte (CMD_SECTOR_ERASE);
      Send_Address (TEST_ADDR);
      CS_High;
      Wait_Until_Ready;  --  erase takes ~400ms max
   end Erase_Sector;

   --  Write up to 256 bytes starting at TEST_ADDR
   procedure Write_Page (Data : HAL.SPI.SPI_Data_8b) is
   begin
      Write_Enable;
      CS_Low;
      Send_Byte (CMD_PAGE_PROGRAM); -- prepares for writing of data
      Send_Address (TEST_ADDR); 
      SPI_Port.Transmit (Data, Status);
      CS_High;
      Wait_Until_Ready;
   end Write_Page;

   --  Read back the same number of bytes from TEST_ADDR
   procedure Read_Page (Data : out HAL.SPI.SPI_Data_8b) is
   begin
      CS_Low;
      Send_Byte (CMD_READ_DATA);
      Send_Address (TEST_ADDR);
      Flush_RX;
      declare
         Dummy : HAL.SPI.SPI_Data_8b (1 .. Data'Length) := (others => 0);
      begin
         Transfer (Dummy, Data);
      end;
      CS_High;
   end Read_Page;

   
   --  Test data: just 0..15 for easy visual verification over UART
   Write_Buf : constant HAL.SPI.SPI_Data_8b (1 .. 16) :=
     (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16);
   Read_Buf  : HAL.SPI.SPI_Data_8b (1 .. 16);
   Pass      : Boolean := True;

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

   --  Configure GPIO pins for SPI
   MISO_Pin.Configure (RP.GPIO.Input,  RP.GPIO.Floating, RP.GPIO.SPI);
   SCK_Pin.Configure  (RP.GPIO.Output, RP.GPIO.Floating, RP.GPIO.SPI);
   MOSI_Pin.Configure (RP.GPIO.Output, RP.GPIO.Floating, RP.GPIO.SPI);

   --  CS is manual GPIO, not hardware-controlled
   CS_Pin.Configure (RP.GPIO.Output, RP.GPIO.Floating);
   CS_High;  --  deselect on startup
   Put_Line ("CS init done");

   --  Configure SPI peripheral: mode 0, 8-bit, 10MHz
   SPI_Port.Configure
     (Config => (Role      => RP.SPI.Master,
                 Baud      => 10_000_000,
                 Data_Size => HAL.SPI.Data_Size_8b,
                 Polarity  => RP.SPI.Active_Low,  --  CPOL=0
                 Phase     => RP.SPI.Rising_Edge,  --  CPHA=0
                 others    => <>));

   Put_Line("Process starting...");
   --  Step 1: check JEDEC ID — should be EF 40 18 for W25Q128
   declare
      ID : HAL.SPI.SPI_Data_8b (1 .. 3);
      B0 : HAL.UInt8;
      B1 : HAL.UInt8;
      B2 : HAL.UInt8;
   begin
      CS_Low;
      Put_Line ("CS pulled low");
      Send_Byte (CMD_JEDEC_ID);
      Flush_RX;
      declare
         Dummy : constant HAL.SPI.SPI_Data_8b (1 .. 3) := (others => 0);
      begin
         Transfer (Dummy, ID);
      end;
      CS_High;
      B0 := ID (1);
      B1 := ID (2);
      B2 := ID (3);
      Put_Line ("JEDEC ID Values:");
      Put_Line (B0'Image & ", " & B1'Image & ", " & B2'Image & ", " );  
      --  B0 should be 239  (0xEF)
      --  Put_Line (B1'Image);  --  should be 64   (0x40)
      --  Put_Line (B2'Image);  --  should be 24   (0x18)
   end;

   --  Step 2: erase, write, read back
   Put_Line ("Erasing, Writing, Reading...");
   Erase_Sector;
   Write_Page (Write_Buf);
   Read_Page  (Read_Buf);

   --  Step 3: verify
   Put_Line ("Read-Write Values:");
   for I in Write_Buf'Range loop
      if Write_Buf (I) /= Read_Buf (I) then
         declare
            W : constant HAL.UInt8 := Write_Buf (I);
            R : constant HAL.UInt8 := Read_Buf (I);
         begin
            Put_Line (W'Image & " /=" & R'Image);
         end;
         Pass := False;
      end if;
      --  Put_Line (Pass'Image);
   end loop;

   if Pass then
      Put_Line ("PASS: all bytes match");
   else
      Put_Line ("FAIL: mismatch detected");
   end if;

   Put_Line("Process Complete");
   loop
      RP.Device.Timer.Delay_Milliseconds (500);
      Pico.LED.Toggle;
      RP.Device.Timer.Delay_Milliseconds (1000);
      Pico.LED.Toggle;
   end loop;

end SPI_Flash_Test;
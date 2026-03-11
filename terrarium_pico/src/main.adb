--
--  Copyright 2021 (C) Jeremy Grosser
--
--  SPDX-License-Identifier: BSD-3-Clause
with HAL; use HAL;
with HAL.GPIO;   use HAL.GPIO;
with HAL.UART;   use HAL.UART;
with RP.Device;  use RP.Device;
with RP.GPIO;    use RP.GPIO;
with RP.UART;
with RP.Clock;
with Pico;
-- with RP2040;

procedure main is
   Test_Error : exception;
   UART    : RP.UART.UART_Port renames RP.Device.UART_0;
   UART_TX : RP.GPIO.GPIO_Point renames Pico.GP0;
   UART_RX : RP.GPIO.GPIO_Point renames Pico.GP1;
   Buffer  : UART_Data_8b (1 .. 1);
   Status  : UART_Status;

   procedure Send_Hello is
      Hello       : constant String := "Hello, Pico!" & ASCII.CR & ASCII.LF;
      Hello_Bytes : UART_Data_8b (1 .. Hello'Length);
   begin
      for I in Hello'Range loop
         Hello_Bytes (I) := Character'Pos (Hello (I));
      end loop;

      UART.Transmit (Hello_Bytes, Status);
      if Status /= Ok then
         raise Test_Error with "Send_Hello transmit failed with status " & Status'Image;
      end if;
   end Send_Hello;

   procedure Echo is
   begin
      loop
         UART.Receive (Buffer, Status, Timeout => 0);
         case Status is
            when Err_Error =>
               raise Test_Error with "Echo receive failed with status " & Status'Image;
            when Err_Timeout =>
               raise Test_Error with "Unexpected Err_Timeout with timeout disabled!";
            when Busy =>
               --  Busy indicates a Break condition- RX held low for a full
               --  word time. This may be detected unintentionally if a
               --  transmitter is not connected. Break is used by some
               --  protocols (eg. LIN bus) to indicate the end of a frame.
               --
               --  For this example, we just ignore it.
               null;
            when Ok =>
               UART.Transmit (Buffer, Status);
               if Status /= Ok then
                  raise Test_Error with "Echo transmit failed with status " & Status'Image;
               end if;
               Pico.LED.Toggle;
         end case;
      end loop;
   end Echo;
begin
   RP.Clock.Initialize (Pico.XOSC_Frequency);
   RP.Clock.Enable (RP.Clock.PERI);
   -- RP.Device.Timer.Enable;
   RP.GPIO.Enable;
   Pico.LED.Configure (Output);
   Pico.LED.Set;

   --  I don't know if the pull up is needed, but it doesn't hurt?
   UART_TX.Configure (Output, Pull_Up, RP.GPIO.UART);
   UART_RX.Configure (Input, Floating, RP.GPIO.UART);
   UART.Configure
      (Config =>
         (Baud      => 115_200,
          Word_Size => 8,
          Parity    => False,
          Stop_Bits => 1,
          others    => <>));

   Send_Hello;
   --UART.Send_Break (RP.Device.Timer'Access, UART.Frame_Time * 2);
   Echo;





   declare
      type Board_Info_Record is record
         Mandatory_Bit : Bit;
         Manufacturer  : UInt11; -- <- 16#_#
         Part_Number   : UInt16;
         Version       : UInt4;
      end record with Size => 32;

      type Raw_Message is array (0 .. 3) of Byte;

      --  function To_Board_Info is new Ada.Unchecked_Conversion
      --     (Raw_Message, Board_Info_Record);

      function To_UIn32 is new Ada.Unchecked_Conversion
         (Raw_Message, UInt32);

      RM : Raw_Message := 0;
      BI : Board_Info_Record with Address => RM'Address;
      BII : UInt32;
   begin
      RM := Read_Next (Stream);
      -- BI := To_Board_Info (RM);
      BII := To_UInt32 (RM);

      Put_Line (BI.Mandatory_Bit'Image & ":" & 
                BI.Manufacturer'Image & ":" &
                BI.Part_Number'Image & ":" &
                BI.Version'Image);
   end;

end main;
--  flash_dump.adb
--  Bench tool. Reads the flight log back over the console, then marks it
--  dumped and erases the chip when asked. Replaces terrarium_pico's
--  flash_reader and flash_reader_2.
--
--  General plan:
--  Prints a summary, then waits for a one-letter command:
--     D   dump page 0, page 1, then every written data page
--     M   mark the log dumped, once the capture has been checked
--     E   erase the whole chip; refused until the log is marked dumped
--     S   print the summary again
--  Lines starting with '#' are for people. Every other line is one 256-byte
--  page as 512 hex digits with nothing else on it, in page order, so the
--  capture can be decoded afterward with nothing left out. The layouts are
--  in flight_journal.ads and telemetry.ads.
--
--  At 115200 baud a page takes about 45 ms. A flight with 20 hours on the
--  pad, 30 s of boost and coast and 2 minutes of descent is about 9,400
--  pages, or about 7 minutes. Check the capture's sequence numbers for
--  gaps before sending M.
--
--  Capture with:  screen -L -Logfile flight.hex /dev/tty.usbmodemXXXX 115200

with Ada.Real_Time; use Ada.Real_Time;
with System.Storage_Elements; use System.Storage_Elements;

with Console_Text;  use Console_Text;
with Payload;
with Telemetry;

procedure Flash_Dump is

   package Journal renames Payload.Journal;

   --  Print what's on the chip, every line starting with '#'.
   procedure Put_Summary is
      Info   : Journal.Log_Info;
      Header : Telemetry.Header;
      Ok     : Boolean;
   begin
      Journal.Inspect (Info, Header, Ok);
      if not Ok then
         Put_Line ("# flash read failed");
         return;
      end if;

      if Info.Blank then
         Put_Line ("# chip is blank");
         return;
      end if;

      Put ("# format:     ");
      Put_Line (if Info.Format_Ok then "ok" else "different version");
      Put ("# data pages: ");
      Put_Int (Info.Pages_Used);
      New_Line;
      Put ("# last phase: ");
      Put_Line (Payload.Flight.Phase'Image (Info.Last_Phase));
      Put ("# resets:     ");
      Put_Int (Integer (Info.Last_Boot));
      New_Line;
      Put ("# dumped:     ");
      Put_Line (if Info.Dumped then "yes" else "no");

      --  the header can only be read in this build's format
      if Info.Format_Ok then
         Put ("# board:      ");
         Put_Line (Header.Board_Id);
         Put ("# tick us:    ");
         Put_Int (Integer (Header.Tick_Us));
         New_Line;
         Put ("# accel:      ");
         Put_Int (Integer (Header.Accel_ODR_Hz));
         Put (" Hz, counts/g ");
         Put_Int (Integer (Header.Accel_Counts_Per_G));
         New_Line;
         Put ("# gyro:       ");
         Put_Int (Integer (Header.Gyro_ODR_Hz));
         Put (" Hz, counts/dps ");
         Put_Int (Integer (Header.Gyro_Counts_Per_Dps));
         New_Line;
         Put ("# baro:       ");
         Put_Int (Integer (Header.Baro_Rate_Hz));
         Put_Line (" Hz");
      end if;
   end Put_Summary;

   --  Send the header, the marker and every written data page as hex.
   procedure Dump is
      Info   : Journal.Log_Info;
      Header : Telemetry.Header;
      Page   : Storage_Array (1 .. Payload.Flash.Page_Size);
      Ok     : Boolean;
      Last   : Natural;
   begin
      Journal.Inspect (Info, Header, Ok);
      if not Ok then
         Put_Line ("# flash read failed");
         return;
      end if;

      Last := Journal.First_Data_Page + Info.Pages_Used - 1;
      Put ("# dump start, pages ");
      Put_Int (Last + 1);
      New_Line;

      for P in 0 .. Last loop
         Journal.Read_Raw_Page (P, Page, Ok);
         if Ok then
            Put_Hex (Page);
            New_Line;
         else
            --  keep going, so one bad read doesn't lose the rest
            Put ("# read failed, page ");
            Put_Int (P);
            New_Line;
         end if;
      end loop;

      Put_Line ("# dump end");
   end Dump;

   procedure Mark is
      Ok : Boolean;
   begin
      Journal.Mark_Dumped (Ok);
      Put_Line (if Ok then "# marked dumped" else "# mark failed");
   end Mark;

   procedure Erase is
      Ok : Boolean;
   begin
      Put_Line ("# erasing, this takes 40 s to a few minutes");
      Journal.Erase_All (Ok);
      Put_Line
        (if Ok then "# erased" else "# not erased: dump and send M first");
   end Erase;

   procedure Put_Help is
   begin
      Put_Line ("# D dump, M mark dumped, E erase, S summary");
   end Put_Help;

   Checks : Payload.Check_Result;
   C      : Character;
   Got    : Boolean;

begin
   Payload.Initialize (Checks);
   Put_Line ("# providentia flash_dump");

   --  only the flash is needed here, so a missing sensor doesn't block
   --  recovering the data
   if not Checks.Flash then
      Put_Line ("# flash not responding, check wiring and reset");
      loop
         Payload.Led_Toggle;
         delay until Clock + Milliseconds (50);
      end loop;
   end if;

   Put_Summary;
   Put_Help;

   loop
      Get_Char (C, Got);
      if Got then
         case C is
            when 'D' | 'd' => Dump;
            when 'M' | 'm' => Mark;
            when 'E' | 'e' => Erase;
            when 'S' | 's' => Put_Summary;
            when others    => Put_Help;
         end case;
      end if;
      delay until Clock + Milliseconds (10);
   end loop;
end Flash_Dump;

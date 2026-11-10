--  flight_journal.ads
--  The flight log on NOR flash: writing pages during flight and reading
--  them back afterward, in one package so the writer and reader can't
--  disagree on the layout again (terrarium_pico's 22 vs 23 offset bug).
--  Part of flight_journal_generic. No hardware access of its own: flash is
--  reached through the formals, so it can be tested on a host against a
--  RAM array.
--
--  General plan:
--  The chip is erased before each campaign (Erase_All after a dump). The
--  journal never erases while logging, because a sector erase blocks for
--  tens to hundreds of ms and must not land in boost. One flight per
--  erase; 16 MB holds hours of flight rate.
--
--  Page layout, all values LSB first:
--
--  Page 0, header, written with the first data page:
--     0-3    Magic "PROV"
--     4      Format_Version
--     5      Record_Size
--     6      Records_Per_Page
--     7      Trailer_Size
--     8-..   Header_Type, Header_Size bytes (sensor settings, scales,
--            calibration, board id), so the log describes itself
--
--  Page 1, dump marker: all 0xFF until Mark_Dumped writes it.
--
--  Pages 2 and on, data:
--     0-..   Records_Per_Page records, Record_Size bytes each. Slots past
--            Count are 0xFF.
--     last 14 bytes, trailer:
--       +0   Sequence, 32-bit, data page number from 0. All 0xFF means
--            never written.
--       +4   Boot, 8-bit, 0 for the first boot of this flight, +1 for each
--            resume after a reset. A new boot restarts the timestamps.
--       +5   Epoch, 8-bit, timestamp wraps since this boot, as of the
--            page's first record. A later record with a smaller
--            timestamp has wrapped once more.
--       +6   Missed tick deadlines since boot, 16-bit, stops at the max
--       +8   Failed reads and writes since boot, 16-bit, stops at the max
--       +10  Battery in millivolts, 16-bit, 0 if not measured
--       +12  Phase when the page was written (Phase_Type'Pos)
--       +13  Count, records used in this page
--
--  Each page holds one phase: the logger calls Flush before it changes
--  phase, so the post-processing never has to guess.

with Interfaces; use Interfaces;
with System.Storage_Elements; use System.Storage_Elements;

generic
   --  one log record and its packed size in bytes; the body checks
   --  Record_Type'Size = 8 * Record_Size at elaboration
   type Record_Type is private;
   Record_Size : Positive;

   --  the record's microsecond timestamp, used to count wraps
   with function Timestamp_Of (R : Record_Type) return Unsigned_32;

   --  settings written once to page 0; Header_Size in bytes, at most
   --  Page_Size - 8
   type Header_Type is private;
   Header_Size : Positive;

   --  flight phases; Final_Phase ends a flight
   type Phase_Type is (<>);
   Final_Phase : Phase_Type;

   --  change whenever Record_Type or Header_Type changes layout
   Format_Version : Unsigned_8;

   --  flash geometry
   Page_Size   : Positive;
   Total_Pages : Positive;

   --  Program one page at byte address Addr. Data'Length = Page_Size and
   --  the page must be erased.
   with procedure Flash_Write_Page
     (Addr : Unsigned_32;
      Data : Storage_Array;
      Ok   : out Boolean);

   --  Read Data'Length bytes starting at byte address Addr.
   with procedure Flash_Read
     (Addr : Unsigned_32;
      Data : out Storage_Array;
      Ok   : out Boolean);

   --  Erase the whole chip. Blocks for tens of seconds.
   with procedure Flash_Erase_Chip (Ok : out Boolean);

   --  True when the arm jumper is in. Append refuses to write otherwise.
   with function Armed return Boolean;
package Flight_Journal is

   Trailer_Size     : constant := 14;
   Header_Page      : constant := 0;
   Marker_Page      : constant := 1;
   First_Data_Page  : constant := 2;

   Records_Per_Page : constant Positive :=
     (Page_Size - Trailer_Size) / Record_Size;
   Data_Pages       : constant Positive := Total_Pages - First_Data_Page;

   type Record_Array is array (1 .. Records_Per_Page) of Record_Type;

   --  a data page's trailer, unpacked
   type Page_Trailer is record
      Sequence     : Unsigned_32 := 0;
      Boot         : Unsigned_8  := 0;
      Epoch        : Unsigned_8  := 0;
      Missed_Ticks : Unsigned_16 := 0;
      Errors       : Unsigned_16 := 0;
      Battery_mV   : Unsigned_16 := 0;
      Phase        : Phase_Type  := Phase_Type'First;
      Count        : Natural     := 0;
   end record;

   --  what is on the chip, from Inspect
   type Log_Info is record
      Blank      : Boolean := True;   --  no header and no data
      Format_Ok  : Boolean := False;  --  header matches this build
      Pages_Used : Natural := 0;      --  data pages written
      Last_Phase : Phase_Type := Phase_Type'First;  --  of the last page
      Last_Boot  : Unsigned_8 := 0;
      Dumped     : Boolean := False;  --  Mark_Dumped has been written
   end record;

   ---------------------------------------------------------------------
   --  Writing, for flight_logger
   ---------------------------------------------------------------------

   type Open_Status is
     (Fresh,         --  blank chip, logging starts at the first data page
      Resumed,       --  a flight was cut off by a reset; carry on after it
      Needs_Dump,    --  holds a finished flight that hasn't been read back
      Needs_Erase,   --  holds a finished flight that has been read back
      Wrong_Format,  --  header from a different Format_Version
      Full,          --  no blank data pages left
      Flash_Fault);  --  a flash read failed

   --  Get ready to log. Scans for the first blank data page so a reset
   --  carries on after existing data, and keeps Header for page 0. Writes
   --  nothing, so opening on the bench costs no flash.
   --  Append is only allowed after Fresh or Resumed. After Resumed, read
   --  the last phase with Inspect and restart the state machine there;
   --  the Boot count goes up by one.
   procedure Open_Append (Header : Header_Type; Status : out Open_Status);

   --  Set the trailer values for the page being filled. Call every tick.
   --  Call Flush first if Phase is changing.
   procedure Set_Status
     (Phase        : Phase_Type;
      Missed_Ticks : Unsigned_16;
      Errors       : Unsigned_16;
      Battery_mV   : Unsigned_16);

   --  Buffer one record, and write the page when it fills. Writes page 0
   --  first if this is the first page of the flight. Ok is False, with
   --  nothing buffered, if not armed, not open, or full; a failed page
   --  write also sets Ok to False, and that page's records are lost.
   procedure Append (R : Record_Type; Ok : out Boolean);

   --  Write the partly filled page now, if it holds any records. Use before
   --  a phase change and on landing.
   procedure Flush (Ok : out Boolean);

   --  Returns True when no blank data pages are left.
   function Is_Full return Boolean;

   --  Returns the number of data pages written, including this boot's.
   function Pages_Used return Natural;

   --  Find the newest record in a page written in Of_Phase, searching back
   --  from the end of the log. Used on resume to recover the pad pressure.
   procedure Find_Last_Record
     (Of_Phase : Phase_Type;
      R        : out Record_Type;
      Found    : out Boolean);

   ---------------------------------------------------------------------
   --  Reading back, for flash_dump
   ---------------------------------------------------------------------

   --  Read page 0 and page 1 and count the data pages written. Read only.
   --  Header is only meaningful when Info.Format_Ok is True.
   procedure Inspect
     (Info   : out Log_Info;
      Header : out Header_Type;
      Ok     : out Boolean);

   --  Read data page Index (0 is the first data page) and unpack it.
   --  Records (1 .. Trailer.Count) are valid.
   procedure Read_Page
     (Index   : Natural;
      Records : out Record_Array;
      Trailer : out Page_Trailer;
      Ok      : out Boolean)
     with Pre => Index < Data_Pages;

   --  Read any page as raw bytes, by its absolute page number (0 is the
   --  header). For the hex dump, so nothing is left out.
   procedure Read_Raw_Page
     (Page : Natural;
      Data : out Storage_Array;
      Ok   : out Boolean)
     with Pre => Page < Total_Pages and then Data'Length = Page_Size;

   --  Record that the log has been read back. The next Open_Append then
   --  reports Needs_Erase instead of Needs_Dump.
   procedure Mark_Dumped (Ok : out Boolean);

   --  Erase the whole chip. Ok is False, without erasing, if the chip holds
   --  data that hasn't been marked dumped. Blocks for tens of seconds.
   procedure Erase_All (Ok : out Boolean);

end Flight_Journal;

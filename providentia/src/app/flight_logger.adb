--  flight_logger.adb
--  Flight firmware. Logs IMU and barometer data to flash in one
--  fixed-period loop, at a rate set by the flight phase. No console output
--  and no flash erases. Run flash_dump and erase before each campaign.
--
--  General plan:
--  Every 10 ms tick drains the IMU FIFO (833 Hz, about 8 samples) and
--  steps the state machine with their mean acceleration. Every 2nd tick
--  reads the barometer (50 Hz). Each IMU sample becomes a record with the
--  latest baro reading, and is logged if it's due in this phase:
--     Idle     nothing, so bench time costs no flash
--     Pad      every 833rd sample, about 1 Hz
--     Boost    every sample, 833 Hz
--     Coast    every sample
--     Descent  every 16th sample, about 52 Hz
--     Landed   nothing; the last page is written on touchdown
--  On the pad, the last 256 samples (about 0.3 s) are also kept in RAM and
--  written when boost is detected, so the start of the burn isn't lost to
--  the 100 ms detection hold.
--
--  The arm jumper moves Idle to Pad. Pulling it on the pad goes back to
--  Idle; pulling it in flight does nothing.
--
--  A reset in flight resumes: the journal finds the first blank page, and
--  the state machine restarts in the last logged phase with the last pad
--  pressure as its ground reference.
--
--  LED:
--     Toggles every 1 s      Idle, not armed
--     Toggles every 0.25 s   Pad, armed
--     Toggles every 50 ms    In flight
--     Toggles every 2 s      Landed, log complete
--     Solid on               Flash full, logging stopped
--     Fast blink             Boot fault: a device isn't responding. Keeps
--                            retrying.
--     Double blink           Flash holds a finished flight or another
--                            format. Run flash_dump. Doesn't retry, so the
--                            data is safe.

with Ada.Real_Time; use Ada.Real_Time;
with Interfaces;    use Interfaces;

with Baro_Types;
with Imu_Types;     use Imu_Types;
with Payload;
with Telemetry;

procedure Flight_Logger is

   package Flight  renames Payload.Flight;
   package Journal renames Payload.Journal;

   use type Flight.Phase;
   use type Journal.Open_Status;

   Tick_Us       : constant := 10_000;  --  100 Hz loop
   Tick          : constant Time_Span := Microseconds (Tick_Us);
   Baro_Interval : constant := 2;       --  ticks between baro reads

   --  IMU samples per logged sample, by Flight.Phase'Pos; 0 = not logged
   Log_Every : constant Telemetry.Decimation_Table :=
     (0 => 0,      --  Idle
      1 => 833,    --  Pad
      2 => 1,      --  Boost
      3 => 1,      --  Coast
      4 => 16,     --  Descent
      5 => 0);     --  Landed

   --  ticks between LED changes, by Flight.Phase'Pos
   type Led_Table is array (0 .. 5) of Positive;
   Led_Every : constant Led_Table := (100, 25, 5, 5, 5, 200);

   --  pre-launch buffer, about 0.3 s at 833 Hz
   Ring_Size : constant := 256;
   type Ring_Index is mod Ring_Size;
   type Sample_Ring is array (Ring_Index) of Telemetry.Sample;

   Machine     : Flight.Machine;
   Phase       : Flight.Phase := Flight.Idle;  --  phase of the open page
   Batch       : Raw_Sample_Array (1 .. 32);   --  room for 38 ms of FIFO
   Baro_Now    : Baro_Types.Reading;           --  latest baro reading
   Pressure    : Float := 0.0;                 --  latest, pascals
   Have_Baro   : Boolean := False;             --  Pressure is valid
   Counts_Per_G : Float := 1.0;
   Since_Log   : Natural := 0;      --  IMU samples since the last logged
   Last_Logged : Unsigned_32 := 0;  --  timestamp of the last logged record
   Logged_Any  : Boolean := False;
   Ring        : Sample_Ring;
   Ring_Next   : Ring_Index := 0;   --  slot the next sample goes in
   Ring_Count  : Natural := 0;      --  samples held, up to Ring_Size
   Ticks       : Unsigned_32 := 0;  --  ticks since boot
   Missed      : Unsigned_16 := 0;  --  missed deadlines since boot
   Errors      : Unsigned_16 := 0;  --  failed reads and writes since boot
   Full        : Boolean := False;  --  flash full, logging stopped
   Deadline    : Time;

   --  Add one to a count, stopping at the maximum so it can't wrap.
   procedure Bump (Count : in out Unsigned_16) is
   begin
      if Count < Unsigned_16'Last then
         Count := Count + 1;
      end if;
   end Bump;

   --  Blink the LED fast for about a second to show a boot fault. The
   --  caller loops on it and retries.
   procedure Fault_Blink is
   begin
      for I in 1 .. 20 loop
         Payload.Led_Toggle;
         delay until Clock + Milliseconds (50);
      end loop;
   end Fault_Blink;

   --  Double blink forever. Never returns, so nothing on the flash can be
   --  overwritten.
   procedure Halt_Needs_Dump is
   begin
      loop
         for I in 1 .. 4 loop
            Payload.Led_Toggle;
            delay until Clock + Milliseconds (100);
         end loop;
         delay until Clock + Milliseconds (1_000);
      end loop;
   end Halt_Needs_Dump;

   --  Returns True if timestamp T is after the last logged record. Uses
   --  the wrapping difference, so it stays right across the 71-minute wrap.
   function Is_Newer (T : Unsigned_32) return Boolean is
   begin
      return not Logged_Any
        or else (T - Last_Logged) in 1 .. 2**31 - 1;
   end Is_Newer;

   --  Append one record to the journal. A record no newer than the last
   --  one is skipped: the pre-launch buffer overlaps the last pad record,
   --  and the journal counts a backward step as a timestamp wrap.
   procedure Log (S : Telemetry.Sample) is
      Ok : Boolean;
   begin
      if Full or else not Is_Newer (S.Timestamp) then
         return;
      end if;

      Journal.Append (S, Ok);
      if Ok then
         Last_Logged := S.Timestamp;
         Logged_Any  := True;
      elsif Journal.Is_Full then
         Full := True;
         Payload.Led_On;
      else
         Bump (Errors);
      end if;
   end Log;

   --  Keep S in the pre-launch buffer, dropping the oldest when full.
   procedure Remember (S : Telemetry.Sample) is
   begin
      Ring (Ring_Next) := S;
      Ring_Next := Ring_Next + 1;
      if Ring_Count < Ring_Size then
         Ring_Count := Ring_Count + 1;
      end if;
   end Remember;

   --  Log the pre-launch buffer, oldest first, then empty it.
   procedure Log_Remembered is
      I : Ring_Index := Ring_Next - Ring_Index'Mod (Ring_Count);
   begin
      for N in 1 .. Ring_Count loop
         Log (Ring (I));
         I := I + 1;
      end loop;
      Ring_Count := 0;
   end Log_Remembered;

   procedure Resume;

   --  Start the devices and open the journal, then set up the state
   --  machine. Retries device faults; halts if the flash shouldn't be
   --  written to.
   procedure Start is
      Checks : Payload.Check_Result;
      Header : Telemetry.Header;
      Status : Journal.Open_Status;
      Ok     : Boolean;
   begin
      --  fast blink and retry until every device responds
      loop
         Payload.Initialize (Checks);
         exit when Payload.All_Ok (Checks);
         Fault_Blink;
      end loop;
      Counts_Per_G := Payload.Imu.Accel_Counts_Per_G;

      --  the header holds the settings and calibration, so the log
      --  describes itself
      loop
         Payload.Make_Header (Tick_Us, Log_Every, Header, Ok);
         exit when Ok;
         Fault_Blink;
      end loop;

      loop
         Journal.Open_Append (Header, Status);
         exit when Status /= Journal.Flash_Fault;
         Fault_Blink;
      end loop;

      case Status is
         when Journal.Fresh =>
            Flight.Reset (Machine);

         when Journal.Resumed =>
            Resume;

         when Journal.Full =>
            Full := True;
            Payload.Led_On;

         when Journal.Needs_Dump | Journal.Needs_Erase
            | Journal.Wrong_Format =>
            Halt_Needs_Dump;

         when Journal.Flash_Fault =>
            null;  --  handled by the retry loop above
      end case;
   end Start;

   --  Pick up a flight that a reset cut off. On the pad this is the same
   --  as a fresh start: the jumper is still in, so the next tick re-arms.
   procedure Resume is
      Info      : Journal.Log_Info;
      Header    : Telemetry.Header;
      Last_Pad  : Telemetry.Sample;
      Found     : Boolean;
      Ok        : Boolean;
   begin
      Flight.Reset (Machine);
      Journal.Inspect (Info, Header, Ok);
      if not Ok or else Info.Last_Phase <= Flight.Pad then
         return;
      end if;

      Journal.Find_Last_Record (Flight.Pad, Last_Pad, Found);
      if not Found then
         --  no pad pressure to measure from, so altitude starts from here
         Bump (Errors);
         return;
      end if;

      Flight.Resume
        (Machine, Info.Last_Phase, Baro_Types.To_Pa (Last_Pad.Pressure),
         Payload.Clock_Ms);
      Phase := Info.Last_Phase;
   end Resume;

   --  Read the barometer if this tick is due for it. A failed read keeps
   --  the previous values and adds to the error count.
   procedure Read_Baro is
      R  : Baro_Types.Reading;
      Ok : Boolean;
   begin
      if Ticks mod Baro_Interval /= 0 then
         return;
      end if;

      Payload.Baro.Read (R, Ok);
      if Ok then
         Baro_Now  := R;
         Pressure  := Baro_Types.To_Pa (R.Pressure);
         Have_Baro := True;
      else
         Bump (Errors);
      end if;
   end Read_Baro;

   --  Returns the mean acceleration of Batch (1 .. Count), in g.
   function Mean_Accel_G (Count : Positive) return Float is
      Sum : Float := 0.0;
   begin
      for I in 1 .. Count loop
         Sum := Sum + Flight.Magnitude
           (Float (Batch (I).Accel (X)),
            Float (Batch (I).Accel (Y)),
            Float (Batch (I).Accel (Z)));
      end loop;
      return Sum / Float (Count) / Counts_Per_G;
   end Mean_Accel_G;

   --  Arm or disarm from the jumper, then step the state machine.
   procedure Update_Phase (Count : Natural) is
      Changed : Boolean;
   begin
      --  arming needs a pressure for the ground reference
      if Flight.Current (Machine) = Flight.Idle then
         if Payload.Armed and then Have_Baro then
            Flight.Arm (Machine, Payload.Clock_Ms, Pressure);
         end if;
      elsif Flight.Current (Machine) = Flight.Pad
        and then not Payload.Armed
      then
         Flight.Disarm (Machine);
      end if;

      if Count > 0 and then Have_Baro then
         Flight.Step
           (Machine, Payload.Clock_Ms, Mean_Accel_G (Count), Pressure,
            Changed);
      end if;
   end Update_Phase;

   --  If the phase moved, close the page in the old phase so every page
   --  holds one phase, then switch over.
   procedure Change_Phase is
      New_Phase : constant Flight.Phase := Flight.Current (Machine);
      Ok        : Boolean;
   begin
      if New_Phase = Phase then
         return;
      end if;

      Journal.Flush (Ok);
      if not Ok then
         Bump (Errors);
      end if;

      Journal.Set_Status (New_Phase, Missed, Errors, Payload.Battery_mV);
      if Phase = Flight.Pad and then New_Phase = Flight.Boost then
         Log_Remembered;
      end if;

      Phase     := New_Phase;
      Since_Log := 0;
   end Change_Phase;

   --  One pass of the loop.
   procedure Do_Tick is
      Count : Natural;
      Ok    : Boolean;
      Every : Natural;
      S     : Telemetry.Sample;
   begin
      Ticks := Ticks + 1;
      Read_Baro;

      --  drain the FIFO every tick, even when not logging, so it never
      --  overflows
      Payload.Imu.Read_Batch (Batch, Count, Ok);
      if not Ok then
         Bump (Errors);
      end if;

      Update_Phase (Count);
      Change_Phase;
      Journal.Set_Status (Phase, Missed, Errors, Payload.Battery_mV);

      Every := Natural (Log_Every (Flight.Phase'Pos (Phase)));
      for I in 1 .. Count loop
         S := Telemetry.Make (Batch (I), Baro_Now);

         if Phase = Flight.Pad then
            Remember (S);
         end if;

         if Every > 0 then
            Since_Log := Since_Log + 1;
            if Since_Log >= Every then
               Since_Log := 0;
               Log (S);
            end if;
         end if;
      end loop;
   end Do_Tick;

   --  Toggle the LED at the rate for this phase. Solid on when full.
   procedure Update_Led is
   begin
      if not Full
        and then Ticks mod Unsigned_32 (Led_Every (Flight.Phase'Pos (Phase)))
                 = 0
      then
         Payload.Led_Toggle;
      end if;
   end Update_Led;

   --  Wait until the next tick is due. Each deadline comes from the
   --  previous one, so variation in the work doesn't build up as drift. If
   --  the deadline has already passed, this counts a miss and restarts from
   --  now instead of rushing to catch up.
   procedure Wait_For_Next_Tick is
   begin
      if Clock >= Deadline then
         Bump (Missed);
         Deadline := Clock + Tick;
         return;
      end if;

      delay until Deadline;
      Deadline := Deadline + Tick;
   end Wait_For_Next_Tick;

begin
   Start;

   --  main loop: do the work, then wait for the next 10 ms deadline
   Deadline := Clock + Tick;
   loop
      Do_Tick;
      Update_Led;
      Wait_For_Next_Tick;
   end loop;
end Flight_Logger;

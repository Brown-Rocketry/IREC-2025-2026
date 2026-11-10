--  logger_recorder.adb

with Interfaces; use Interfaces;

with Logger_Health;
with Logger_Led;
with Logger_Pre_Launch;

package body Logger_Recorder is

   package Flight  renames Payload.Flight;
   package Journal renames Payload.Journal;

   use type Flight.Phase;

   Current     : Flight.Phase := Flight.Idle;
   Since_Log   : Natural := 0;      --  IMU samples since the last logged
   Last_Logged : Unsigned_32 := 0;  --  timestamp of the last logged record
   Logged_Any  : Boolean := False;
   Full        : Boolean := False;

   procedure Start (Phase : Flight.Phase) is
   begin
      Current := Phase;
   end Start;

   function Phase return Flight.Phase is (Current);

   --  Returns True if timestamp T is after the last logged record. The
   --  difference is taken in Unsigned_32, which wraps, so it is still right
   --  across the 71-minute wrap: a newer T is 1 .. 2**31 - 1 ahead, an older
   --  or equal one comes out as 0 or 2**31 and above.
   function Is_Newer (T : Unsigned_32) return Boolean is
   begin
      return not Logged_Any
        or else (T - Last_Logged) in 1 .. 2**31 - 1;
   end Is_Newer;

   procedure Set_Full is
   begin
      Full := True;
      Logger_Led.Show_Full;
   end Set_Full;

   --  Append one record to the journal.
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
         Set_Full;
      else
         Logger_Health.Count_Error;
      end if;
   end Log;

   --  Log the pre-launch buffer, oldest first, which empties it.
   procedure Log_Pre_Launch is
      S   : Telemetry.Sample;
      Got : Boolean;
   begin
      loop
         Logger_Pre_Launch.Take_Oldest (S, Got);
         exit when not Got;
         Log (S);
      end loop;
   end Log_Pre_Launch;

   procedure Update_Status is
   begin
      Journal.Set_Status
        (Current, Logger_Health.Missed, Logger_Health.Errors,
         Payload.Battery_mV);
   end Update_Status;

   procedure Change_Phase (New_Phase : Flight.Phase) is
      Old_Phase : constant Flight.Phase := Current;
      Ok        : Boolean;
   begin
      if New_Phase = Old_Phase then
         return;
      end if;

      Journal.Flush (Ok);
      if not Ok then
         Logger_Health.Count_Error;
      end if;

      Current   := New_Phase;
      Since_Log := 0;
      Update_Status;

      if Old_Phase = Flight.Pad and then New_Phase = Flight.Boost then
         Log_Pre_Launch;
      end if;
   end Change_Phase;

   procedure Offer (S : Telemetry.Sample) is
      Every : constant Natural :=
        Natural (Log_Every (Flight.Phase'Pos (Current)));
   begin
      if Current = Flight.Pad then
         Logger_Pre_Launch.Remember (S);
      end if;

      if Every > 0 then
         Since_Log := Since_Log + 1;
         if Since_Log >= Every then
            Since_Log := 0;
            Log (S);
         end if;
      end if;
   end Offer;

   function Is_Full return Boolean is (Full);

end Logger_Recorder;

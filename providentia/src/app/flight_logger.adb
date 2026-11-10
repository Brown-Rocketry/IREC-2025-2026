--  flight_logger.adb
--  Flight firmware. Logs IMU and barometer data to flash in one
--  fixed-period loop, at a rate set by the flight phase. No console output.
--  Run flash_dump and mark the last flight dumped before each campaign.
--
--  General plan:
--  Start brings up the devices, writes the settings into a journal header
--  and opens the journal. Then every 10 ms tick:
--     1. read the barometer if due (every 2nd tick, 50 Hz)
--     2. drain the IMU FIFO (833 Hz, about 8 samples)
--     3. step the state machine with their mean acceleration
--     4. close the page if the phase changed
--     5. offer each IMU sample, with the latest baro reading, to the log
--  The work is split into packages under logger/, one job each:
--     Logger_Timing      the 10 ms deadline
--     Logger_Sensors     reading the IMU and barometer
--     Logger_Phase       the state machine and the arm jumper
--     Logger_Recorder    which samples are logged, and page closing
--     Logger_Pre_Launch  the last 0.3 s on the pad
--     Logger_Led         what the LED shows
--     Logger_Health      missed deadlines and failed reads

with Logger_Led;
with Logger_Phase;
with Logger_Recorder;
with Logger_Sensors;
with Logger_Timing;
with Payload;
with Telemetry;

procedure Flight_Logger is

   package Journal renames Payload.Journal;

   use type Journal.Open_Status;

   --  Start the devices and open the journal. Retries device faults;
   --  halts if the flash holds a flight that hasn't been read back.
   procedure Start is
      Checks : Payload.Check_Result;
      Header : Telemetry.Header;
      Status : Journal.Open_Status;
      Ok     : Boolean;
   begin
      loop
         Payload.Initialize (Checks);
         exit when Payload.All_Ok (Checks);
         Logger_Led.Fault_Blink;
      end loop;
      Logger_Sensors.Start;

      --  the header holds the settings and calibration, so the log
      --  describes itself
      loop
         Payload.Make_Header
           (Logger_Timing.Tick_Us, Logger_Recorder.Log_Every, Header, Ok);
         exit when Ok;
         Logger_Led.Fault_Blink;
      end loop;

      loop
         Journal.Open_Append (Header, Status);
         exit when Status /= Journal.Flash_Fault;
         Logger_Led.Fault_Blink;
      end loop;

      case Status is
         when Journal.Fresh       => Logger_Phase.Start;
         when Journal.Resumed     => Logger_Phase.Resume;
         when Journal.Full        => Logger_Recorder.Set_Full;
         when Journal.Needs_Dump  => Logger_Led.Halt_Needs_Dump;
         when Journal.Flash_Fault => null;  --  retried above
      end case;
      Logger_Recorder.Start (Logger_Phase.Current);
   end Start;

   Batch : Logger_Sensors.Imu_Batch;
   Count : Natural;

begin
   Start;
   Logger_Timing.Start;

   loop
      Logger_Sensors.Read_Baro_If_Due;
      Logger_Sensors.Read_Imu (Batch, Count);

      Logger_Phase.Update (Batch, Count);
      Logger_Recorder.Change_Phase (Logger_Phase.Current);
      Logger_Recorder.Update_Status;

      for I in 1 .. Count loop
         Logger_Recorder.Offer
           (Telemetry.Make (Batch (I), Logger_Sensors.Baro_Raw));
      end loop;

      Logger_Led.Update (Logger_Recorder.Phase);
      Logger_Timing.Wait_For_Next_Tick;
   end loop;
end Flight_Logger;

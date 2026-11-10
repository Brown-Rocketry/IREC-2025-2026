--  logger_phase.ads
--  The flight state machine, fed from the sensors and the arm jumper. Part
--  of flight_logger.
--
--  General plan:
--  The arm jumper moves Idle to Pad. Pulling it on the pad goes back to
--  Idle; pulling it in flight does nothing. Arming needs one baro reading
--  first, since the pad pressure is the ground reference for altitude.
--
--  A reset in flight resumes: the journal finds the first blank page, and
--  the state machine restarts in the last logged phase with the last pad
--  pressure as its ground reference. On the pad a resume is the same as a
--  fresh start, because the jumper is still in and the next tick re-arms.

with Payload;
with Logger_Sensors;

package Logger_Phase is

   --  Start in Idle.
   procedure Start;

   --  Pick up a flight that a reset cut off.
   procedure Resume;

   --  Arm or disarm from the jumper, then step the state machine with this
   --  tick's IMU batch.
   procedure Update (Batch : Logger_Sensors.Imu_Batch; Count : Natural);

   --  Returns the phase the state machine is in.
   function Current return Payload.Flight.Phase;

end Logger_Phase;

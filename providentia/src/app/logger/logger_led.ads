--  logger_led.ads
--  What the LED shows while flight_logger runs. Part of flight_logger.
--
--  General plan:
--     Toggles every 1 s      Idle, not armed
--     Toggles every 0.25 s   Pad, armed
--     Toggles every 50 ms    In flight
--     Toggles every 2 s      Landed, log complete
--     Solid on               Flash full, logging stopped
--     Fast blink             Boot fault: a device isn't responding. Keeps
--                            retrying.
--     Double blink           Flash holds a flight that hasn't been read
--                            back, or another format. Run flash_dump.
--                            Doesn't retry, so the data is safe.

with Payload;

package Logger_Led is

   --  Blink fast for about a second. The caller loops on it and retries.
   procedure Fault_Blink;

   --  Double blink forever. Never returns, so nothing on the flash can be
   --  overwritten.
   procedure Halt_Needs_Dump
     with No_Return;

   --  Solid on from now on: the flash is full.
   procedure Show_Full;

   --  Toggle at the rate for Phase, on the ticks that are due. Does
   --  nothing once Show_Full has been called.
   procedure Update (Phase : Payload.Flight.Phase);

end Logger_Led;

--  flight_state.ads
--  Flight phase detection from acceleration and pressure. Part of
--  flight_state_generic. No hardware access, so it can be tested on a host
--  machine by replaying a recovered log.
--
--  General plan:
--  Idle    not armed. Nothing is logged, so bench time costs no flash.
--  Pad     armed and waiting. Tracks ground pressure slowly so weather
--          drift over hours on the pad doesn't become altitude.
--  Boost   accel above Launch_G for Launch_Hold_Ms.
--  Coast   accel below Burnout_G for Burnout_Hold_Ms.
--  Descent altitude falling for Apogee_Hold_Ms, but not until
--          Apogee_Lockout_Ms after burnout, so the pressure dip at high
--          speed can't trigger it early.
--  Landed  altitude inside Landed_Band_M and accel within Landed_G_Band of
--          1 g, both for Landed_Hold_Ms.
--
--  Phases only move forward once armed. Disarm only works on the pad, so a
--  loose arm jumper in flight can't stop logging.
--
--  Why 3 g and 100 ms: in the April 2026 log boost was the only sustained
--  stretch above 3 g in 25 hours, and ada-flight-logger's shake test
--  triggered cleanly on the same setting. Re-tune every threshold against
--  the April log before flight.

with Interfaces; use Interfaces;

generic
   Launch_G          : Float   := 3.0;
   Launch_Hold_Ms    : Natural := 100;
   Burnout_G         : Float   := 1.5;
   Burnout_Hold_Ms   : Natural := 200;
   Apogee_Lockout_Ms : Natural := 3_000;
   Apogee_Hold_Ms    : Natural := 1_000;
   Landed_Band_M     : Float   := 2.0;
   Landed_G_Band     : Float   := 0.2;
   Landed_Hold_Ms    : Natural := 10_000;
package Flight_State
  with Pure
is
   --  values are the byte stored in every page trailer, so don't reorder
   type Phase is (Idle, Pad, Boost, Coast, Descent, Landed);
   for Phase use
     (Idle => 0, Pad => 1, Boost => 2, Coast => 3, Descent => 4, Landed => 5);

   --  milliseconds since boot; wraps after 49 days, which is handled
   subtype Time_Ms is Unsigned_32;

   --  holds the phase, the ground reference and the hold timers
   type Machine is private;

   --  Go back to Idle and forget the ground reference.
   procedure Reset (M : in out Machine);

   --  Idle to Pad. Pressure_Pa becomes the first ground reference. No
   --  effect in any other phase.
   procedure Arm
     (M           : in out Machine;
      Now         : Time_Ms;
      Pressure_Pa : Float);

   --  Pad to Idle. No effect in any other phase.
   procedure Disarm (M : in out Machine);

   --  Restart in From after a reboot, with Ground_Pa as the pad reference.
   --  Hold timers start over, and the apogee lockout restarts if From is
   --  Coast. Use the last pad record from the journal for Ground_Pa.
   procedure Resume
     (M         : in out Machine;
      From      : Phase;
      Ground_Pa : Float;
      Now       : Time_Ms);

   --  Feed in one step. Accel_G is the acceleration magnitude in g, as
   --  from Magnitude. Changed is True on the step the phase moved; read the
   --  new one with Current. Call at a steady rate, at least every 10 ms
   --  during flight, so the hold times mean what they say.
   procedure Step
     (M           : in out Machine;
      Now         : Time_Ms;
      Accel_G     : Float;
      Pressure_Pa : Float;
      Changed     : out Boolean);

   --  Returns the current phase.
   function Current (M : Machine) return Phase;

   --  Returns the latest altitude above the pad in meters. 0 before Arm.
   function Altitude_M (M : Machine) return Float;

   --  Returns the highest altitude seen since launch, in meters.
   function Max_Altitude_M (M : Machine) return Float;

   --  Returns the pad reference pressure in pascals. 0 before Arm.
   function Ground_Pressure_Pa (M : Machine) return Float;

   --  Altitude in meters of Pressure_Pa above Ground_Pa, from the standard
   --  atmosphere. Good to about 1 percent below 11 km.
   function Pressure_Altitude_M (Pressure_Pa, Ground_Pa : Float) return Float;

   --  Length of an acceleration vector, in the units it was given in.
   function Magnitude (X, Y, Z : Float) return Float;

private
   type Machine is record
      Current      : Phase   := Idle;
      Ground_Pa    : Float   := 0.0;
      Altitude     : Float   := 0.0;
      Max_Altitude : Float   := 0.0;
      Last_Step    : Time_Ms := 0;
      Held_Since   : Time_Ms := 0;      --  when the pending condition began
      Holding      : Boolean := False;  --  is a condition being timed now
      Burnout_At   : Time_Ms := 0;      --  start of the apogee lockout
   end record;
end Flight_State;

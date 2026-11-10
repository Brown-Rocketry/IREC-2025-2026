--  payload.ads
--  The Providentia payload board as the application sees it: the IMU,
--  barometer, flash, arm jumper, LED and clock, plus the journal and state
--  machine set up for them. Part of providentia_payload.
--
--  General plan:
--  The mains only ever with Payload, Telemetry and Console_Text. Chips,
--  pins, buses and clocks are named only in the body, so a new experiment
--  on this board is a new main, and new hardware is a copy of this crate
--  with the body changed.
--
--  The body instantiates the chip crates and the class interfaces, the
--  same way nucleo_g431kb's Instances does for the MCU:
--     Imu   LSM6DSO32 on Spi_1, its own CS pin     -> Imu_Interface
--     Baro  BMP390 on I2C_1, address 16#77#,
--           through BMP3XX_I2C_Bus                 -> Baro_Interface
--     Flash W25Q128 on Spi_1, Board.Spi_1_Cs       -> Nor_Flash_Interface
--  The nested packages below forward to those instances, so this spec
--  compiles before the chip crates exist.
--
--  Nothing here raises. Failures come back as Ok flags so the logger can
--  count them and keep going. Exceptions inside the GHAL bus drivers still
--  reach the last chance handler (No_Exception_Propagation), which is
--  tracked as a chain issue.

with Interfaces; use Interfaces;
with System.Storage_Elements; use System.Storage_Elements;

with Baro_Types;
with Flight_Journal;
with Flight_State;
with Imu_Types;
with Telemetry;

package Payload is

   Board_Id : constant Telemetry.Board_Id_String := "providentia r2  ";

   --  The settings the payload runs with, also written to the journal
   --  header. 833 Hz with the low pass filter keeps motor vibration from
   --  aliasing. +/-32 g leaves room above the 14.5 g seen in April, which
   --  was 90 percent of the old +/-16 g range.
   Imu_Settings : constant Imu_Types.Imu_Config :=
     (Accel_Range  => Imu_Types.G32,
      Gyro_Range   => Imu_Types.DPS_2000,
      Accel_ODR_Hz => 833,
      Gyro_ODR_Hz  => 833,
      Low_Pass     => True);

   --  X8 pressure and X1 temperature take about 19 ms, inside the 20 ms
   --  period at 50 Hz.
   Baro_Settings : constant Baro_Types.Baro_Config :=
     (Pressure_OSR    => Baro_Types.X8,
      Temperature_OSR => Baro_Types.X1,
      Rate_Hz         => 50,
      Filter_On       => False);

   --  result of each startup check, True when it passed
   type Check_Result is record
      Flash : Boolean := False;  --  JEDEC id matched and the chip opened
      Imu   : Boolean := False;  --  id matched and Imu_Settings accepted
      Baro  : Boolean := False;  --  id matched and Baro_Settings accepted
   end record;

   --  Returns True if every check passed.
   function All_Ok (R : Check_Result) return Boolean is
     (R.Flash and then R.Imu and then R.Baro);

   --  Start the board (console at 115200, Spi_1 at 10 MHz mode 0, I2C_1 at
   --  400 kHz, CS, arm and LED pins), then check and configure each device.
   --  Safe to call again to retry after a failure.
   procedure Initialize (Result : out Check_Result);

   --  Microseconds since boot, lower 32 bits. Wraps about every 71 minutes.
   function Clock_Us return Unsigned_32;

   --  Milliseconds since boot. Wraps after 49 days.
   function Clock_Ms return Unsigned_32;

   --  Returns True when the arm jumper is in.
   function Armed return Boolean;

   --  Battery voltage in millivolts. 0 until the ADC driver exists (step 6
   --  of the port).
   function Battery_mV return Unsigned_16;

   procedure Led_On;
   procedure Led_Off;
   procedure Led_Toggle;

   ---------------------------------------------------------------------
   --  Devices
   ---------------------------------------------------------------------

   --  The IMU. Same operations as Imu_Interface; see imu_interface.ads.
   package Imu is
      function Check_Id return Boolean;
      function Capabilities return Imu_Types.Imu_Caps;

      --  scale at Imu_Settings
      function Accel_Counts_Per_G return Float;
      function Gyro_Counts_Per_Dps return Float;

      procedure Read_Accel (V : out Imu_Types.Raw_Vector; Ok : out Boolean);
      procedure Read_Gyro (V : out Imu_Types.Raw_Vector; Ok : out Boolean);
      procedure Read_Batch
        (Buf   : out Imu_Types.Raw_Sample_Array;
         Count : out Natural;
         Ok    : out Boolean);
   end Imu;

   --  The barometer. Same operations as Baro_Interface; see
   --  baro_interface.ads. Readings are compensated, in fixed units; use
   --  Baro_Types.To_Pa and To_C for floats.
   package Baro is
      function Check_Id return Boolean;
      function Data_Ready return Boolean;
      procedure Read (R : out Baro_Types.Reading; Ok : out Boolean);
      procedure Read_Calibration
        (Cal : out Baro_Types.Calibration_Blob;
         Ok  : out Boolean);
   end Baro;

   --  The flash, as the journal needs it. The application normally goes
   --  through Journal instead.
   package Flash is
      Page_Size   : constant := 256;
      Total_Pages : constant := 65_536;  --  16 MB

      --  Returns True if the JEDEC id is the W25Q128's (EF 40 18).
      function Check_Id return Boolean;

      procedure Write_Page
        (Addr : Unsigned_32;
         Data : Storage_Array;
         Ok   : out Boolean);
      procedure Read
        (Addr : Unsigned_32;
         Data : out Storage_Array;
         Ok   : out Boolean);

      --  Blocks for 40 s typical, up to 200 s on the W25Q128.
      procedure Erase_Chip (Ok : out Boolean);
   end Flash;

   ---------------------------------------------------------------------
   --  Rocketry layer
   ---------------------------------------------------------------------

   --  default thresholds; see flight_state.ads
   package Flight is new Flight_State;

   package Journal is new Flight_Journal
     (Record_Type      => Telemetry.Sample,
      Record_Size      => Telemetry.Sample_Size,
      Timestamp_Of     => Telemetry.Timestamp_Of,
      Header_Type      => Telemetry.Header,
      Header_Size      => Telemetry.Header_Size,
      Phase_Type       => Flight.Phase,
      Final_Phase      => Flight.Landed,
      Format_Version   => Telemetry.Format_Version,
      Page_Size        => Flash.Page_Size,
      Total_Pages      => Flash.Total_Pages,
      Flash_Write_Page => Flash.Write_Page,
      Flash_Read       => Flash.Read,
      Flash_Erase_Chip => Flash.Erase_Chip,
      Armed            => Armed);

   --  Returns a journal header filled in with Imu_Settings, Baro_Settings,
   --  the IMU scales and the baro calibration, plus the caller's loop tick
   --  and decimation. Ok is False if the calibration read failed.
   procedure Make_Header
     (Tick_Us   : Unsigned_32;
      Log_Every : Telemetry.Decimation_Table;
      H         : out Telemetry.Header;
      Ok        : out Boolean);

end Payload;

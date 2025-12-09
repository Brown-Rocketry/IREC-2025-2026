# Brown Rocketry - IREC 2025 Flight Software

**Team:** Brown Rocketry  
**Rocket Name:** Providentia  
**Project Name:** The Bear Minimum  
**Competition:** IREC 2025 - 10K COTS Category

## Overview

This repository contains the avionics and data acquisition systems for Brown University's first entry into the International Rocketry Engineering Competition (IREC). Our rocket, Providentia, is a dual-deployment rocket targeting 10,000 feet AGL, carrying a 4.1kg 3U CubeSat payload containing a sealed micro-terrarium experiment.

**Mission:** Test the effects of short-term thermal, vibrational, and shock stresses on an enclosed micro-ecosystem during high-power rocket flight.

## Team

- **Student Lead:** Ethan Kim
- **Alt Student Lead / Avionics Lead:** Chicha Nimitpornsuko
- **Faculty Advisor:** Daniel Harris
- **Team Mentor:** Peter Tarle (TRA L3, #18555)
- **Flyer of Record:** Sam Hamilton (TRA L3, #16415)

### Avionics Subsystem Team
Led by Chicha Nimitpornsuko, the avionics team is responsible for:
- Flight computer configuration and testing
- Recovery system electronics and deployment charges
- Telemetry and GPS tracking systems
- Payload data acquisition system development
- Ground station operations
- Pre-flight electronics checkout procedures

**Team Members:**
- **Chicha Nimitpornsuko** (chompoonek_nimitpornsuko@brown.edu) - Avionics Lead
- **Margeaux Corrigan** (margeaux_corrigan@brown.edu) - Incoming IREC Avionics Lead
- **George Liao** (george_liao@brown.edu) - Avionics Team Member

*Specific role assignments within the avionics subsystem are being finalized as the team develops.*

## Vehicle Specifications

- **Length:** 2.26 m
- **Diameter:** 157 mm
- **Liftoff Weight:** 22.86 kg (with motor)
- **Payload Weight:** 4.1 kg
- **Motor:** Aerotech M1800FJ-4 (8207.7 N-s total impulse)
- **Target Apogee:** 10,000 ft AGL
- **Predicted Apogee:** 10,413 ft AGL
- **Max Velocity:** 311 m/s
- **Max Acceleration:** 12.44 G

## System Architecture

### Flight Computers
- **Primary & Backup:** 2x Blue Raven altimeters (dual redundancy)
- Each powered by independent Molicel P45B 21700 Li-ion batteries
- Separate pull-pin arming switches for each circuit
- Configured for dual-deployment recovery

### Recovery System
- **Drogue Deployment:** Apogee (~12,000 ft MSL)
  - Parachute: Fruity Chutes 24" drogue (Cd 2.2)
  - Primary: 1.0g black powder
  - Backup: 1.5g black powder
  - Descent rate: 31.1 m/s

- **Main Deployment:** 1,500 ft AGL
  - Parachute: Fruity Chutes 96" Iris Ultra (Cd 2.2)
  - Primary: 2.0g black powder
  - Backup: 3.0g black powder
  - Descent rate: 5.17 m/s
  - Landing impact energy: 305J

### Telemetry & Tracking
- **Primary GPS:** BigRedBee 70 cm (915 MHz) in nosecone
- **Backup GPS:** 2x Featherweight GPS modules in avionics bay
- **Licensed Operator:** Jason Zhao (VE7ITB - Canadian Amateur Radio Basic with Honours)
- **Live Video:** 2x DJI O3 Air Unit cameras with live streaming capability

### Payload Data Acquisition
Multi-microcontroller system for monitoring the terrarium payload and flight dynamics(some details TBD):

**AdaCore/STM32 System (Primary Flight Data):**
- STM32 Nucleo-G431KB development board
- Adafruit BNO055 9-DOF IMU (acceleration, gyroscope, magnetometer)
- Adafruit BMP580 temperature and pressure sensor
- Possible terrarium environmental sensors integration
- SD card module for data logging
- Independent Molicel P45B battery with pull-pin switch

**Arduino System (GPS & Recovery):**
- Arduino Uno R3 microcontroller
- M10 u-blox GPS module
- Recovery system monitoring
- Parachute deployment event logging
- Independent power supply

**Monitored Parameters:**
- Temperature (external and internal to terrarium)
- Barometric pressure
- Humidity (if integrated with AdaCore system)
- 9-axis motion data (3-axis acceleration, gyroscope, magnetometer)
- GPS position and altitude
- Recovery events (drogue and main deployment timestamps)
- Timestamp for all measurements

**Data Storage:** All sensor data logged to SD card for post-flight analysis

## Payload Information

The payload is a functional 3U CubeSat (10 cm × 10 cm × 30 cm) containing a hermetically sealed micro-terrarium with living plant life (moss, succulents, or basil). The experiment aims to correlate external launch environment conditions with the sealed terrarium environment to assess biological component survivability under launch conditions.

**Payload Goals:**
- Monitor impact of high-G acceleration on enclosed ecosystem
- Track thermal environment during flight
- Document vibrational and shock loads
- Post-flight visual assessment of plant health
- Correlation analysis between sensor data and flight timeline

## Software Components

### Flight Control
- Blue Raven firmware configuration for dual deployment
- Apogee detection and drogue deployment
- Barometric altitude-based main deployment at 1,500 ft AGL

### Data Acquisition (Arduino)(not confirmed)
- Real-time sensor polling and timestamping
- SD card data logging with error handling
- Low-power operation during coast phase
- Post-flight data retrieval interface

### Ground Station
- GPS tracking and mapping
- Live video feed reception
- Flight telemetry monitoring

## Installation & Setup

### Required Tools
- Arduino IDE 1.8.x or 2.x
- Blue Raven configuration software
- Featherweight GPS configuration utility

### Arduino Libraries(not confirmed)
```
- Wire.h (I2C communication)
- SPI.h (SD card interface)
- SD.h (SD card operations)
- Adafruit_BMP280.h (pressure/temp sensor)
- Adafruit_BNO055.h (9-DOF IMU)
- Adafruit_Sensor.h (unified sensor library)
- TinyGPS++.h (GPS parsing)
```

### Flashing Procedure
1. Connect Arduino via USB
2. Open payload_data_logger.ino in Arduino IDE
3. Select board: Arduino Uno
4. Select appropriate COM port
5. Upload sketch
6. Verify SD card initialization via serial monitor

### Pre-Flight Configuration
- Format SD card (FAT32)
- Set deployment altitudes in Blue Raven units
- Verify GPS lock before rail departure
- Arm all circuits via pull-pin switches during final countdown

## Testing

### Completed Tests
- **Avionics Integration:** All electronic systems bench tested
- **High-Temperature Testing:** Deployment reliability under extended heat exposure
- **Battery Drain Test:** Performance verification under extreme conditions
- **GPS Functionality:** Lock acquisition and tracking accuracy
- **Camera Activation:** Video feed initiation and quality check

### Planned Tests (December 2025 - February 2026)
- Full system integration test
- Ground ejection tests (primary and backup charges)
- Subscale test flight for telemetry validation
- Full-scale test launch (February 2026)

## Safety & Compliance

- All recovery charges sized per NFPA 1127 and IREC guidelines
- Dual redundancy on all flight-critical systems
- Independent battery circuits prevent single-point failures
- Pull-pin arming switches prevent accidental activation
- Shock cord rated 5,600 lbs (3/8" Technora)
- All personnel maintain safe distance during arming and launch
- Mentor and FOR oversight for all launch operations

## Flight Data

Post-flight data analysis will include:
- Altitude vs. time profile
- Velocity and acceleration curves
- GPS trajectory mapping
- Payload environmental data correlation
- Parachute deployment timing verification
- Cross-range drift analysis (wind effects)

## Competition Results

*Section to be updated after IREC 2025 competition*

## Outreach

Brown Rocketry is committed to promoting aerospace accessibility. Through the Pathways to Diversity Fund and partnerships with the Society of Hispanic Professional Engineers (SHPE) and Society of Women Engineers (SWE), we host workshops and collaborative launches to lower barriers for underrepresented groups in rocketry.

## License

MIT License - See LICENSE file for details

## Acknowledgments

- **RIMRA** (Rhode Island Model Rocketry Association) for launch site access
- **Peter Tarle** for mentorship and technical guidance
- **Pathways to Diversity Fund** and **Hazeltine Engineering Grant** for financial support
- **University of Rhode Island** for collaborative launch partnerships
- **ESRA** for hosting IREC 2025

## Contact

- **Website:** https://sites.google.com/brown.edu/brown-rocketry/home
- **Instagram:** @brownrocketry
- **Email:** ethan_m_kim@brown.edu

---

*Go Bears! 🐻🚀*

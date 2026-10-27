#!/bin/sh
# Clone the bus generics that stm32g431_ghal path-pins (see alire.toml),
# then build. Safe to rerun.
set -e
cd "$(dirname "$0")"
mkdir -p alire/cache/pins
for crate in i2c_generic spi_generic usart_generic; do
   if [ ! -d "alire/cache/pins/$crate" ]; then
      git clone -q -b main "https://github.com/GNAT-Academic-Program/$crate.git" "alire/cache/pins/$crate"
   fi
done
alr build

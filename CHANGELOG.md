# Changelog

All notable changes to `ex_dlt645` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-11-13

### Features
- **Standard Protocol Support**:
  - Full implementation of DL/T 645-2007 (and 1997) multi-function electricity meter communications protocol.
  - Comprehensive Data Identifier coverage across Tables A.1 to A.7 (Energy, Demand, Variables, Events, Parameters, Freeze, Load).
- **Pure Functional Codec (`ExDlt645.Codec`)**:
  - Stateless binary pattern matching for packet framing and deframing.
  - Automatic `+0x33` modulo-256 transformation and checksum (CS) verification.
- **Data Identifier Dictionary & Scalers (`ExDlt645.DataId`)**:
  - Extensive registry covering thousands of standard DIs with automated decimal formatting (`XXXXXX.XX`, `XXX.X`, `XXX.XXX`, `XX.XXXX`, `X.XXX`, `XX.XX`).
  - Unit annotations and read/write attribute validation.
- **Hardware-Free In-Memory Virtual Serial Bus (`ExDlt645.VirtualBus`)**:
  - In-memory multi-drop serial bus with process monitoring and lock-free broadcast.
  - Allows 100% closed-loop testing, CI/CD execution, and Phoenix LiveView UI simulation without real RS-485 hardware.
- **Pluggable Transports (`ExDlt645.Transport`)**:
  - `ExDlt645.Transport.UART`: Hardware serial port communication backed by `Circuits.UART`.
  - `ExDlt645.Transport.Virtual`: Memory bus adapter for tests and local simulation.
  - `ExDlt645.Transport.Tcp`: Direct socket connection for Ethernet and 4G DTU transparent serial gateways.
- **Streaming Framer (`ExDlt645.Framer`)**:
  - Implements `Circuits.UART.Framing` behaviour.
  - Automatic `0xFE` preamble stripping, dynamic frame length derivation, and sliding-window byte-by-byte resynchronization.
- **Dual Operating Modes for Master (`ExDlt645.Master`)**:
  - Passive (synchronous call) and Active (asynchronous streaming notification) modes.
  - Half-duplex serialization with `:busy` protection.
  - Built-in support for transformer scaling factors (`:multiplier`, `:ct`, `:pt`).
- **Slave Simulator (`ExDlt645.Slave`)**:
  - In-memory virtual electricity meter simulator responding to read, write, address discovery, broadcast time calibration, and freeze commands.
- **Diagnostics & Command Line Interface (`ExDlt645.Query` & `mix dlt645`)**:
  - Point inspection (`info`, `show_info`), fuzzy keyword search (`search`), and raw frame deep diagnostics (`inspect_frame`).
  - Mix task `mix dlt645` for CLI workflows (`-i`, `-s`, `-p`, `-u`).
- **Telemetry (`ExDlt645.Telemetry`)**:
  - Measurement of request round-trip time (RTT), function codes, and error tracking.


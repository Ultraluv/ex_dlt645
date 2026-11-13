defmodule ExDlt645 do
  @moduledoc """
  A complete, idiomatic Elixir/OTP communication library for the DL/T 645-2007
  (and 1997) electricity meter protocol.

  ## Architecture & Key Features

  - **Pure Functional Codec (`ExDlt645.Codec`)**: Stateless packet encoding, decoding,
    +0x33 modulo 256 transformation, and checksum verification with binary pattern matching.
  - **Data Identifier Catalog (`ExDlt645.DataId`)**: Complete coverage of DL/T 645-2007
    tables (A.1 Energy, A.2 Demand, A.3 Variables, A.4 Events, A.5 Parameters, A.6 Freeze, A.7 Load).
  - **BCD Number & Datetime Engine (`ExDlt645.BCD`)**: Fast little-endian BCD conversions for
    numeric readings, meter addresses, timestamps, and wildcard matching.
  - **Streaming Framer (`ExDlt645.Framer`)**: `Circuits.UART.Framing` behaviour implementation
    featuring preamble stripping, frame length deduction, and sliding-window byte-by-byte resynchronization.
  - **Pluggable Transport Layer (`ExDlt645.Transport`)**:
    - Hardware UART (`ExDlt645.Transport.UART`) powered by `Circuits.UART`.
    - In-Memory Virtual Bus (`ExDlt645.Transport.Virtual` & `ExDlt645.VirtualBus`) for hardware-free CI/CD and simulation.
    - Raw TCP Client (`ExDlt645.Transport.Tcp`) for Ethernet/4G DTU serial servers.
  - **Master Collector (`ExDlt645.Master`)**: Half-duplex serialized request execution,
    busy guard, active (asynchronous event streaming) and passive (synchronous call) modes.
  - **Slave Meter Simulator (`ExDlt645.Slave`)**: In-memory virtual meter grid component for
    automated testing and interactive protocol playgrounds.
  - **Telemetry (`ExDlt645.Telemetry`)**: Start/stop measurements with RTT for all requests.

  ## Quick Start

  ### 1. In-Memory Virtual Loopback Testing (Hardware-free)

  ```elixir
  # Start a virtual electric meter slave
  {:ok, _slave} = ExDlt645.Slave.start_link(address: "123456789012", tty: "virtual")

  # Start a master collector on the same virtual bus
  {:ok, master} = ExDlt645.Master.start_link(tty: "virtual")

  # Read Total Forward Active Energy (DI: 0x00010000)
  {:ok, energy} = ExDlt645.read_data(master, "123456789012", 0x00010000)
  # => {:ok, 1234.56}

  # Read Phase A Voltage (DI: 0x02010100)
  {:ok, voltage} = ExDlt645.read_data(master, "123456789012", 0x02010100)
  # => {:ok, 220.0}

  # Broadcast read meter address
  {:ok, addr} = ExDlt645.read_address(master)
  # => {:ok, "123456789012"}
  ```

  ### 2. Physical RS-485 Serial Port

  ```elixir
  {:ok, master} = ExDlt645.Master.start_link(
    tty: "/dev/ttyUSB0",
    uart_opts: [speed: 2400, parity: :even]
  )

  {:ok, energy} = ExDlt645.read_data(master, "001234567890", 0x00010000)
  ```
  """

  alias ExDlt645.{BCD, Codec, DataId, Master, Query}

  # Master conveniences
  defdelegate read_data(master, address, di, opts \\ []), to: Master
  defdelegate read_address(master, opts \\ []), to: Master
  defdelegate write_data(master, address, di, data_payload, opts \\ []), to: Master
  defdelegate write_address(master, old_address, new_address, opts \\ []), to: Master
  defdelegate sync_time(master, datetime, opts \\ []), to: Master
  defdelegate freeze(master, address, freeze_time, opts \\ []), to: Master
  defdelegate custom_request(master, raw_packet, opts \\ []), to: Master

  # Query & Diagnostic conveniences
  defdelegate info(di), to: Query
  defdelegate show_info(di), to: Query
  defdelegate search(keyword), to: Query
  defdelegate inspect_frame(input), to: Query

  # DataId conveniences
  defdelegate lookup_di(di), to: DataId, as: :lookup
  defdelegate decode_value(di, payload), to: DataId
  defdelegate encode_value(di, value), to: DataId

  # BCD conveniences
  defdelegate encode_address(addr_str), to: BCD
  defdelegate decode_address(bytes), to: BCD

  # Codec conveniences
  defdelegate parse_frame(binary), to: Codec
  defdelegate pack_read_request(address, di, opts \\ []), to: Codec
  defdelegate pack_read_response(address, di, value_bytes, opts \\ []), to: Codec
  defdelegate checksum(binary), to: Codec
end

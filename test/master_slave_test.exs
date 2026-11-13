defmodule ExDlt645.MasterSlaveTest do
  use ExUnit.Case, async: false

  alias ExDlt645.{Frame, Master, Slave, VirtualBus}

  setup do
    bus_name = :"virtual_bus_#{System.unique_integer([:positive])}"
    {:ok, bus_pid} = VirtualBus.start_link(name: bus_name)

    addr = "123456789012"

    {:ok, slave_pid} =
      Slave.start_link(
        address: addr,
        tty: "virtual",
        uart_opts: [virtual_bus: bus_name],
        data: %{
          0x00010000 => 1234.56,
          0x02010100 => 220.0,
          0x02020100 => 1.500,
          0x02030000 => 0.3300
        }
      )

    {:ok, master_pid} =
      Master.start_link(
        tty: "virtual",
        uart_opts: [virtual_bus: bus_name],
        timeout: 2_000
      )

    on_exit(fn ->
      if Process.alive?(master_pid), do: Master.stop(master_pid)
      if Process.alive?(slave_pid), do: Slave.stop(slave_pid)
      if Process.alive?(bus_pid), do: GenServer.stop(bus_pid)
    end)

    %{bus: bus_name, slave: slave_pid, master: master_pid, address: addr}
  end

  describe "Master-Slave communication in passive mode" do
    test "reads forward active energy successfully", %{master: master, address: addr} do
      assert {:ok, 1234.56} = ExDlt645.read_data(master, addr, 0x00010000)
    end

    test "reads instantaneous voltage and current", %{master: master, address: addr} do
      assert {:ok, 220.0} = ExDlt645.read_data(master, addr, 0x02010100)
      assert {:ok, 1.500} = ExDlt645.read_data(master, addr, 0x02020100)
      assert {:ok, 0.3300} = ExDlt645.read_data(master, addr, 0x02030000)
    end

    test "applies CT / PT and overall multiplier scaling factors", %{
      master: master,
      address: addr
    } do
      # Secondary reading is 1234.56 kWh, multiplier 20 -> 24691.2 kWh
      assert {:ok, 24691.2} = ExDlt645.read_data(master, addr, 0x00010000, multiplier: 20)

      # Secondary current reading is 1.500 A, CT ratio 20 (e.g. 100/5A) -> 30.0 A
      assert {:ok, 30.0} = ExDlt645.read_data(master, addr, 0x02020100, ct: 20)

      # Secondary voltage reading is 220.0 V, PT ratio 100 -> 22000.0 V
      assert {:ok, 22000.0} = ExDlt645.read_data(master, addr, 0x02010100, pt: 100)
    end

    test "reads raw frame when raw: true is passed", %{master: master, address: addr} do
      {:ok, %Frame{} = frame} = ExDlt645.read_data(master, addr, 0x02010100, raw: true)
      assert frame.address == addr
      assert frame.func == 0x11
      assert frame.di == 0x02010100
      assert frame.data_parsed == 220.0
    end

    test "broadcast reads meter communication address (0x13)", %{master: master, address: addr} do
      assert {:ok, ^addr} = ExDlt645.read_address(master)
    end

    test "returns structured meter error when requesting non-existent DI", %{
      master: master,
      address: addr
    } do
      # 0x00090000 does not exist in slave
      assert {:error, {:meter_error, 0x20, :data_not_exist}} =
               ExDlt645.read_data(master, addr, 0x00090000)
    end

    test "writes new address to meter and verifies", %{
      master: master,
      slave: slave,
      address: old_addr
    } do
      new_addr = "000000000088"
      assert :ok = ExDlt645.write_address(master, old_addr, new_addr)
      assert Slave.address(slave) == new_addr

      # Now reading with new address succeeds
      assert {:ok, 220.0} = ExDlt645.read_data(master, new_addr, 0x02010100)
    end

    test "broadcast time synchronization", %{master: master} do
      now = NaiveDateTime.utc_now()
      assert :ok = ExDlt645.sync_time(master, now)
    end
  end

  describe "Master-Slave communication in active mode" do
    test "delivers asynchronous result message to caller", %{bus: bus_name, address: addr} do
      {:ok, active_master} =
        Master.start_link(
          tty: "virtual",
          active: true,
          uart_opts: [virtual_bus: bus_name],
          timeout: 2_000
        )

      assert :ok = ExDlt645.read_data(active_master, addr, 0x02010100)

      assert_receive {:ex_dlt645, %{func: 0x11, address: ^addr},
                      {:ok, %Frame{data_parsed: 220.0}}},
                     2_000

      Master.stop(active_master)
    end
  end
end

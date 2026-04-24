defmodule SpawnDemo do
  def run do
    IO.puts("PARENT starting loop")

    for n <- 1..5 do
      IO.puts("PARENT spawning child #{n}")

      spawn(fn ->
        IO.puts("  CHILD #{n} started")
        Process.sleep(1000)
        IO.puts("  CHILD #{n} finished")
      end)
    end

    IO.puts("PARENT finished loop")
  end
end

defmodule MailboxDemo do
  def start_server do
    spawn(fn -> loop() end)
  end

  def loop do
    receive do
      {:hello, n} ->
        IO.puts("SERVER handling #{n}")
        IO.inspect(Process.info(self(), :message_queue_len), label: "queue_len")
        Process.sleep(500)
        loop()
    end
  end

  def run do
    server = start_server()

    for n <- 1..10 do
      spawn(fn ->
        delay = :rand.uniform(1000)
        Process.sleep(delay)
        IO.puts("CLIENT #{n} sending after #{delay} ms")
        send(server, {:hello, n})
      end)
    end

    :ok
  end
end

defmodule PingServer do
  def start do
    spawn(fn -> loop() end)
  end

  def loop do
    receive do
      {:ping, caller, n} ->
        send(caller, {:pong, n})
        loop()
    end
  end

  def run do
    server = start()
    send(server, {:ping, self(), 1})

    receive do
      {:pong, n} -> IO.puts("got pong #{n}")
    end
  end
end

defmodule RegisteredEcho do
  def start do
    pid = spawn(fn -> loop() end)
    Process.register(pid, :echo_server)
    pid
  end

  def loop do
    receive do
      {:echo, msg, caller} ->
        send(caller, {:reply, msg})
        loop()
    end
  end

  def run do
    start()
    send(:echo_server, {:echo, "hola", self()})

    receive do
      {:reply, msg} -> IO.inspect(msg)
    end
  end
end

defmodule MonitorNormalDemo do
  def run do
    worker = spawn(fn ->
      Process.sleep(1000)
      IO.puts("worker finishing")
      exit(:normal)
    end)

    ref = Process.monitor(worker)

    receive do
      {:DOWN, ^ref, :process, ^worker, reason} ->
        IO.puts("worker is down: #{inspect(reason)}")
    end
  end
end

defmodule MonitorCrashDemo do
  def run do
    worker = spawn(fn ->
      Process.sleep(500)
      raise "unexpected error"
    end)

    ref = Process.monitor(worker)

    receive do
      {:DOWN, ^ref, :process, ^worker, reason} ->
        IO.puts("worker crashed with reason: #{inspect(reason)}")
    end
  end
end

defmodule TaskLikeDemo do
  def run do
    parent = self()

    worker = spawn(fn ->
      result = Enum.sum(1..10)
      send(parent, {:result, self(), result})
    end)

    ref = Process.monitor(worker)

    receive do
      {:result, ^worker, result} ->
        IO.puts("got result: #{result}")
    end

    receive do
      {:DOWN, ^ref, :process, ^worker, reason} ->
        IO.puts("worker ended with reason: #{inspect(reason)}")
    end
  end
end

defmodule BottleneckDemo do
  def start do
    spawn(fn -> loop(0) end)
  end

  def loop(processed_count) do
    receive do
      {:heavy_request, n, caller} ->
        IO.puts("SERVER starting heavy work for request #{n}")
        IO.inspect(Process.info(self(), :message_queue_len), label: "queue_len_before_heavy_work")
        Process.sleep(1500)
        send(caller, {:heavy_done, n})
        IO.puts("SERVER finished heavy work for request #{n}")
        loop(processed_count + 1)

      {:stats, caller} ->
        send(caller, {:stats, processed_count})
        loop(processed_count)
    end
  end

  def run do
    server = start()
    parent = self()

    for n <- 1..5 do
      spawn(fn ->
        IO.puts("CLIENT #{n} sending heavy request")
        send(server, {:heavy_request, n, parent})
      end)
    end

    collect(5)
  end

  defp collect(0), do: :ok

  defp collect(remaining) do
    receive do
      {:heavy_done, n} ->
        IO.puts("CLIENT got heavy_done for request #{n}")
        collect(remaining - 1)
    end
  end
end

defmodule DelegationDemo do
  def start do
    pid = spawn(fn -> loop(%{done: 0, jobs: %{}}) end)
    Process.register(pid, :delegation_server)
    pid
  end

  def loop(state) do
    receive do
      {:heavy_request, n, caller} ->
        IO.puts("SERVER received request #{n}")
        IO.inspect(Process.info(self(), :message_queue_len), label: "queue_len_when_dispatching")

        worker =
          spawn(fn ->
            Process.sleep(1500)
            send(:delegation_server, {:worker_done, n, caller, self()})
          end)

        ref = Process.monitor(worker)
        jobs = Map.put(state.jobs, ref, %{request_id: n, caller: caller, worker: worker})
        loop(%{state | jobs: jobs})

      {:worker_done, n, caller, worker_pid} ->
        IO.puts("SERVER got worker result for request #{n} from #{inspect(worker_pid)}")
        send(caller, {:heavy_done, n})
        loop(%{state | done: state.done + 1})

      {:DOWN, ref, :process, _pid, reason} ->
        case Map.pop(state.jobs, ref) do
          {nil, jobs} ->
            loop(%{state | jobs: jobs})

          {job, jobs} ->
            IO.puts("SERVER observed worker down for request #{job.request_id}: #{inspect(reason)}")
            loop(%{state | jobs: jobs})
        end
    end
  end

  def run do
    start()
    parent = self()

    for n <- 1..5 do
      spawn(fn ->
        IO.puts("CLIENT #{n} sending heavy request")
        send(:delegation_server, {:heavy_request, n, parent})
      end)
    end

    collect(5)
  end

  defp collect(0), do: :ok

  defp collect(remaining) do
    receive do
      {:heavy_done, n} ->
        IO.puts("CLIENT got heavy_done for request #{n}")
        collect(remaining - 1)
    end
  end
end

defmodule RegisterAndMonitorManyDemo do
  def start_counter do
    pid = spawn(fn -> counter_loop(0) end)
    Process.register(pid, :counter)
    pid
  end

  def counter_loop(value) do
    receive do
      {:inc, caller} ->
        new_value = value + 1
        send(caller, {:counter_value, new_value})
        counter_loop(new_value)

      {:get, caller} ->
        send(caller, {:counter_value, value})
        counter_loop(value)
    end
  end

  def run do
    start_counter()
    send(:counter, {:inc, self()})

    receive do
      {:counter_value, value} ->
        IO.puts("counter value after increment: #{value}")
    end

    workers =
      for n <- 1..3 do
        parent = self()

        spawn(fn ->
          delay = 400 * n
          Process.sleep(delay)

          if rem(n, 2) == 0 do
            raise "worker #{n} failed"
          else
            send(parent, {:worker_result, n, :ok})
          end
        end)
      end

    refs =
      Enum.map(workers, fn pid ->
        {pid, Process.monitor(pid)}
      end)

    IO.inspect(refs, label: "monitored_workers")

    collect(3)
  end

  defp collect(0), do: :ok

  defp collect(remaining) do
    receive do
      {:worker_result, n, :ok} ->
        IO.puts("got result from worker #{n}")
        collect(remaining)

      {:DOWN, _ref, :process, pid, reason} ->
        IO.puts("observed #{inspect(pid)} down with reason #{inspect(reason)}")
        collect(remaining - 1)
    end
  end
end

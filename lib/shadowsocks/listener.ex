defmodule Shadowsocks.Listener do
  use GenServer
  require Shadowsocks.Event
  import Record

  defrecordp :state, lsock: nil, args: nil, port: nil, up: 0, down: 0, flow_time: 0

  @opts [:binary, {:backlog, 20},{:nodelay, true}, {:active, false}, {:packet, :raw},{:reuseaddr, true},{:send_timeout_close, true}, {:buffer, 16384}]
  @default_arg %{ota: false, method: "rc4-md5"}
  @min_flow 5 * 1024 * 1024
  @min_time 60 * 1000

  def update(pid, args) do
    GenServer.call pid, {:update, args}
  end

  def port(pid) do
    GenServer.call pid, :get_port
  end

  def start_link(args) when is_list(args) do
    Enum.into(args, %{}) |> start_link
  end
  def start_link(args) when is_map(args) do
    args = Map.merge(@default_arg, args)
    |> validate_arg(:port, :required)
    |> validate_arg(:port, &is_integer/1)
    |> validate_arg(:method, Shadowsocks.Encoder.methods())
    |> validate_arg(:password, :required)
    |> validate_arg(:password, &is_binary/1)
    |> validate_arg(:type, :required)
    |> validate_arg(:type, [:client, :server])
    |> validate_arg(:ota, [true, false])
    if args[:type] == :client do
      args
      |> validate_arg(:server, :required)
      |> validate_arg(:server, &is_tuple/1)
    end
    args =
      case args do
        %{conn_mod: mod} when is_atom(mod) -> args
        %{type: :client} -> Map.put(args, :conn_mod, Shadowsocks.Conn.Client)
        %{type: :server} -> Map.put(args, :conn_mod, Shadowsocks.Conn.Server)
      end
      |> case do
           %{server: {domain, port}}=m when is_binary(domain) ->
             %{m | server: {String.to_charlist(domain), port}}
           m ->
             m
         end
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    Process.flag(:trap_exit, true)

    opts = case args do
             %{ip: ip} ->
               [{:ip, ip}|@opts]
             _->
               @opts
           end
    case :gen_tcp.listen(args.port, opts) do
      {:ok, lsock} ->
        case :prim_inet.async_accept(lsock, -1) do
          {:ok, _} ->
            Shadowsocks.Event.start_listener(args.port)
            {:ok, state(lsock: lsock, args: args, port: args.port)}
          {:error, error} ->
            {:stop, error}
        end
      error ->
        {:stop, error}
    end
  end

  def handle_call({:update, args}, _from, state(args: old_args)=state) do
    try do
      args = Enum.filter(args, fn
        {:method,_} -> true;
        {:password,_} -> true;
        {:conn_mod,_}->true;
        _ -> false
        end)
      |> Enum.into(old_args)
      |> validate_arg(:method, Shadowsocks.Encoder.methods())
      |> validate_arg(:password, &is_binary/1)
      |> validate_arg(:conn_mod, &is_atom/1)

      {:reply, :ok, state(state, args: args)}
    rescue
      e in ArgumentError ->
        {:reply, {:error, e}, state}
    end
  end

  def handle_call(:get_port, _, state(port: port)=state) do
    {:reply, port, state}
  end

  def handle_info({:inet_async, _, _, {:ok, csock}}, state) do
    true = :inet_db.register_socket(csock, :inet_tcp)
    {:ok, pid} = Shadowsocks.Conn.start_link(csock, state(state, :args))
    Process.put(pid, {0, 0})
    case :gen_tcp.controlling_process(csock, pid) do
      :ok ->
        send pid, {:shoot, csock}
      {:error, _} ->
        Process.exit(pid, :kill)
        :gen_tcp.close(csock)
    end
    case :prim_inet.async_accept(state(state,:lsock), -1) do
      {:ok, _} ->
        {:noreply, state}
      {:error, ref} ->
        {:stop, {:async_accept, :inet.format_error(ref)}, state}
    end

  end

  def handle_info({:inet_async, _lsock, _ref, error}, state) do
    {:stop, error, state}
  end

  def handle_info({:flow, pid, down, up}, state(up: pup,down: pdown, flow_time: ft)=s) do
    with {old_down, old_up} <- Process.get(pid) do
      Process.put(pid, {old_down+down, old_up+up})
    end
    tick = System.system_time(:milliseconds)
    case {pup+up, pdown+down} do
      {u, d} when u > @min_flow or d > @min_flow or tick - ft > @min_time ->
        Shadowsocks.Event.flow(state(s, :port), d, u)
        {:noreply, state(s, up: 0, down: 0, flow_time: tick)}
      {u,d} ->
        {:noreply, state(s, up: u, down: d)}
    end
  end

  def handle_info({:EXIT, pid, reason}, state(port: port)=state) do
    with {down, up} <- Process.get(pid) do
      Shadowsocks.Event.close_conn(port, pid, reason, {down, up})
      Process.delete(pid)
    end
    {:noreply, state}
  end

  def terminate(_, state(port: port, up: up, down: down)) when up > 0 and down > 0 do
    Shadowsocks.Event.sync_flow(port, down, up)
  end
  def terminate(_, state) do
    state
  end

  defp validate_arg(arg, key, :required) do
    unless Map.has_key?(arg, key) do
      raise ArgumentError, message: "required #{key}"
    end
    arg
  end
  defp validate_arg(arg, key, fun) when is_function(fun) do
    unless fun.(arg[key]) do
      raise ArgumentError, message: "bad arg #{key} : #{arg[key]}"
    end
    arg
  end
  defp validate_arg(arg, key, values) when is_list(values) do
    unless Enum.any?(values, &(&1 == arg[key])) do
      raise ArgumentError, message: "bad arg #{key} : #{arg[key]}, accept values: #{inspect values}"
    end
    arg
  end
end

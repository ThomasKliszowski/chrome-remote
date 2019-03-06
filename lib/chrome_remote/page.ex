defmodule ChromeRemote.Page do
  use GenServer
  alias __MODULE__
  alias ChromeRemote.Chrome
  alias ChromeRemote.Protocol.WebSocket
  alias ChromeRemote.Interface

  defstruct url: "",
            socket: nil,
            callbacks: [],
            event_subscribers: %{},
            ref_id: 1,
            chrome_pid: nil,
            page_id: nil,
            credentials: nil,
            lifecycle_pid: nil

  def start_link(args \\ [], opts \\ []), do: GenServer.start_link(__MODULE__, args, opts)

  def init(opts) do
    chrome_pid = Keyword.get(opts, :chrome_pid)
    page_id = Keyword.get(opts, :page_id)
    credentials = Keyword.get(opts, :credentials)
    user_agent = Keyword.get(opts, :user_agent)

    Process.monitor(chrome_pid)

    {:ok, socket} =
      Chrome.get_websocket_uri(chrome_pid, page_id)
      |> URI.to_string()
      |> WebSocket.start_link()

    setup_authentication(credentials)
    {:ok, lifecycle_pid} = setup_lifecycle()
    setup_user_agent(user_agent)

    state = %Page{
      socket: socket,
      chrome_pid: chrome_pid,
      lifecycle_pid: lifecycle_pid,
      page_id: page_id
    }

    {:ok, state}
  end

  def navigate(page, url) do
    Interface.Page.navigate!(page, %{url: url})
    send(get_lifecycle(page), :navigating)
  end

  def wait_for_loading(page) do
    get_lifecycle(page)
    |> Page.Lifecycle.wait_for_loading()
  end

  def subscribe(pid, event, subscriber_pid \\ self()) do
    GenServer.call(pid, {:subscribe, event, subscriber_pid})
  end

  def unsubscribe(pid, event, subscriber_pid \\ self()) do
    GenServer.call(pid, {:unsubscribe, event, subscriber_pid})
  end

  def unsubscribe_all(pid, subscriber_pid \\ self()) do
    GenServer.call(pid, {:unsubscribe_all, subscriber_pid})
  end

  defp get_lifecycle(page), do: GenServer.call(page, :get_lifecycle, 10_000)

  def execute_command(pid, method, params, opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    call(pid, method, params, timeout)
  end

  def call(pid, method, params, timeout) do
    GenServer.call(pid, {:call_command, method, params}, timeout)
  end

  # -----

  def handle_call({:call_command, method, params}, from, state) do
    send(self(), {:send_rpc_request, state.ref_id, state.socket, method, params})

    new_state =
      state
      |> add_callback({:call, from})
      |> increment_ref_id()

    {:noreply, new_state}
  end

  # @todo(vy): Subscriber pids that die should be removed from being subscribed
  def handle_call({:subscribe, event, subscriber_pid}, _from, state) do
    new_event_subscribers =
      state
      |> Map.get(:event_subscribers, %{})
      |> Map.update(event, [subscriber_pid], fn subscriber_pids ->
        [subscriber_pid | subscriber_pids]
      end)

    new_state = %{state | event_subscribers: new_event_subscribers}

    {:reply, :ok, new_state}
  end

  def handle_call({:unsubscribe, event, subscriber_pid}, _from, state) do
    new_event_subscribers =
      state
      |> Map.get(:event_subscribers, %{})
      |> Map.update(event, [], fn subscriber_pids ->
        List.delete(subscriber_pids, subscriber_pid)
      end)

    new_state = %{state | event_subscribers: new_event_subscribers}

    {:reply, :ok, new_state}
  end

  def handle_call({:unsubscribe_all, subscriber_pid}, _from, state) do
    new_event_subscribers =
      state
      |> Map.get(:event_subscribers, %{})
      |> Enum.map(fn {key, subscriber_pids} ->
        {key, List.delete(subscriber_pids, subscriber_pid)}
      end)
      |> Enum.into(%{})

    new_state = %{state | event_subscribers: new_event_subscribers}

    {:reply, :ok, new_state}
  end

  def handle_call(:get_lifecycle, _from, %{lifecycle_pid: lifecycle_pid} = state) do
    {:reply, lifecycle_pid, state}
  end

  # This handles websocket frames coming from the websocket connection.
  #
  # If a frame has an ID:
  #   - That means it's for an RPC call, so we will reply to the caller with the response.
  #
  # If the frame is an event:
  #   - Forward the event to any subscribers.
  def handle_info({:message, frame_data}, state) do
    json = Jason.decode!(frame_data)
    id = json["id"]
    method = json["method"]

    # Message is an RPC response
    callbacks =
      if id do
        send_rpc_response(state.callbacks, id, json)
      else
        state.callbacks
      end

    # Message is an Domain event
    if method do
      send_event(state.event_subscribers, method, json)
    end

    {:noreply, %{state | callbacks: callbacks}}
  end

  def handle_info({:send_rpc_request, ref_id, socket, method, params}, state) do
    message = %{
      "id" => ref_id,
      "method" => method,
      "params" => params
    }

    json = Jason.encode!(message)
    WebSocket.send_frame(socket, {:text, json})
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp add_callback(state, from) do
    state
    |> Map.update(:callbacks, [{state.ref_id, from}], fn callbacks ->
      [{state.ref_id, from} | callbacks]
    end)
  end

  defp remove_callback(callbacks, from) do
    callbacks
    |> Enum.reject(&(&1 == from))
  end

  defp increment_ref_id(state) do
    state
    |> Map.update(:ref_id, 1, &(&1 + 1))
  end

  defp send_rpc_response(callbacks, id, json) do
    error = json["error"]

    Enum.find(callbacks, fn {ref_id, _from} ->
      ref_id == id
    end)
    |> case do
      {_ref_id, {:cast, method, from}} = callback ->
        event = {:chrome, method, json}
        send(from, event)
        remove_callback(callbacks, callback)

      {_ref_id, {:call, from}} = callback ->
        status = if error, do: :error, else: :ok
        GenServer.reply(from, {status, json})
        remove_callback(callbacks, callback)

      _ ->
        callbacks
    end
  end

  defp send_event(event_subscribers, event_name, json) do
    event = {:chrome, event_name, json}

    pids_subscribed_to_event =
      event_subscribers
      |> Map.get(event_name, [])

    pids_subscribed_to_event
    |> Enum.each(&send(&1, event))
  end

  defp setup_lifecycle(), do: Page.Lifecycle.start_link(page: self())

  defp setup_authentication(nil), do: nil

  defp setup_authentication(%{} = credentials) do
    {:ok, _} = Page.Authentication.start_link(page: self(), credentials: credentials)
  end

  defp setup_user_agent(nil), do: nil

  defp setup_user_agent(user_agent) do
    pid = self()

    Task.async(fn ->
      Interface.Network.setUserAgentOverride!(pid, %{userAgent: user_agent})
    end)
  end

  def terminate(_reason, state) do
    Process.exit(state.socket, :kill)
    :stop
  end
end
